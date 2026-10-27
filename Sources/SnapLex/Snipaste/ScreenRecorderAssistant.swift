import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import QuartzCore
import os

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

public extension RecordingTargetMode {
    var localizedLabel: String { L10n.string(rawValue) }
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
    private var errorToastPanel: NSPanel?
    private var errorToastTask: Task<Void, Never>?

    private var clockTimer: Timer?
    private var countdownTask: Task<Void, Never>?
    private var pipelineStartupTask: Task<Bool, Never>?
    private var pipeline: ScreenCaptureRecordingPipeline?
    private var isFinalizingRecording = false
    private let recordingLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "ScreenRecording"
    )

    private var targetScreenRect: CGRect = .zero

    private var keyMonitor: Any?

    private init() {}

    public func applyAppearance(_ appearance: NSAppearance?) {
        recordingBarWindow?.appearance = appearance
        regionBorderWindow?.appearance = appearance
        errorToastPanel?.appearance = appearance
    }

    /// Opens the unified F1 capture overlay with the Screen Recording Sub-Toolbar pre-selected!
    public func showAssistant(initialRegion: CGRect? = nil) {
        SnipasteCaptureManager.shared.startCapture(openRecordingSubbar: true)
    }

    /// Starts recording the specified `screenRect` directly from the screenshot sub-toolbar!
    public func startRecording(screenRect: CGRect) {
        guard ScreenRecordingStartPolicy.canStart(
            isCountingDown: isCountingDown,
            isRecording: isRecording,
            isFinalizing: isFinalizingRecording
        ) else {
            recordingLogger.info("recording start ignored reason=already-counting-recording-or-finalizing")
            return
        }

        self.targetScreenRect = screenRect
        recordingLogger.info("recording start accepted width=\(Int(screenRect.width), privacy: .public) height=\(Int(screenRect.height), privacy: .public) countdown=\(self.countdownSeconds, privacy: .public)")

        showRegionGuideBorder(around: screenRect)
        showFloatingRecordingBar(near: screenRect)

        if countdownSeconds > 0 {
            isCountingDown = true
            activeCountdownValue = countdownSeconds
            resizeFloatingRecordingBarToFit()
            countdownTask?.cancel()
            countdownTask = Task { @MainActor in
                while self.activeCountdownValue > 0 && self.isCountingDown {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { return }
                    guard !Task.isCancelled, self.isCountingDown else { return }
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
        elapsedSeconds = 0
        capturedFrameCount = 0
        isPaused = false
        isRecording = true
        resizeFloatingRecordingBarToFit()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLex-Recording-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let pipeline = ScreenCaptureRecordingPipeline(
            screenRect: targetScreenRect,
            recordSpeaker: recordSpeaker,
            recordMicrophone: recordMicrophone,
            recordCursor: recordMouseCursor,
            recordClick: recordMouseClick,
            recordKeystrokes: recordKeystrokes,
            outputURL: url
        )
        pipeline.onVideoFrame = { [weak self, weak pipeline] in
            Task { @MainActor in
                guard let self, let pipeline, self.pipeline === pipeline, self.isRecording else { return }
                self.capturedFrameCount += 1
            }
        }
        pipeline.onFailure = { [weak self, weak pipeline] message in
            Task { @MainActor in
                guard let self, let pipeline, self.pipeline === pipeline else { return }
                self.recordingFailed(message)
            }
        }
        self.pipeline = pipeline

        pipelineStartupTask = Task { @MainActor in
            do {
                try await pipeline.start()
                guard self.pipeline === pipeline, self.isRecording || self.isFinalizingRecording else {
                    await pipeline.cancel()
                    return false
                }
                guard self.isRecording else { return true }
                self.installInputOverlayMonitors()
                self.clockTimer?.invalidate()
                self.clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.isRecording, !self.isPaused else { return }
                        self.elapsedSeconds += 1
                    }
                }
                return true
            } catch {
                guard self.pipeline === pipeline else { return false }
                self.recordingFailed(self.localizedRecordingError(error))
                return false
            }
        }
    }

    public func togglePauseRecording() {
        guard isRecording else { return }
        isPaused.toggle()
        pipeline?.setPaused(isPaused)
        resizeFloatingRecordingBarToFit()
    }

    public func dismissForEscape() {
        if isCountingDown {
            countdownTask?.cancel()
            countdownTask = nil
            isCountingDown = false
            cleanupRecordingWindows()
            return
        }
        if isRecording {
            stopRecordingAndPromptSave()
        } else {
            cleanupRecordingWindows()
        }
    }

    /// Take a screenshot at ANY time while recording without stopping the recording!
    public func takeSnapshotDuringRecording() {
        SnipasteCaptureManager.shared.startCapture()
    }

    public func stopRecordingAndPromptSave() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        guard isRecording else {
            cleanupRecordingWindows()
            return
        }
        isRecording = false
        isFinalizingRecording = true
        clockTimer?.invalidate()
        clockTimer = nil
        removeInputOverlayMonitors()
        cleanupRecordingWindows()
        guard let pipeline else {
            isFinalizingRecording = false
            return
        }
        let startupTask = pipelineStartupTask
        Task { @MainActor in
            defer { self.isFinalizingRecording = false }
            // A stop click can arrive while ScreenCaptureKit is still starting.
            // Finish startup before touching its stream/writer from stop().
            let started = await startupTask?.value ?? true
            self.pipeline = nil
            self.pipelineStartupTask = nil
            guard started else {
                await pipeline.cancel()
                try? FileManager.default.removeItem(at: pipeline.outputURL)
                return
            }
            do {
                try await pipeline.stop()
                self.recordingLogger.info("recording finalized frames=\(self.capturedFrameCount, privacy: .public) result=ready-to-export")
                self.promptExportDialog(recordingURL: pipeline.outputURL)
            } catch {
                await pipeline.cancel()
                try? FileManager.default.removeItem(at: pipeline.outputURL)
                let nsError = error as NSError
                self.recordingLogger.error("recording finalization failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
                self.showRecordingError(L10n.string("无法保存录屏文件，请检查存储空间后重试。"))
            }
        }
    }

    private func recordingFailed(_ message: String) {
        guard isRecording || isCountingDown else { return }
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        isRecording = false
        isPaused = false
        clockTimer?.invalidate()
        clockTimer = nil
        removeInputOverlayMonitors()
        cleanupRecordingWindows()
        let failedPipeline = pipeline
        let startupTask = pipelineStartupTask
        pipeline = nil
        pipelineStartupTask = nil
        Task {
            _ = await startupTask?.value
            await failedPipeline?.cancel()
            if let failedPipeline { try? FileManager.default.removeItem(at: failedPipeline.outputURL) }
        }
        showRecordingError(message)
    }

    private func localizedRecordingError(_ error: Error) -> String {
        (error as? ScreenCaptureRecordingError)?.errorDescription
            ?? L10n.string("录屏过程中发生错误，请重试。")
    }

    private func showRecordingError(_ message: String) {
        errorToastTask?.cancel()
        errorToastPanel?.orderOut(nil)

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(targetScreenRect) }) ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = targetScreenRect.width > 0 && targetScreenRect.height > 0
            ? targetScreenRect.intersection(screenFrame)
            : screen?.visibleFrame ?? screenFrame
        let width = min(360, max(220, anchor.width - 16))
        let size = NSSize(width: width, height: 62)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingErrorToastView(message: message))

        let x = max(screenFrame.minX + 8, min(anchor.midX - size.width / 2, screenFrame.maxX - size.width - 8))
        let y = max(screenFrame.minY + 8, min(anchor.minY + 10, screenFrame.maxY - size.height - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        errorToastPanel = panel

        errorToastTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            if self?.errorToastPanel === panel {
                self?.errorToastPanel = nil
            }
        }
    }

    private func cleanupRecordingWindows() {
        recordingBarWindow?.orderOut(nil)
        recordingBarWindow = nil
        regionBorderWindow?.orderOut(nil)
        regionBorderWindow = nil
    }

    private func installInputOverlayMonitors() {
        removeInputOverlayMonitors()
        guard recordKeystrokes else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
            guard !chars.isEmpty else { return }
            var prefix = ""
            if event.modifierFlags.contains(.command) { prefix += "⌘" }
            if event.modifierFlags.contains(.option) { prefix += "⌥" }
            if event.modifierFlags.contains(.control) { prefix += "⌃" }
            if event.modifierFlags.contains(.shift) { prefix += "⇧" }
            let label = "⌨️ \(prefix)\(chars)"
            Task { @MainActor [weak self] in self?.pipeline?.recordKeyOverlay(label) }
        }
    }

    private func removeInputOverlayMonitors() {
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
    }

    // MARK: - Export Dialog with Side-by-Side Radio Buttons (Default: MP4, Zero Text Truncation!)

    private func promptExportDialog(recordingURL: URL) {
        selectedExportFormat = .mp4

        let savePanel = NSSavePanel()
        savePanel.title = L10n.string("保存录屏 (30 FPS)")
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

        guard savePanel.runModal() == .OK, let rawURL = savePanel.url else {
            try? FileManager.default.removeItem(at: recordingURL)
            return
        }

        let chosenFormat = selectedExportFormat
        let finalURL = rawURL.deletingPathExtension().appendingPathExtension(chosenFormat.fileExtension)

        Task.detached(priority: .userInitiated) {
            do {
                try? FileManager.default.removeItem(at: finalURL)
                switch chosenFormat {
                case .mp4:
                    try FileManager.default.moveItem(at: recordingURL, to: finalURL)
                case .gif:
                    try await Self.exportAnimatedGIF(from: recordingURL, to: finalURL)
                    try? FileManager.default.removeItem(at: recordingURL)
                }
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                }
            } catch {
                try? FileManager.default.removeItem(at: recordingURL)
                await MainActor.run {
                    self.showRecordingError(L10n.string("无法保存录屏文件，请检查存储空间后重试。"))
                }
            }
        }
    }

    private nonisolated static func exportAnimatedGIF(from sourceURL: URL, to url: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ScreenCaptureRecordingError.noFrames }
        let frameRate = 15
        let frameCount = max(1, min(5_400, Int(ceil(duration * Double(frameRate)))))
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { throw ScreenCaptureRecordingError.writeFailed }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]
        ] as CFDictionary)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let delay = 1.0 / Double(frameRate)
        let properties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay
            ]
        ]
        for index in 0..<frameCount {
            let time = CMTime(value: Int64(index), timescale: Int32(frameRate))
            let image: CGImage = try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? ScreenCaptureRecordingError.writeFailed)
                    }
                }
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureRecordingError.writeFailed }
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
        win.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
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
        panel.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
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

private struct RecordingErrorToastView: View {
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.string("录屏未能完成"))
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
        )
        .snapLexAppearance()
    }
}

// MARK: - Side-by-Side Radio Button Export Format Selector (Default: MP4, Zero Text Truncation!)

private struct ExportFormatRadioAccessoryView: View {
    @ObservedObject var manager: ScreenRecorderManager
    let onSelectFormat: (RecordingExportFormat) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(L10n.string("导出格式："))
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
                        Text(L10n.string(format.rawValue))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            if manager.isCountingDown {
                HStack(spacing: 7) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                    Text(L10n.format("准备录制 · 倒计时 %d 秒...", manager.activeCountdownValue))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(manager.isPaused ? Color.white.opacity(0.6) : Color.red)
                        .frame(width: 9, height: 9)
                    Text(formatDuration(manager.elapsedSeconds))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                        .fixedSize(horizontal: true, vertical: false)
                    Text(L10n.string("· 30FPS"))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.62))
                        .fixedSize(horizontal: true, vertical: false)
                }

                Divider().frame(height: 16).background(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.22))

                Button(action: { manager.togglePauseRecording() }) {
                    HStack(spacing: 4) {
                        Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11.5, weight: .bold))
                        Text(L10n.string(manager.isPaused ? "继续" : "暂停"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }

            Button(action: { manager.stopRecordingAndPromptSave() }) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                    Text(L10n.string("结束 F10"))
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Color.white)
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
                .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                .overlay(Capsule().strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1))
        )
        .snapLexAppearance()
    }

    private func formatDuration(_ sec: Int) -> String {
        String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}
