import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import Vision

@MainActor
public final class ScrollingCaptureEngine: ObservableObject {
    public static let shared = ScrollingCaptureEngine()

    @Published public var previewImage: NSImage?
    @Published public var stitchedPixelHeight: Int = 0
    @Published public var stitchedFrameCount: Int = 0
    @Published public var isAutoScrolling: Bool = false
    @Published public var lastScrollWasUpward: Bool = false
    @Published public var statusHint: String = L10n.string("在选框内向上或向下滚动，或点「自动滚动」(Esc 停止)")

    public private(set) var isCaptureActive: Bool = false

    private var targetScreenRect: CGRect = .zero
    private var targetQuartzRect: CGRect = .zero
    private var backingScale: CGFloat = 2.0
    private var frameBorderWindow: NSWindow?
    private var controlPanelWindow: NSPanel?

    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalMouseDownMonitor: Any?

    private var capturePollingTimer: Timer?
    private var autoScrollTimer: Timer?
    private var autoScrollStartedAt: TimeInterval = 0
    private var lastScrollEventTime: TimeInterval = 0

    // Bidirectional stitching state
    private var masterCGImage: CGImage?
    private var lastFrameCGImage: CGImage?
    /// Tracks where the top of `lastFrameCGImage` sits inside `masterCGImage` (in pixels from top)
    private var currentViewportTopInMaster: Int = 0
    private var isProcessingFrame: Bool = false
    private var captureGeneration = UUID()
    private let stitchingQueue = DispatchQueue(label: "io.github.snaplex.scroll-stitching", qos: .userInitiated)

    private typealias CGWindowListCreateImageFunc = @convention(c) (
        CGRect,
        CGWindowListOption,
        CGWindowID,
        CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private let windowListCreateImageFn: CGWindowListCreateImageFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
    }()

    private init() {}

    public func applyAppearance(_ appearance: NSAppearance?) {
        frameBorderWindow?.appearance = appearance
        controlPanelWindow?.appearance = appearance
    }

    public func startScrollingCapture(screenRect: CGRect) {
        stopTimersAndWindows()

        let normalizedRect = CGRect(
            x: round(screenRect.minX),
            y: round(screenRect.minY),
            width: max(100, round(screenRect.width)),
            height: max(120, round(screenRect.height))
        )
        self.targetScreenRect = normalizedRect

        let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, normalizedRect) }) ?? NSScreen.main
        self.backingScale = screen?.backingScaleFactor ?? 2.0
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
        self.targetQuartzRect = CGRect(
            x: normalizedRect.minX,
            y: primaryHeight - normalizedRect.maxY,
            width: normalizedRect.width,
            height: normalizedRect.height
        )

        self.masterCGImage = nil
        self.lastFrameCGImage = nil
        self.currentViewportTopInMaster = 0
        self.previewImage = nil
        self.stitchedPixelHeight = 0
        self.stitchedFrameCount = 0
        self.isAutoScrolling = false
        self.lastScrollWasUpward = false
        self.statusHint = L10n.string("在选框内向上/向下滚动，或点「自动滚动」(Esc 停止 / Enter 完成)")
        self.isCaptureActive = true

        activateUnderlyingWindowOwner(in: targetQuartzRect)

        showFrameBorderWindow(around: normalizedRect)
        showControlPanelWindow(near: normalizedRect)

        // Capture initial base frame immediately
        captureAndStitchSlice()

        let onScrollEvent: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.lastScrollEventTime = ProcessInfo.processInfo.systemUptime
                self.captureAndStitchSlice()
            }
        }

        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: onScrollEvent)
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            onScrollEvent(event)
            return event
        }

        // High-frequency 35ms (~28.5 FPS) capture loop during active scroll / momentum scroll / auto-scroll
        // so trackpad inertial scrolling never skips intermediate frames!
        capturePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.isAutoScrolling || (now - self.lastScrollEventTime < 0.65) {
                    self.captureAndStitchSlice()
                }
            }
        }

        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                if event.keyCode == 53 { // Esc
                    self.cancelScrollingCapture()
                } else if event.keyCode == 49 { // Space -> Pause auto-scroll
                    if self.isAutoScrolling {
                        self.stopAutoScroll(reason: L10n.string("已暂停自动滚动"))
                    }
                } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter -> Finish
                    self.finishScrollingCapture()
                }
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: keyHandler)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            keyHandler(event)
            return event
        }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isAutoScrolling else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.autoScrollStartedAt > 0.35 {
                        self.stopAutoScroll(reason: L10n.string("已暂停自动滚动"))
                }
            }
        }
    }

    private func activateUnderlyingWindowOwner(in quartzRect: CGRect) {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let centerPt = CGPoint(x: quartzRect.midX, y: quartzRect.midY)

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"] else {
                continue
            }
            let winRect = CGRect(x: x, y: y, width: w, height: h)
            if winRect.contains(centerPt) {
                if let app = NSRunningApplication(processIdentifier: ownerPID) {
                    app.activate()
                }
                break
            }
        }
    }

    public func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll(reason: L10n.string("已暂停自动滚动"))
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        isAutoScrolling = true
        autoScrollStartedAt = ProcessInfo.processInfo.systemUptime
        statusHint = L10n.string("自动滚动拼接中... (移出选框或按 Esc 停止)")

        activateUnderlyingWindowOwner(in: targetQuartzRect)
        let centerQuartz = CGPoint(x: targetQuartzRect.midX, y: targetQuartzRect.midY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self, self.isAutoScrolling else { return }
            CGWarpMouseCursorPosition(centerQuartz)
        }

        autoScrollTimer?.invalidate()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isAutoScrolling else { return }
                let now = ProcessInfo.processInfo.systemUptime

                if now - self.autoScrollStartedAt > 0.75 {
                    let currentMouse = NSEvent.mouseLocation
                    if !self.targetScreenRect.insetBy(dx: -28, dy: -28).contains(currentMouse) {
                        self.stopAutoScroll(reason: L10n.string("鼠标移出选框，已停止自动滚动"))
                        return
                    }
                }

                self.postGentleScrollWheelTick()
                self.lastScrollEventTime = now
            }
        }
    }

    private func stopAutoScroll(reason: String) {
        isAutoScrolling = false
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        statusHint = reason
    }

    public func finishScrollingCapture() {
        let finalImg = previewImage
        let rect = targetScreenRect
        stopTimersAndWindows()

        guard let img = finalImg else { return }
        ScreenshotHistoryStore.shared.saveInBackground(img)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])

        // Preserve exact aspect ratio of the stitched long image so it is NEVER squished!
        let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, rect) }) ?? NSScreen.main
        let vFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let imgW = max(80, img.size.width)
        let imgH = max(80, img.size.height)
        let maxW = min(imgW, vFrame.width * 0.82)
        let maxH = min(imgH, vFrame.height * 0.80)
        let fitScale = min(1.0, min(maxW / imgW, maxH / imgH))
        let displayW = round(max(80, imgW * fitScale))
        let displayH = round(max(80, imgH * fitScale))
        let displayX = round(max(vFrame.minX + 16, min(rect.midX - displayW / 2, vFrame.maxX - displayW - 16)))
        let displayY = round(max(vFrame.minY + 54, min(rect.maxY - displayH, vFrame.maxY - displayH - 16)))
        let displayRect = NSRect(x: displayX, y: displayY, width: displayW, height: displayH)
        PinManager.shared.pinImage(img, at: displayRect)
    }

    public func cancelScrollingCapture() {
        stopTimersAndWindows()
    }

    private func stopTimersAndWindows() {
        isCaptureActive = false
        captureGeneration = UUID()
        isProcessingFrame = false
        masterCGImage = nil
        lastFrameCGImage = nil
        previewImage = nil
        isAutoScrolling = false
        capturePollingTimer?.invalidate()
        capturePollingTimer = nil
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        if let mon = globalScrollMonitor { NSEvent.removeMonitor(mon); globalScrollMonitor = nil }
        if let mon = localScrollMonitor { NSEvent.removeMonitor(mon); localScrollMonitor = nil }
        if let mon = globalKeyMonitor { NSEvent.removeMonitor(mon); globalKeyMonitor = nil }
        if let mon = localKeyMonitor { NSEvent.removeMonitor(mon); localKeyMonitor = nil }
        if let mon = globalMouseDownMonitor { NSEvent.removeMonitor(mon); globalMouseDownMonitor = nil }
        frameBorderWindow?.orderOut(nil)
        frameBorderWindow = nil
        controlPanelWindow?.orderOut(nil)
        controlPanelWindow = nil
    }

    private func postGentleScrollWheelTick() {
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -36,
            wheel2: 0,
            wheel3: 0
        ) {
            scrollEvent.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Bidirectional (Up & Down) 2D Vision Phase Correlation + Full-Overlap Edge-Weighted Stitcher

    private func captureAndStitchSlice() {
        guard isCaptureActive, !isProcessingFrame, let capture = windowListCreateImageFn else { return }
        isProcessingFrame = true
        let generation = captureGeneration
        let rect = targetQuartzRect
        let master = masterCGImage
        let previous = lastFrameCGImage
        let viewportTop = currentViewportTopInMaster
        stitchingQueue.async { [weak self] in
            let result: SliceResult? = autoreleasepool {
                guard let slice = capture(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)?.takeRetainedValue(),
                      slice.width >= 64, slice.height >= 80 else { return nil }
                return Self.processSlice(slice, master: master, previous: previous, viewportTop: viewportTop)
            }
            DispatchQueue.main.async {
                // A cancelled/restarted session must never publish old frames
                // or clear the new session's in-flight flag.
                guard let self, self.isCaptureActive, self.captureGeneration == generation else { return }
                self.isProcessingFrame = false
                guard let result else { return }
                if result.reachedMemoryLimit {
                    self.stopAutoScroll(reason: L10n.string("已达到长截图内存上限，请完成当前截图"))
                    return
                }
                self.masterCGImage = result.master
                self.lastFrameCGImage = result.lastFrame
                self.currentViewportTopInMaster = result.viewportTop
                if result.reset {
                    self.stitchedFrameCount = 1
                } else if result.extended {
                    self.stitchedFrameCount += 1
                    self.lastScrollWasUpward = result.upward
                    self.statusHint = L10n.format(
                        result.upward ? "向上拼接 · 第 %d 段 (%d px)" : "向下拼接 · 第 %d 段 (%d px)",
                        self.stitchedFrameCount, result.master.height
                    )
                }
                if result.reset || result.extended {
                    self.stitchedPixelHeight = result.master.height
                    self.updatePreviewImage(from: result.master)
                }
            }
        }
    }

    struct SliceResult {
        let master: CGImage
        let lastFrame: CGImage
        let viewportTop: Int
        var reset = false
        var extended = false
        var upward = false
        var reachedMemoryLimit = false
    }

    nonisolated static func canAllocateStitchedBitmap(width: Int, height: Int) -> Bool {
        // Stitching retains the previous image while allocating the next one.
        // A height limit alone permits gigabyte allocations on wide displays.
        guard width > 0, height > 0, height <= 36_000 else { return false }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (bytes, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        return !rowOverflow && !sizeOverflow && bytes <= 128 * 1024 * 1024
    }

    nonisolated static func processSlice(
        _ slice: CGImage, master: CGImage?, previous: CGImage?, viewportTop: Int
    ) -> SliceResult? {
        guard let master, let previous,
              previous.width == slice.width, previous.height == slice.height else {
            return SliceResult(master: slice, lastFrame: slice, viewportTop: 0, reset: true)
        }
        guard let match = findVerifiedBidirectional2DScrollMatch(prev: previous, curr: slice) else { return nil }
        let newViewportTop = viewportTop + match.signedDeltaRows
        let seamInMaster = viewportTop + match.seamRowInPrev
        let seamInNew = match.seamRowInPrev - match.signedDeltaRows
        let targetHeight = newViewportTop < 0 ? master.height - newViewportTop : newViewportTop + slice.height
        if targetHeight > master.height, !canAllocateStitchedBitmap(width: master.width, height: targetHeight) {
            return SliceResult(master: master, lastFrame: previous, viewportTop: viewportTop, reachedMemoryLimit: true)
        }
        if newViewportTop + slice.height > master.height {
            guard let stitched = stitchBottomExtension(
                master: master, newSlice: slice, seamRowInMaster: seamInMaster, seamRowInNew: seamInNew
            ) else { return nil }
            return SliceResult(master: stitched, lastFrame: slice, viewportTop: newViewportTop, extended: true)
        } else if newViewportTop < 0 {
            guard let stitched = stitchTopExtension(
                master: master, newSlice: slice, seamRowInMaster: seamInMaster, seamRowInNew: seamInNew
            ) else { return nil }
            return SliceResult(master: stitched, lastFrame: slice, viewportTop: 0, extended: true, upward: true)
        }
        return SliceResult(master: master, lastFrame: slice, viewportTop: newViewportTop)
    }

    private func updatePreviewImage(from master: CGImage) {
        let scale = max(1.0, backingScale)
        let masterSize = NSSize(width: CGFloat(master.width) / scale, height: CGFloat(master.height) / scale)
        self.previewImage = NSImage(cgImage: master, size: masterSize)
    }

    private struct VerifiedBidirectionalMatch {
        let seamRowInPrev: Int
        /// `> 0` when scrolling down (content moves up); `< 0` when scrolling up (content moves down)
        let signedDeltaRows: Int
    }

    /// Combines Apple Vision 2D Phase Correlation (`VNTranslationalImageRegistrationRequest`)
    /// with Full-Overlap Active-Edge Verification (ignoring uniform background pixels so white pages never false-match)
    /// and selects the lowest-gradient whitespace row for an invisible seam.
    private nonisolated static func findVerifiedBidirectional2DScrollMatch(
        prev: CGImage,
        curr: CGImage
    ) -> VerifiedBidirectionalMatch? {
        let w = prev.width
        let h = prev.height
        guard w == curr.width, h == curr.height, w >= 64, h >= 80 else { return nil }

        // Ignore outer 8% left/right (scrollbars/borders) and top/bottom 10% (sticky headers/footers)
        let cropX = Int(Double(w) * 0.08)
        let cropW = max(48, Int(Double(w) * 0.82))
        let topMargin = max(12, Int(Double(h) * 0.10))
        let bottomMargin = max(12, Int(Double(h) * 0.10))

        let candidateVerticalBands: [(Double, Double)] = [
            (0.10, 0.90),
            (0.10, 0.68),
            (0.32, 0.90)
        ]

        var candidateDeltas: [Int] = []
        for (yStartRatio, yEndRatio) in candidateVerticalBands {
            let cropY = Int(Double(h) * yStartRatio)
            let cropH = Int(Double(h) * (yEndRatio - yStartRatio))
            guard cropH >= 48 else { continue }

            let coreRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            guard let prevCore = prev.cropping(to: coreRect),
                  let currCore = curr.cropping(to: coreRect) else {
                continue
            }

            let req = VNTranslationalImageRegistrationRequest(targetedCGImage: currCore)
            let handler = VNImageRequestHandler(cgImage: prevCore, options: [:])
            do {
                try handler.perform([req])
            } catch {
                continue
            }

            guard let obs = req.results?.first as? VNImageTranslationAlignmentObservation else {
                continue
            }

            let tx = obs.alignmentTransform.tx
            guard tx.isFinite, obs.alignmentTransform.ty.isFinite,
                  abs(obs.alignmentTransform.ty) <= CGFloat(h) else { continue }
            let rawSignedDelta = Int(round(-obs.alignmentTransform.ty))
            let absDelta = abs(rawSignedDelta)

            if abs(tx) <= 3.5,
               absDelta >= 5,
               absDelta <= Int(Double(h) * 0.72),
               !candidateDeltas.contains(rawSignedDelta) {
                candidateDeltas.append(rawSignedDelta)
            }
        }

        guard !candidateDeltas.isEmpty else { return nil }

        // Evaluate zero-scroll baseline on active edge pixels to ensure the page actually moved
        let zeroEval = evaluateFullOverlapAlignment(
            prev: prev,
            curr: curr,
            cropX: cropX,
            cropW: cropW,
            topMargin: topMargin,
            bottomMargin: bottomMargin,
            signedDeltaRows: 0
        )

        var bestDelta: Int?
        var bestEdgeMAD: Float = .greatestFiniteMagnitude
        var bestOverallMAD: Float = .greatestFiniteMagnitude
        var bestCleanSeamRow: Int = h / 2

        for rawDelta in candidateDeltas {
            for candidateDelta in (rawDelta - 3)...(rawDelta + 3) where abs(candidateDelta) >= 5 {
                let eval = evaluateFullOverlapAlignment(
                    prev: prev,
                    curr: curr,
                    cropX: cropX,
                    cropW: cropW,
                    topMargin: topMargin,
                    bottomMargin: bottomMargin,
                    signedDeltaRows: candidateDelta
                )
                if eval.edgeMAD < bestEdgeMAD {
                    bestEdgeMAD = eval.edgeMAD
                    bestOverallMAD = eval.overallMAD
                    bestDelta = candidateDelta
                    bestCleanSeamRow = eval.cleanestSeamRowInPrev
                }
            }
        }

        guard let finalDelta = bestDelta else { return nil }

        // Strict verification on active text/edge pixels (`bestEdgeMAD`) + overall overlap (`bestOverallMAD`):
        // Prevents two unrelated lines of text on a white background from ever passing!
        let passedEdgeGate = bestEdgeMAD < 11.5 && bestEdgeMAD < zeroEval.edgeMAD * 0.52
        let passedOverallGate = bestOverallMAD < 4.5 && bestOverallMAD < zeroEval.overallMAD * 0.58

        guard passedEdgeGate && passedOverallGate else {
            return nil
        }

        return VerifiedBidirectionalMatch(
            seamRowInPrev: bestCleanSeamRow,
            signedDeltaRows: finalDelta
        )
    }

    private struct OverlapEvaluation {
        let overallMAD: Float
        let edgeMAD: Float
        let cleanestSeamRowInPrev: Int
    }

    /// Evaluates the ENTIRE overlapping region between `prev` and `curr` (excluding top/bottom sticky margins),
    /// computing MAD specifically on active edge/text pixels so uniform white/black backgrounds never dilute the score,
    /// and finds the lowest-energy whitespace row for a clean seam cut.
    private nonisolated static func evaluateFullOverlapAlignment(
        prev: CGImage,
        curr: CGImage,
        cropX: Int,
        cropW: Int,
        topMargin: Int,
        bottomMargin: Int,
        signedDeltaRows: Int
    ) -> OverlapEvaluation {
        let h = prev.height
        // A row `r` in `prev` corresponds to row `r - signedDeltaRows` in `curr`.
        // Both `r` and `r - signedDeltaRows` must lie within `[topMargin, h - bottomMargin)`.
        let prevOverlapStart = max(topMargin, topMargin + signedDeltaRows)
        let prevOverlapEnd = min(h - bottomMargin, h - bottomMargin + signedDeltaRows)
        let overlapH = prevOverlapEnd - prevOverlapStart

        guard overlapH >= 44 else {
            return OverlapEvaluation(overallMAD: 999, edgeMAD: 999, cleanestSeamRowInPrev: h / 2)
        }

        let currOverlapStart = prevOverlapStart - signedDeltaRows
        let prevRect = CGRect(x: cropX, y: prevOverlapStart, width: cropW, height: overlapH)
        let currRect = CGRect(x: cropX, y: currOverlapStart, width: cropW, height: overlapH)

        guard let pSub = prev.cropping(to: prevRect),
              let cSub = curr.cropping(to: currRect) else {
            return OverlapEvaluation(overallMAD: 999, edgeMAD: 999, cleanestSeamRowInPrev: h / 2)
        }

        let cols = 220
        let rows = min(96, max(36, overlapH / 2))
        let count = cols * rows
        let cs = CGColorSpaceCreateDeviceGray()

        guard let ctx1 = CGContext(
            data: nil,
            width: cols,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: cols,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let ctx2 = CGContext(
            data: nil,
            width: cols,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: cols,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return OverlapEvaluation(overallMAD: 999, edgeMAD: 999, cleanestSeamRowInPrev: h / 2)
        }

        ctx1.interpolationQuality = .medium
        ctx2.interpolationQuality = .medium
        ctx1.draw(pSub, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        ctx2.draw(cSub, in: CGRect(x: 0, y: 0, width: cols, height: rows))

        // CGContext owns these buffers for the entire draw/read lifetime.
        // Passing &Array to its initializer only borrows storage for that call.
        guard let buf1 = ctx1.data?.assumingMemoryBound(to: UInt8.self),
              let buf2 = ctx2.data?.assumingMemoryBound(to: UInt8.self) else {
            return OverlapEvaluation(overallMAD: 999, edgeMAD: 999, cleanestSeamRowInPrev: h / 2)
        }
        var totalDiff: Int = 0
        var edgeDiffSum: Int = 0
        var edgePixelCount: Int = 0

        // Track row energy (gradient + mismatch) across the middle 50% of the overlap to pick the cleanest whitespace seam
        let midRowStart = rows / 4
        let midRowEnd = (rows * 3) / 4
        var cleanestRowIdx = rows / 2
        var lowestRowEnergy = Int.max

        for r in 0..<rows {
            let rowBase1 = r * ctx1.bytesPerRow
            let rowBase2 = r * ctx2.bytesPerRow
            var rowEnergy: Int = 0
            for c in 0..<cols {
                let idx1 = rowBase1 + c
                let idx2 = rowBase2 + c
                let v1 = Int(buf1[idx1])
                let v2 = Int(buf2[idx2])
                let diff = abs(v1 - v2)
                totalDiff += diff

                if c > 0 {
                    let g1 = abs(v1 - Int(buf1[idx1 - 1]))
                    let g2 = abs(v2 - Int(buf2[idx2 - 1]))
                    let maxG = max(g1, g2)
                    rowEnergy += maxG + diff * 2
                    if maxG >= 8 {
                        edgeDiffSum += diff
                        edgePixelCount += 1
                    }
                }
            }
            if r >= midRowStart && r <= midRowEnd && rowEnergy < lowestRowEnergy {
                lowestRowEnergy = rowEnergy
                cleanestRowIdx = r
            }
        }

        guard edgePixelCount >= 24 else {
            // Almost completely blank/textureless area
            return OverlapEvaluation(overallMAD: 999, edgeMAD: 999, cleanestSeamRowInPrev: h / 2)
        }

        let overallMAD = Float(totalDiff) / Float(count)
        let edgeMAD = Float(edgeDiffSum) / Float(edgePixelCount)

        // Note: In CGContext buffer, row 0 is at the top of the buffer (which maps to the bottom of the drawn CGRect in Quartz user space),
        // so convert `cleanestRowIdx` safely to `prev` top-down coordinates and clamp well inside the overlap.
        let fractionFromTop = Double(rows - 1 - cleanestRowIdx) / Double(max(1, rows - 1))
        let rawSeamInPrev = prevOverlapStart + Int(round(fractionFromTop * Double(overlapH)))
        let safeMargin = min(20, overlapH / 4)
        let clampedSeamInPrev = max(prevOverlapStart + safeMargin, min(prevOverlapEnd - safeMargin, rawSeamInPrev))

        return OverlapEvaluation(
            overallMAD: overallMAD,
            edgeMAD: edgeMAD,
            cleanestSeamRowInPrev: clampedSeamInPrev
        )
    }

    /// Appends the bottom portion of `newSlice` (`seamRowInNew ..< sliceH`) onto the bottom of `master[0 ..< seamRowInMaster]`
    private nonisolated static func stitchBottomExtension(
        master: CGImage,
        newSlice: CGImage,
        seamRowInMaster: Int,
        seamRowInNew: Int
    ) -> CGImage? {
        let w = master.width
        let sliceH = newSlice.height
        let masterKeepH = seamRowInMaster
        let newSliceTakeH = sliceH - seamRowInNew
        let totalHeight = masterKeepH + newSliceTakeH

        guard masterKeepH >= 16,
              seamRowInNew >= 0,
              newSliceTakeH >= 16,
              totalHeight > master.height,
              canAllocateStitchedBitmap(width: w, height: totalHeight) else {
            return nil
        }

        guard let topMasterPart = master.cropping(to: CGRect(x: 0, y: 0, width: w, height: masterKeepH)),
              let bottomNewPart = newSlice.cropping(to: CGRect(x: 0, y: seamRowInNew, width: w, height: newSliceTakeH)) else {
            return nil
        }

        let colorSpace = master.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(bottomNewPart, in: CGRect(x: 0, y: 0, width: w, height: newSliceTakeH))
        ctx.draw(topMasterPart, in: CGRect(x: 0, y: newSliceTakeH, width: w, height: masterKeepH))
        return ctx.makeImage()
    }

    /// Prepends the top portion of `newSlice` (`0 ..< seamRowInNew`) onto the top of `master[seamRowInMaster ..< master.height]`
    private nonisolated static func stitchTopExtension(
        master: CGImage,
        newSlice: CGImage,
        seamRowInMaster: Int,
        seamRowInNew: Int
    ) -> CGImage? {
        let w = master.width
        let newSliceTakeH = seamRowInNew
        let masterKeepH = master.height - seamRowInMaster
        let totalHeight = newSliceTakeH + masterKeepH

        guard newSliceTakeH >= 16,
              seamRowInMaster >= 0,
              masterKeepH >= 16,
              totalHeight > master.height,
              canAllocateStitchedBitmap(width: w, height: totalHeight) else {
            return nil
        }

        guard let topNewPart = newSlice.cropping(to: CGRect(x: 0, y: 0, width: w, height: newSliceTakeH)),
              let bottomMasterPart = master.cropping(to: CGRect(x: 0, y: seamRowInMaster, width: w, height: masterKeepH)) else {
            return nil
        }

        let colorSpace = master.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.draw(bottomMasterPart, in: CGRect(x: 0, y: 0, width: w, height: masterKeepH))
        ctx.draw(topNewPart, in: CGRect(x: 0, y: masterKeepH, width: w, height: newSliceTakeH))
        return ctx.makeImage()
    }

    // MARK: - Minimalist Clean Guide Border (`滚动截屏边框太浮夸了，需要简单一点`)

    private func showFrameBorderWindow(around screenRect: CGRect) {
        let insetRect = screenRect.insetBy(dx: -4, dy: -4)
        let win = NSWindow(
            contentRect: insetRect,
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

        // Simple, thin 1.2pt solid white border with a subtle hairline shadow — clean & understated!
        let borderView = NSHostingView(
            rootView: RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.2)
                .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 0)
                .padding(2.5)
                .background(Color.clear)
        )
        win.contentView = borderView
        win.orderFrontRegardless()
        self.frameBorderWindow = win
    }

    private func showControlPanelWindow(near screenRect: CGRect) {
        let panelW: CGFloat = 290
        let panelH: CGFloat = 480
        let screen = NSScreen.screens.first(where: { NSIntersectsRect($0.frame, screenRect) }) ?? NSScreen.main
        let vFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = screenRect.maxX + 16
        if x + panelW > vFrame.maxX - 10 {
            x = max(vFrame.minX + 10, screenRect.minX - panelW - 16)
        }
        let y = max(vFrame.minY + 14, min(screenRect.maxY - panelH, vFrame.maxY - panelH - 14))

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelW, height: panelH),
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
        panel.contentView = NSHostingView(rootView: ScrollingCaptureHUDView(engine: self))
        panel.orderFrontRegardless()
        self.controlPanelWindow = panel
    }
}

// MARK: - Real-Time Long Screenshot Preview HUD (Pure Monochrome Black & White)

private struct ScrollingCaptureHUDView: View {
    @ObservedObject var engine: ScrollingCaptureEngine
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                Text(L10n.string("长截图实时预览"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                    .fixedSize()
                Spacer()
                Text(L10n.format("%d 段", engine.stitchedFrameCount))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                    .fixedSize()
            }

            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.055))

                    if let img = engine.previewImage {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(spacing: 0) {
                                    Color.clear
                                        .frame(height: 1)
                                        .id("liveTopEdge")
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: .infinity)
                                    Color.clear
                                        .frame(height: 1)
                                        .id("liveBottomEdge")
                                }
                            }
                            .padding(4)
                            .onChange(of: engine.stitchedPixelHeight) { _, _ in
                                withAnimation(.easeOut(duration: 0.12)) {
                                    if engine.lastScrollWasUpward {
                                        proxy.scrollTo("liveTopEdge", anchor: .top)
                                    } else {
                                        proxy.scrollTo("liveBottomEdge", anchor: .bottom)
                                    }
                                }
                            }
                        }
                    } else {
                        Text(L10n.string("等待画面捕获..."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                if let img = engine.previewImage {
                    VStack(spacing: 4) {
                        Text(L10n.string("全览"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.055))
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .padding(3)
                        }
                        .frame(width: 58)
                    }
                }
            }
            .frame(height: 330)

            Text(engine.statusHint)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.primary.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 28)

            HStack(spacing: 8) {
                Button(action: { engine.toggleAutoScroll() }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.isAutoScrolling ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                        Text(L10n.string(engine.isAutoScrolling ? "停止滚动" : "自动滚动"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .fixedSize()
                    }
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(engine.isAutoScrolling ? SnapLexTheme.toolbarSelection(for: colorScheme) : Color.primary.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(engine.isAutoScrolling ? SnapLexTheme.toolbarForeground(for: colorScheme) : Color.clear, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button(action: { engine.cancelScrollingCapture() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .frame(width: 32, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)

                Button(action: { engine.finishScrollingCapture() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11.5, weight: .bold))
                        Text(L10n.string("完成"))
                            .font(.system(size: 12, weight: .bold))
                            .fixedSize()
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(SnapLexTheme.toolbarForeground(for: colorScheme)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                )
        )
        .snapLexAppearance()
    }
}
