import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import QuartzCore

public enum RecordingTargetMode: String, CaseIterable, Identifiable {
    case region = "区域"
    case window = "窗口"
    case fullScreen = "全屏"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .region: return "crop"
        case .window: return "macwindow"
        case .fullScreen: return "display"
        }
    }
}

public enum RecordingExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4 视频 (.mp4)"
    case gif = "GIF 动图 (.gif)"

    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .gif: return "gif"
        }
    }
}

private struct TimedRecordingFrame {
    let image: CGImage
    let timestampSeconds: Double
}

/// Thread-safe snapshot of overlay state read by the 30 FPS background capture queue
private final class RecordingOverlayStateBox: @unchecked Sendable {
    private let lock = NSLock()
    var isPaused: Bool = false
    var recordMouseCursor: Bool = true
    var recordMouseClick: Bool = true
    var recordKeystrokes: Bool = true
    var targetScreenRect: CGRect = .zero
    var targetQuartzRect: CGRect = .zero
    var lastClickTime: TimeInterval = 0
    var lastKeyLabel: String?
    var lastKeyTime: TimeInterval = 0

    func updateConfig(
        isPaused: Bool,
        recordMouseCursor: Bool,
        recordMouseClick: Bool,
        recordKeystrokes: Bool,
        targetScreenRect: CGRect,
        targetQuartzRect: CGRect
    ) {
        lock.lock()
        self.isPaused = isPaused
        self.recordMouseCursor = recordMouseCursor
        self.recordMouseClick = recordMouseClick
        self.recordKeystrokes = recordKeystrokes
        self.targetScreenRect = targetScreenRect
        self.targetQuartzRect = targetQuartzRect
        lock.unlock()
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        self.isPaused = paused
        lock.unlock()
    }

    func recordClick(at time: TimeInterval) {
        lock.lock()
        self.lastClickTime = time
        lock.unlock()
    }

    func recordKey(_ label: String, at time: TimeInterval) {
        lock.lock()
        self.lastKeyLabel = label
        self.lastKeyTime = time
        lock.unlock()
    }

    func snapshot() -> (
        isPaused: Bool,
        recordMouseCursor: Bool,
        recordMouseClick: Bool,
        recordKeystrokes: Bool,
        targetScreenRect: CGRect,
        targetQuartzRect: CGRect,
        lastClickTime: TimeInterval,
        lastKeyLabel: String?,
        lastKeyTime: TimeInterval
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            isPaused,
            recordMouseCursor,
            recordMouseClick,
            recordKeystrokes,
            targetScreenRect,
            targetQuartzRect,
            lastClickTime,
            lastKeyLabel,
            lastKeyTime
        )
    }
}

@MainActor
public final class ScreenRecorderManager: ObservableObject {
    public static let shared = ScreenRecorderManager()

    // Sub-toolbar configuration (defaults to 区域录屏!)
    @Published public var targetMode: RecordingTargetMode = .region
    @Published public var countdownSeconds: Int = 3
    @Published public var recordSpeaker: Bool = false
    @Published public var recordMicrophone: Bool = false
    @Published public var recordMouseCursor: Bool = true
    @Published public var recordMouseClick: Bool = true
    @Published public var recordKeystrokes: Bool = true

    // Active recording state
    @Published public var isCountingDown: Bool = false
    @Published public var activeCountdownValue: Int = 3
    @Published public var isRecording: Bool = false
    @Published public var isPaused: Bool = false
    @Published public var elapsedSeconds: Int = 0
    @Published public var capturedFrameCount: Int = 0

    // Export format state (defaults to MP4!)
    @Published public var selectedExportFormat: RecordingExportFormat = .mp4

    private var recordingBarWindow: NSPanel?
    private var regionBorderWindow: NSWindow?

    private let captureQueue = DispatchQueue(label: "com.snaplex.recorder.capture30fps", qos: .userInteractive)
    private var captureDispatchTimer: DispatchSourceTimer?
    private var clockTimer: Timer?
    private let overlayStateBox = RecordingOverlayStateBox()

    // High-speed 30 FPS timed frames + 15 FPS GIF frames
    private var timedFrames: [TimedRecordingFrame] = []
    private var recordingStartUptime: TimeInterval = 0
    private var accumulatedPausedSeconds: TimeInterval = 0
    private var pauseBeganUptime: TimeInterval?

    private var targetQuartzRect: CGRect = .zero
    private var targetScreenRect: CGRect = .zero

    private var mouseMonitor: Any?
    private var keyMonitor: Any?

    private typealias CGWindowListCreateImageFunc = @convention(c) (
        CGRect,
        CGWindowListOption,
        CGWindowID,
        CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private nonisolated static let windowListCreateImageFn: CGWindowListCreateImageFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
    }()

    private init() {}

    /// Opens the unified F1 capture overlay with the Screen Recording Sub-Toolbar pre-selected!
    public func showAssistant(initialRegion: CGRect? = nil) {
        SnipasteCaptureManager.shared.startCapture(openRecordingSubbar: true)
    }

    /// Starts recording the specified `screenRect` directly from the screenshot sub-toolbar!
    public func startRecording(screenRect: CGRect) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 900
        self.targetScreenRect = screenRect
        self.targetQuartzRect = CGRect(
            x: screenRect.minX,
            y: primaryH - screenRect.maxY,
            width: max(32, screenRect.width),
            height: max(32, screenRect.height)
        )

        showRegionGuideBorder(around: screenRect)
        showFloatingRecordingBar(near: screenRect)

        if countdownSeconds > 0 {
            isCountingDown = true
            activeCountdownValue = countdownSeconds
            resizeFloatingRecordingBarToFit()
            Task { @MainActor in
                while self.activeCountdownValue > 0 && self.isCountingDown {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !self.isCountingDown { return }
                    self.activeCountdownValue -= 1
                }
                if self.isCountingDown {
                    self.isCountingDown = false
                    self.startActualRecordingLoop()
                }
            }
        } else {
            startActualRecordingLoop()
        }
    }

    private func startActualRecordingLoop() {
        timedFrames.removeAll()
        elapsedSeconds = 0
        capturedFrameCount = 0
        isPaused = false
        isRecording = true
        recordingStartUptime = ProcessInfo.processInfo.systemUptime
        accumulatedPausedSeconds = 0
        pauseBeganUptime = nil

        overlayStateBox.updateConfig(
            isPaused: false,
            recordMouseCursor: recordMouseCursor,
            recordMouseClick: recordMouseClick,
            recordKeystrokes: recordKeystrokes,
            targetScreenRect: targetScreenRect,
            targetQuartzRect: targetQuartzRect
        )

        resizeFloatingRecordingBarToFit()
        installInputOverlayMonitors()

        // High-precision 30 FPS (33.33ms) background capture timer on `.userInteractive` queue!
        captureDispatchTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))

        let stateBox = self.overlayStateBox
        timer.setEventHandler { [weak self] in
            guard let frameImg = Self.captureAndCompositeOnBackground(stateBox: stateBox) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self = self, self.isRecording, !self.isPaused else { return }
                let timestamp = max(0, now - self.recordingStartUptime - self.accumulatedPausedSeconds)
                self.timedFrames.append(TimedRecordingFrame(image: frameImg, timestampSeconds: timestamp))
                self.capturedFrameCount = self.timedFrames.count
                // Cap at 5400 frames (3 minutes @ 30 FPS)
                if self.timedFrames.count >= 5400 {
                    self.stopRecordingAndPromptSave()
                }
            }
        }
        timer.resume()
        self.captureDispatchTimer = timer

        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRecording, !self.isPaused else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    public func togglePauseRecording() {
        guard isRecording else { return }
        isPaused.toggle()
        overlayStateBox.setPaused(isPaused)
        let now = ProcessInfo.processInfo.systemUptime
        if isPaused {
            pauseBeganUptime = now
        } else if let began = pauseBeganUptime {
            accumulatedPausedSeconds += (now - began)
            pauseBeganUptime = nil
        }
        resizeFloatingRecordingBarToFit()
    }

    /// Take a screenshot at ANY time while recording without stopping the recording!
    public func takeSnapshotDuringRecording() {
        SnipasteCaptureManager.shared.startCapture()
    }

    public func stopRecordingAndPromptSave() {
        isCountingDown = false
        guard isRecording else {
            cleanupRecordingWindows()
            return
        }
        isRecording = false
        captureDispatchTimer?.cancel()
        captureDispatchTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        removeInputOverlayMonitors()
        cleanupRecordingWindows()

        guard !timedFrames.isEmpty else { return }
        promptExportDialog(timedFrames: timedFrames)
    }

    private func cleanupRecordingWindows() {
        recordingBarWindow?.orderOut(nil)
        recordingBarWindow = nil
        regionBorderWindow?.orderOut(nil)
        regionBorderWindow = nil
    }

    // MARK: - 30 FPS Pure CoreGraphics Background Capture & Overlay Compositing

    private nonisolated static func captureAndCompositeOnBackground(stateBox: RecordingOverlayStateBox) -> CGImage? {
        let state = stateBox.snapshot()
        guard !state.isPaused else { return nil }
        guard let fn = windowListCreateImageFn,
              let rawCG = fn(state.targetQuartzRect, .optionOnScreenOnly, kCGNullWindowID, .nominalResolution)?.takeRetainedValue() else {
            return nil
        }

        let w = rawCG.width
        let h = rawCG.height
        guard state.recordMouseCursor || state.recordMouseClick || state.recordKeystrokes else {
            return rawCG
        }

        let colorSpace = rawCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return rawCG
        }

        ctx.draw(rawCG, in: CGRect(x: 0, y: 0, width: w, height: h))

        let scaleX = CGFloat(w) / max(1, state.targetScreenRect.width)
        let scaleY = CGFloat(h) / max(1, state.targetScreenRect.height)
        let now = ProcessInfo.processInfo.systemUptime

        let mouseScreen = NSEvent.mouseLocation
        if state.targetScreenRect.contains(mouseScreen) {
            let localX = (mouseScreen.x - state.targetScreenRect.minX) * scaleX
            let localY = (mouseScreen.y - state.targetScreenRect.minY) * scaleY

            if state.recordMouseClick, now - state.lastClickTime < 0.38 {
                let progress = CGFloat((now - state.lastClickTime) / 0.38)
                let radius = (12.0 + progress * 22.0) * scaleX
                let alpha = max(0.0, 0.78 * (1.0 - progress))
                ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.32, blue: 0.25, alpha: alpha))
                ctx.setLineWidth(3.0 * scaleX)
                ctx.strokeEllipse(in: CGRect(x: localX - radius, y: localY - radius, width: radius * 2, height: radius * 2))
            }

            if state.recordMouseCursor {
                let r = 6.0 * scaleX
                ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.95))
                ctx.fillEllipse(in: CGRect(x: localX - r, y: localY - r, width: r * 2, height: r * 2))
                ctx.setStrokeColor(CGColor(gray: 0.0, alpha: 0.85))
                ctx.setLineWidth(1.8 * scaleX)
                ctx.strokeEllipse(in: CGRect(x: localX - r, y: localY - r, width: r * 2, height: r * 2))
            }
        }

        if state.recordKeystrokes, let keyStr = state.lastKeyLabel, now - state.lastKeyTime < 1.1 {
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, 15.0 * scaleX, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 1.0, alpha: 1.0)
            ]
            if let attrStr = CFAttributedStringCreate(nil, keyStr as CFString, attrs as CFDictionary) {
                let line = CTLineCreateWithAttributedString(attrStr)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let textW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                let textH = ascent + descent

                let pillRect = CGRect(
                    x: (CGFloat(w) - textW) / 2 - 14 * scaleX,
                    y: 24 * scaleY,
                    width: textW + 28 * scaleX,
                    height: textH + 14 * scaleY
                )
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 8 * scaleX, cornerHeight: 8 * scaleY, transform: nil)
                ctx.setFillColor(CGColor(gray: 0.06, alpha: 0.78))
                ctx.addPath(pillPath)
                ctx.fillPath()

                ctx.textPosition = CGPoint(x: pillRect.minX + 14 * scaleX, y: pillRect.minY + 7 * scaleY + descent)
                CTLineDraw(line, ctx)
            }
        }

        return ctx.makeImage() ?? rawCG
    }

    private func installInputOverlayMonitors() {
        removeInputOverlayMonitors()
        let box = self.overlayStateBox
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            box.recordClick(at: ProcessInfo.processInfo.systemUptime)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
            guard !chars.isEmpty else { return }
            var prefix = ""
            if event.modifierFlags.contains(.command) { prefix += "⌘" }
            if event.modifierFlags.contains(.option) { prefix += "⌥" }
            if event.modifierFlags.contains(.control) { prefix += "⌃" }
            if event.modifierFlags.contains(.shift) { prefix += "⇧" }
            let label = "⌨️ \(prefix)\(chars)"
            box.recordKey(label, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func removeInputOverlayMonitors() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }

    // MARK: - Export Dialog with Side-by-Side Radio Buttons (Default: MP4, Zero Text Truncation!)

    private func promptExportDialog(timedFrames: [TimedRecordingFrame]) {
        selectedExportFormat = .mp4

        let savePanel = NSSavePanel()
        savePanel.title = "保存录屏 (30 FPS)"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let baseName = "SnapLex_Record_\(formatter.string(from: Date()))"
        savePanel.nameFieldStringValue = "\(baseName).mp4"
        savePanel.canCreateDirectories = true

        // Wrap `ExportFormatRadioAccessoryView` in an explicit-width container so `NSSavePanel` NEVER clips the radio labels!
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 54))
        let accessoryHosting = NSHostingView(
            rootView: ExportFormatRadioAccessoryView(
                manager: self,
                onSelectFormat: { format in
                    let currentField = savePanel.nameFieldStringValue
                    let stem = (currentField as NSString).deletingPathExtension
                    savePanel.nameFieldStringValue = "\(stem.isEmpty ? baseName : stem).\(format.fileExtension)"
                }
            )
        )
        accessoryHosting.frame = containerView.bounds
        accessoryHosting.autoresizingMask = [.width, .height]
        containerView.addSubview(accessoryHosting)
        savePanel.accessoryView = containerView

        guard savePanel.runModal() == .OK, let rawURL = savePanel.url else { return }

        let chosenFormat = selectedExportFormat
        let finalURL = rawURL.deletingPathExtension().appendingPathExtension(chosenFormat.fileExtension)

        switch chosenFormat {
        case .mp4:
            Task.detached(priority: .userInitiated) {
                Self.exportTimedMP4VideoSync(timedFrames: timedFrames, to: finalURL)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                }
            }
        case .gif:
            Task.detached(priority: .userInitiated) {
                // Sample at 15 FPS (`every 2nd frame` from 30 FPS capture) so GIF playback is smooth and file size stays compact
                let strideStep = timedFrames.count > 40 ? 2 : 1
                var gifImages: [CGImage] = []
                for idx in stride(from: 0, to: timedFrames.count, by: strideStep) {
                    gifImages.append(timedFrames[idx].image)
                }
                let avgDelay: Double
                if let lastTS = timedFrames.last?.timestampSeconds, lastTS > 0.1, gifImages.count > 1 {
                    avgDelay = max(0.033, min(0.15, lastTS / Double(gifImages.count)))
                } else {
                    avgDelay = Double(strideStep) / 30.0
                }
                Self.exportAnimatedGIF(frames: gifImages, to: finalURL, frameDelay: avgDelay)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                }
            }
        }
    }

    public nonisolated static func exportAnimatedGIF(frames: [CGImage], to url: URL, frameDelay: Double) {
        try? FileManager.default.removeItem(at: url)
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.gif.identifier as CFString,
                  frames.count,
                  nil
              ) else {
            return
        }

        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay
            ]
        ]

        for cgFrame in frames {
            CGImageDestinationAddImage(destination, cgFrame, frameProperties as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
    }

    /// Exports 30 FPS H.264 MP4 using exact real-time presentation timestamps (`CMTime` timescale 600)
    private nonisolated static func exportTimedMP4VideoSync(timedFrames: [TimedRecordingFrame], to url: URL) {
        guard let first = timedFrames.first?.image else { return }
        try? FileManager.default.removeItem(at: url)

        // H.264 requires even width and height
        let w = max(16, (first.width / 2) * 2)
        let h = max(16, (first.height / 2) * 2)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            return
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, w * h * 6),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h
            ]
        )

        guard writer.canAdd(input) else { return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        var lastTickValue: Int64 = -1

        for (idx, item) in timedFrames.enumerated() {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let pool = adaptor.pixelBufferPool else { continue }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pb = pixelBuffer else { continue }

            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb),
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                ctx.draw(item.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            // Strict monotonically increasing presentation time at 600 ticks/sec (20 ticks per 30fps frame)
            var tick = Int64(round(item.timestampSeconds * 600.0))
            if idx == 0 {
                tick = 0
            } else if tick <= lastTickValue {
                tick = lastTickValue + 20
            }
            lastTickValue = tick

            let presentationTime = CMTime(value: tick, timescale: 600)
            adaptor.append(pb, withPresentationTime: presentationTime)
        }

        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting {
            sema.signal()
        }
        sema.wait()
    }

    // MARK: - Recording Guide Border & Dynamic-Width Outer Centered Floating Bar

    private func showRegionGuideBorder(around screenRect: CGRect) {
        let win = NSWindow(
            contentRect: screenRect.insetBy(dx: -12, dy: -12),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .statusBar
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.sharingType = .none
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = NSHostingView(
            rootView: ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.black.opacity(0.60), lineWidth: 4.0)
                    .shadow(color: .black.opacity(0.65), radius: 5, x: 0, y: 2)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white, lineWidth: 2.0)
            }
            .padding(10)
            .background(Color.clear)
        )
        win.orderFrontRegardless()
        self.regionBorderWindow = win
    }

    private func computeOuterCenteredBarFrame(for screenRect: CGRect, barW: CGFloat, barH: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, screenRect) }) ?? NSScreen.main
        let sFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let vFrame = screen?.visibleFrame ?? sFrame

        let centeredX = max(sFrame.minX + 12, min(round(screenRect.midX - barW / 2), sFrame.maxX - barW - 12))

        // 1. Prefer strictly OUTSIDE below `screenRect`
        let belowY = round(screenRect.minY - barH - 14)
        if belowY >= sFrame.minY + 6 {
            return NSRect(x: centeredX, y: belowY, width: barW, height: barH)
        }

        // 2. Otherwise strictly OUTSIDE above `screenRect`
        let aboveY = round(screenRect.maxY + 14)
        if aboveY + barH <= vFrame.maxY - 4 {
            return NSRect(x: centeredX, y: aboveY, width: barW, height: barH)
        }

        // 3. Otherwise strictly OUTSIDE to the right or left (vertically centered)
        let midY = max(sFrame.minY + 12, min(round(screenRect.midY - barH / 2), vFrame.maxY - barH - 12))
        if screenRect.maxX + 14 + barW <= sFrame.maxX - 8 {
            return NSRect(x: round(screenRect.maxX + 14), y: midY, width: barW, height: barH)
        }
        if screenRect.minX - 14 - barW >= sFrame.minX + 8 {
            return NSRect(x: round(screenRect.minX - barW - 14), y: midY, width: barW, height: barH)
        }

        // 4. Fullscreen fallback: top-center (window has `sharingType = .none`, never recorded)
        return NSRect(x: centeredX, y: round(vFrame.maxY - barH - 14), width: barW, height: barH)
    }

    private func showFloatingRecordingBar(near screenRect: CGRect) {
        let hosting = NSHostingView(rootView: ActiveRecordingControlBarView(manager: self))
        let fit = hosting.fittingSize
        let barW = max(310, ceil(fit.width) + 16)
        let barH = max(46, ceil(fit.height) + 8)
        let barFrame = computeOuterCenteredBarFrame(for: screenRect, barW: barW, barH: barH)

        let panel = NSPanel(
            contentRect: barFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.recordingBarWindow = panel
    }

    private func resizeFloatingRecordingBarToFit() {
        guard let panel = recordingBarWindow, let hosting = panel.contentView else { return }
        let rect = self.targetScreenRect
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let fit = hosting.fittingSize
            let newW = max(310, ceil(fit.width) + 16)
            let newH = max(46, ceil(fit.height) + 8)
            let newFrame = self.computeOuterCenteredBarFrame(for: rect, barW: newW, barH: newH)
            panel.setFrame(newFrame, display: true)
        }
    }
}

// MARK: - Side-by-Side Radio Button Export Format Selector (Default: MP4, Zero Text Truncation!)

private struct ExportFormatRadioAccessoryView: View {
    @ObservedObject var manager: ScreenRecorderManager
    let onSelectFormat: (RecordingExportFormat) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text("导出格式：")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: true)

            ForEach(RecordingExportFormat.allCases) { format in
                Button(action: {
                    manager.selectedExportFormat = format
                    onSelectFormat(format)
                }) {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .strokeBorder(
                                    manager.selectedExportFormat == format ? Color.accentColor : Color.secondary,
                                    lineWidth: 1.6
                                )
                                .frame(width: 16, height: 16)
                            if manager.selectedExportFormat == format {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8.5, height: 8.5)
                            }
                        }
                        Text(format.rawValue)
                            .font(.system(size: 13, weight: manager.selectedExportFormat == format ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(manager.selectedExportFormat == format ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minWidth: 450, minHeight: 48)
    }
}

// MARK: - Floating Control Bar During Active Recording (Screenshot Option Removed, Never Truncates!)

private struct ActiveRecordingControlBarView: View {
    @ObservedObject var manager: ScreenRecorderManager

    var body: some View {
        HStack(spacing: 12) {
            if manager.isCountingDown {
                HStack(spacing: 7) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Text("准备录制 · 倒计时 \(manager.activeCountdownValue) 秒...")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(manager.isPaused ? Color.white.opacity(0.6) : Color.red)
                        .frame(width: 9, height: 9)
                    Text(formatDuration(manager.elapsedSeconds))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("· 30FPS")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: true, vertical: false)
                }

                Divider().frame(height: 16).background(Color.white.opacity(0.22))

                Button(action: { manager.togglePauseRecording() }) {
                    HStack(spacing: 4) {
                        Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11.5, weight: .bold))
                        Text(manager.isPaused ? "继续" : "暂停")
                            .font(.system(size: 11.5, weight: .semibold))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }

            Button(action: { manager.stopRecordingAndPromptSave() }) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                    Text("结束 F10")
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(red: 0.93, green: 0.34, blue: 0.31))
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            Capsule()
                .fill(Color(white: 0.10, opacity: 0.96))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        )
    }

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}
