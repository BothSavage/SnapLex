import AppKit
import SwiftUI
import CoreGraphics
import CoreText
import QuartzCore
import ImageIO

// MARK: - Ultra-Fast In-Memory Screen Capture Bridge (Zero Subprocess, Zero Disk I/O, Zero PNG Encode)

private enum FastScreenCapture {
    private typealias CGWindowListCreateImageFunc = @convention(c) (
        CGRect,
        CGWindowListOption,
        CGWindowID,
        CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private typealias CGDisplayCreateImageFunc = @convention(c) (
        CGDirectDisplayID
    ) -> Unmanaged<CGImage>?

    private static let windowListCreateImageFn: CGWindowListCreateImageFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
    }()

    private static let displayCreateImageFn: CGDisplayCreateImageFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: CGDisplayCreateImageFunc.self)
    }()

    /// Warms up WindowServer Mach port on background queue at app launch
    static func warmup() {
        // Never provoke the Screen Recording permission prompt during launch.
        // The explicit request is made from the user's F1 action, before any
        // capture overlay is created.
        guard CGPreflightScreenCaptureAccess() else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = windowListCreateImageFn?(
                CGRect(x: 0, y: 0, width: 4, height: 4),
                .optionOnScreenOnly,
                kCGNullWindowID,
                .bestResolution
            )?.takeRetainedValue()
        }
    }

    /// Captures all windows strictly BELOW `belowWindowID` so the overlay window can appear on screen in <1ms first!
    static func captureScreen(quartzRect: CGRect, belowWindowID: CGWindowID, displayID: CGDirectDisplayID = CGMainDisplayID()) -> CGImage? {
        if let fn = windowListCreateImageFn {
            let option: CGWindowListOption = belowWindowID != kCGNullWindowID
                ? .optionOnScreenBelowWindow
                : .optionOnScreenOnly
            if let img = fn(quartzRect, option, belowWindowID, .bestResolution)?.takeRetainedValue(),
               img.width > 10, img.height > 10 {
                return img
            }
        }
        if let dispFn = displayCreateImageFn,
           let img = dispFn(displayID)?.takeRetainedValue() {
            return img
        }
        return nil
    }
}

// MARK: - CaptureManager

@MainActor
public final class CaptureManager: NSObject {
    public static let shared = CaptureManager()

    private var reusableWindow: CaptureOverlayWindow?
    private var screenSwitchTimer: Timer?
    private var activeScreenFrame: NSRect?
    public private(set) var isCapturing: Bool = false

    /// Callback when user clicks "💬 截图翻译"
    public var onOCRTranslateImage: ((NSImage, CGRect) -> Void)?
    /// Callback when user clicks "🔍 提取文字"
    public var onOCRExtractText: ((NSImage, CGRect) -> Void)?

    private override init() {
        super.init()
    }

    /// Pre-allocates the NSPanel + SwiftUI NSHostingView toolbar and warms up WindowServer capture at launch
    public func prewarm() {
        FastScreenCapture.warmup()
        if reusableWindow == nil, let screen = NSScreen.main {
            reusableWindow = CaptureOverlayWindow(
                screenFrame: screen.frame,
                onFinish: { [weak self] in
                    self?.closeCapture()
                }
            )
        }
    }

    public func applyAppearance(_ appearance: NSAppearance?) {
        reusableWindow?.appearance = appearance
    }

    public func startCapture(openRecordingSubbar: Bool = false, copyOnRelease: Bool = false) {
        if isCapturing {
            if copyOnRelease {
                reusableWindow?.canvasView.copyNowOrArm()
            }
            return
        }

        // The system permission dialog must be presented before the high-level
        // screenshot panel. Otherwise the screenSaver-level panel can cover the
        // dialog and leave the user unable to grant access.
        guard ScreenCapturePermissionGate.ensureAccess(
            preflight: { CGPreflightScreenCaptureAccess() },
            request: { CGRequestScreenCaptureAccess() }
        ) else { return }

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        isCapturing = true
        showCapture(on: screen, openRecordingSubbar: openRecordingSubbar, copyOnRelease: copyOnRelease)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followMouseAcrossScreens() }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenSwitchTimer = timer
    }

    private func followMouseAcrossScreens() {
        guard isCapturing, reusableWindow?.canvasView.canSwitchScreens == true else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              screen.frame != activeScreenFrame else { return }
        let copyOnRelease = reusableWindow?.canvasView.copyOnRelease ?? false
        showCapture(on: screen, openRecordingSubbar: false, copyOnRelease: copyOnRelease)
    }

    private func showCapture(on screen: NSScreen, openRecordingSubbar: Bool, copyOnRelease: Bool) {
        let screenFrame = screen.frame
        activeScreenFrame = screenFrame

        // 1. Enumerate visible windows (~0.5ms in memory)
        let overlayWindowID = reusableWindow.map { CGWindowID(max(0, $0.windowNumber)) }
        let detectedWindows = Self.detectVisibleWindows(for: screen, excluding: overlayWindowID)

        // 2. Reuse pre-warmed window (0ms allocation!)
        let window: CaptureOverlayWindow
        if let existing = reusableWindow {
            window = existing
        } else {
            let created = CaptureOverlayWindow(
                screenFrame: screenFrame,
                onFinish: { [weak self] in
                    self?.closeCapture()
                }
            )
            reusableWindow = created
            window = created
        }

        window.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
        window.updateScreenFrame(screenFrame)
        window.level = .screenSaver
        window.canvasView.beginSession(
            screenFrame: screenFrame,
            visibleFrame: screen.visibleFrame,
            detectedWindows: detectedWindows,
            openRecordingSubbar: openRecordingSubbar,
            copyOnRelease: copyOnRelease
        )
        let sessionID = window.canvasView.sessionID

        // 3. Show the overlay window IMMEDIATELY (<1ms latency on F1!)
        // Because `screenshotLayer.contents` starts nil, the live desktop shines right through our
        // dimming cutout + blue window highlight frame with 0ms delay!
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 4. Immediately freeze the screen below `window.windowNumber` in memory on high-priority thread
        let winID = CGWindowID(max(0, window.windowNumber))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let quartzY = primaryHeight - screenFrame.maxY
        let quartzRect = CGRect(
            x: screenFrame.minX,
            y: quartzY,
            width: screenFrame.width,
            height: screenFrame.height
        )

        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak window] in
            guard let cgImage = FastScreenCapture.captureScreen(quartzRect: quartzRect, belowWindowID: winID, displayID: displayID) else {
                return
            }
            DispatchQueue.main.async {
                guard let self = self, self.isCapturing, let window = window,
                      window.canvasView.sessionID == sessionID else { return }
                window.canvasView.setCapturedCGImage(cgImage)
            }
        }
    }

    public func pinActiveSelectionIfCapturing() -> Bool {
        guard isCapturing, let overlay = reusableWindow else { return false }
        overlay.canvasView.triggerPinAction()
        return true
    }

    /// Consumes the shortcut while a capture is open, even when there is nothing to save yet.
    public func quickSaveActiveCapture() -> Bool {
        guard isCapturing, let overlay = reusableWindow else { return false }
        overlay.canvasView.quickSaveSelection()
        return true
    }

    public func closeCapture() {
        guard isCapturing else { return }
        isCapturing = false
        screenSwitchTimer?.invalidate()
        screenSwitchTimer = nil
        activeScreenFrame = nil
        reusableWindow?.orderOut(nil)
        reusableWindow?.canvasView.clearSession()
    }

    // MARK: - Window Detection (CGWindowListCopyWindowInfo)

    private static func detectVisibleWindows(for screen: NSScreen, excluding overlayWindowID: CGWindowID?) -> [DetectedWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        var results: [DetectedWindowInfo] = []

        for info in infoList {
            if let windowID = info[kCGWindowNumber as String] as? CGWindowID,
               windowID == overlayWindowID { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05 else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let w = boundsDict["Width"],
                  let h = boundsDict["Height"],
                  w >= 40, h >= 40 else {
                continue
            }

            let cocoaY = primaryHeight - (y + h)
            let rect = CGRect(
                x: x - screen.frame.minX,
                y: cocoaY - screen.frame.minY,
                width: w,
                height: h
            ).intersection(CGRect(origin: .zero, size: screen.frame.size))

            guard rect.width >= 40 && rect.height >= 40 else { continue }

            let appName = info[kCGWindowOwnerName as String] as? String ?? "Window"
            let title = info[kCGWindowName as String] as? String ?? ""
            results.append(DetectedWindowInfo(frameInScreen: rect, appName: appName, title: title))
        }

        return results
    }
}

// MARK: - Full-Screen Pre-Warmed Overlay Window

public final class CaptureOverlayWindow: NSPanel {
    private let containerView: NSView
    private let backgroundImageView: NSView
    public let canvasView: CaptureCanvasView

    public init(
        screenFrame: NSRect,
        onFinish: @escaping () -> Void
    ) {
        let localBounds = NSRect(origin: .zero, size: screenFrame.size)
        self.containerView = NSView(frame: localBounds)
        self.backgroundImageView = NSView(frame: localBounds)
        self.backgroundImageView.wantsLayer = true
        self.backgroundImageView.layer?.contentsGravity = .resize
        self.backgroundImageView.layer?.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]

        self.canvasView = CaptureCanvasView(
            frame: localBounds,
            screenOrigin: screenFrame.origin,
            backgroundLayerProvider: { [weak backgroundImageView] in
                backgroundImageView?.layer
            },
            onFinish: onFinish
        )
        self.containerView.addSubview(backgroundImageView)
        self.containerView.addSubview(canvasView)

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.sharingType = .none
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
        self.contentView = containerView
        self.initialFirstResponder = canvasView
    }

    public func updateScreenFrame(_ screenFrame: NSRect) {
        let localBounds = NSRect(origin: .zero, size: screenFrame.size)
        setFrame(screenFrame, display: false)
        containerView.frame = localBounds
        backgroundImageView.frame = localBounds
        canvasView.frame = localBounds
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    /// Prevent macOS AppKit from pushing the full-screen overlay window downward by the menu bar / notch height (-39pt)!
    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - 120Hz GPU-Accelerated Capture Canvas View

public enum CaptureVisionToolAction: Equatable {
    case scanBarcodes
}

@MainActor
public final class CaptureCanvasView: NSView {
    private var screenOrigin: CGPoint
    private var cgImage: CGImage?
    private var capturedImageRect: CGRect = .zero
    private var detectedWindows: [DetectedWindowInfo] = []
    private let backgroundLayerProvider: () -> CALayer?
    private let onFinish: () -> Void

    private var themeForeground: NSColor {
        SnapLexTheme.appKitToolbarForeground(for: effectiveAppearance)
    }

    private var themeBackground: NSColor {
        SnapLexTheme.appKitToolbarBackground(for: effectiveAppearance)
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // 1x1 pixel RGBA context for 0.003ms color sampling
    private let singlePixelContext: CGContext? = {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }()

    // Selection state
    public var selectionRect: CGRect = .zero {
        didSet {
            updateToolbarPosition()
            needsDisplay = true
        }
    }
    public var hasLockedSelection: Bool = false
    var canSwitchScreens: Bool {
        guard !hasLockedSelection, liveCaptureState == nil else { return false }
        if case .none = interaction { return true }
        return false
    }
    private var hoveredWindow: DetectedWindowInfo?
    private var mouseLocationInView: CGPoint = .zero
    private var capturedCursor: (image: NSImage, rect: CGRect)?
    private var showsCapturedCursor = false
    var copyOnRelease = false

    private struct LiveCaptureState {
        let image: CGImage
        let selection: CGRect
        let locked: Bool
        let annotations: [SnipAnnotationItem]
        let redoStack: [SnipAnnotationItem]
        let tool: SnipAnnotationTool
        let counter: Int
        let windows: [DetectedWindowInfo]
        let showsCursor: Bool
    }
    private var liveCaptureState: LiveCaptureState?
    private var replayRecords: [ScreenshotHistoryRecord] = []
    private var replayIndex = -1
    private var replayLoadToken = UUID()
    private let screenshotHistory: ScreenshotHistoryStore

    // Drag / Resize state
    private enum DragInteraction {
        case none
        case creatingSelection(start: CGPoint)
        case movingSelection(startMouse: CGPoint, initialRect: CGRect)
        case resizingSelection(handle: ResizeHandlePosition, initialRect: CGRect)
        case drawingAnnotation
        case selectingAnnotation(id: UUID)
        case movingAnnotation(id: UUID, initial: SnipAnnotationItem, startMouse: CGPoint)
        case scalingAnnotation(id: UUID, initial: SnipAnnotationItem, anchor: CGPoint, startDistance: CGFloat)
        case rotatingAnnotation(id: UUID, initial: SnipAnnotationItem, center: CGPoint, startAngle: CGFloat)
    }
    private var interaction: DragInteraction = .none

    // Annotation & Recording sub-toolbar state
    public var currentTool: SnipAnnotationTool = .selectMove {
        didSet {
            if currentTool != .selectMove {
                isRecordingSubbarExpanded = false
            }
            updateToolbarView()
            needsDisplay = true
        }
    }
    public var isRecordingSubbarExpanded: Bool = false {
        didSet {
            if isRecordingSubbarExpanded {
                currentTool = .selectMove
            }
            updateToolbarView()
            needsDisplay = true
        }
    }
    public var strokeColor: NSColor = .systemRed {
        didSet { applyTextStyleToInlineField(); updateToolbarView() }
    }
    public var strokeWidth: CGFloat = 4.0 {
        didSet { updateToolbarView() }
    }
    public var isShapeFilled: Bool = false {
        didSet { updateToolbarView() }
    }

    // Text tool style (A): font size, bold, italic — no background
    public var textFontSize: CGFloat = SnipTextStyle.defaultFontSize {
        didSet { applyTextStyleToInlineField(); updateToolbarView() }
    }
    public var textBold: Bool = false {
        didSet { applyTextStyleToInlineField(); updateToolbarView() }
    }
    public var textItalic: Bool = false {
        didSet { applyTextStyleToInlineField(); updateToolbarView() }
    }
    private var currentTextFont: NSFont {
        SnipTextStyle.font(size: textFontSize, bold: textBold, italic: textItalic)
    }

    private var annotations: [SnipAnnotationItem] = []
    private var redoStack: [SnipAnnotationItem] = []
    private var activeAnnotation: SnipAnnotationItem?
    private var selectedAnnotationID: UUID?
    private var nextCounterValue: Int = 1

    // Color picker format
    public var colorFormat: SnipColorFormat = .hex
    private var statusToast: String?
    private var statusToastToken = UUID()
    private var isApplyingImageEffect = false
    private var isScanningBarcodes = false
    private(set) var sessionID = UUID()

    // Floating SwiftUI toolbar subview (allocated once, reused across F1 sessions!)
    private var toolbarHostingView: NSHostingView<CaptureToolbarSwiftUIView>?
    private var trackingArea: NSTrackingArea?

    // Inline direct text field (zero popup dialog!)
    private var inlineTextField: NSTextField?

    public init(
        frame: NSRect,
        screenOrigin: CGPoint,
        backgroundLayerProvider: @escaping () -> CALayer?,
        screenshotHistory: ScreenshotHistoryStore? = nil,
        onFinish: @escaping () -> Void
    ) {
        self.screenOrigin = screenOrigin
        self.backgroundLayerProvider = backgroundLayerProvider
        self.screenshotHistory = screenshotHistory ?? .shared
        self.onFinish = onFinish
        super.init(frame: frame)

        self.wantsLayer = true
        setupToolbarHostingView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var acceptsFirstResponder: Bool { true }

    private var dockBottomInset: CGFloat = 0
    private var menuBarTopInset: CGFloat = 38

    public func beginSession(
        screenFrame: NSRect,
        visibleFrame: NSRect? = nil,
        detectedWindows: [DetectedWindowInfo],
        openRecordingSubbar: Bool = false,
        copyOnRelease: Bool = false
    ) {
        sessionID = UUID()
        self.copyOnRelease = copyOnRelease
        isApplyingImageEffect = false
        isScanningBarcodes = false
        self.frame = NSRect(origin: .zero, size: screenFrame.size)
        self.screenOrigin = screenFrame.origin
        if let vis = visibleFrame {
            self.dockBottomInset = max(0, vis.minY - screenFrame.minY)
            self.menuBarTopInset = max(28, screenFrame.maxY - vis.maxY)
        } else {
            self.dockBottomInset = 0
            self.menuBarTopInset = 38
        }
        self.detectedWindows = detectedWindows
        self.cgImage = nil
        self.capturedImageRect = bounds
        self.backgroundLayerProvider()?.contents = nil
        self.backgroundLayerProvider()?.contentsGravity = .resize
        self.liveCaptureState = nil
        self.replayRecords = []
        self.replayIndex = -1
        self.replayLoadToken = UUID()
        self.showsCapturedCursor = false

        self.hasLockedSelection = false
        self.selectionRect = .zero
        self.interaction = .none
        self.currentTool = .selectMove
        self.isRecordingSubbarExpanded = false
        self.annotations.removeAll()
        self.redoStack.removeAll()
        self.activeAnnotation = nil
        self.selectedAnnotationID = nil
        self.nextCounterValue = 1
        self.statusToast = nil
        self.toolbarHostingView?.isHidden = true

        let mouseScreen = NSEvent.mouseLocation
        self.mouseLocationInView = CGPoint(
            x: mouseScreen.x - screenOrigin.x,
            y: mouseScreen.y - screenOrigin.y
        )
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        self.capturedCursor = (
            cursor.image,
            CGRect(
                x: mouseLocationInView.x - cursor.hotSpot.x,
                y: mouseLocationInView.y - (cursor.image.size.height - cursor.hotSpot.y),
                width: cursor.image.size.width, height: cursor.image.size.height
            )
        )
        self.hoveredWindow = detectedWindows.first(where: { $0.frameInScreen.contains(mouseLocationInView) })

        if openRecordingSubbar {
            ScreenRecorderManager.shared.targetMode = .region
            self.hasLockedSelection = true
            let w: CGFloat = min(800, bounds.width * 0.64)
            let h: CGFloat = min(500, bounds.height * 0.60)
            self.selectionRect = CGRect(
                x: round((bounds.width - w) / 2),
                y: round((bounds.height - h) / 2 + 28),
                width: round(w),
                height: round(h)
            )
            self.isRecordingSubbarExpanded = true
            self.updateToolbarView()
        }

        self.window?.makeFirstResponder(self)
        self.needsDisplay = true
    }

    public func setCapturedCGImage(_ image: CGImage) {
        self.cgImage = image
        let layer = backgroundLayerProvider()
        // A live screen capture fills the overlay. A history image keeps its aspect ratio.
        let fillsScreen = abs(capturedImageRect.width - bounds.width) < 0.5
            && abs(capturedImageRect.height - bounds.height) < 0.5
        layer?.contentsGravity = fillsScreen ? .resize : .resizeAspect
        layer?.contents = image
        self.needsDisplay = true
    }

    public func clearSession() {
        sessionID = UUID()
        replayLoadToken = UUID()
        liveCaptureState = nil
        replayRecords = []
        replayIndex = -1
        capturedCursor = nil
        showsCapturedCursor = false
        isApplyingImageEffect = false
        isScanningBarcodes = false
        commitInlineTextIfNeeded()
        self.cgImage = nil
        self.backgroundLayerProvider()?.contents = nil
        self.annotations.removeAll()
        self.redoStack.removeAll()
        self.activeAnnotation = nil
        self.selectedAnnotationID = nil
        self.toolbarHostingView?.isHidden = true
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Toolbar Setup & Positioning

    private func setupToolbarHostingView() {
        let hosting = NSHostingView(rootView: makeToolbarSwiftUIView())
        hosting.frame = CGRect(x: 0, y: 0, width: 760, height: 84)
        hosting.isHidden = true
        addSubview(hosting)
        self.toolbarHostingView = hosting
    }

    private func updateToolbarView() {
        guard let hosting = toolbarHostingView else { return }
        hosting.rootView = makeToolbarSwiftUIView()
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        hosting.frame.size = fit
        updateToolbarPosition()
    }

    private func updateToolbarPosition() {
        guard let hosting = toolbarHostingView else { return }
        guard hasLockedSelection, selectionRect.width >= 16, selectionRect.height >= 16 else {
            hosting.isHidden = true
            return
        }
        hosting.isHidden = false
        // updateToolbarView measures the hosting view when its content changes.
        // Selection drags only move it; forcing SwiftUI layout on every mouse
        // event makes resizing needlessly expensive.
        let fit = hosting.frame.size

        // When in Full-Screen Recording mode, place the entire menu in the center of the screen
        if isRecordingSubbarExpanded && ScreenRecorderManager.shared.targetMode == .fullScreen {
            let cx = round((bounds.width - fit.width) / 2)
            let cy = round((bounds.height - fit.height) / 2)
            hosting.frame.origin = CGPoint(x: cx, y: cy)
            return
        }

        // Top 30pt of CaptureToolbarSwiftUIView is transparent headroom for hover tooltips.
        let tooltipHeadroom: CGFloat = 30
        let visibleHeight = max(40, fit.height - tooltipHeadroom)
        let gap: CGFloat = 10

        // Account for both the macOS Dock/bottom edge AND the full toolbar height (including sub-toolbar expansion room)
        // so the toolbar flips above the selection BEFORE it ever gets occluded or cramped at the bottom edge!
        let minSafeBottomY: CGFloat = max(24, dockBottomInset + 14)
        let reservedToolbarHeight: CGFloat = max(visibleHeight, 84)
        let maxSafeTopY: CGFloat = max(minSafeBottomY + fit.height, bounds.height - max(menuBarTopInset, 38) - 6)

        // Always horizontally center the toolbar relative to selectionRect, clamped on-screen
        var x = round(selectionRect.midX - fit.width / 2)
        x = max(16, min(x, bounds.width - fit.width - 16))

        let belowY = round(selectionRect.minY - visibleHeight - gap)
        let hasRoomBelowForFullToolbar = (selectionRect.minY - reservedToolbarHeight - gap) >= minSafeBottomY

        // When placed above selectionRect, sit above the top-left dimension badge (`rect.maxY + 6 ..< rect.maxY + 30`)
        // so the toolbar never occludes the dimension badge or the top border of selectionRect.
        let aboveBadgeGap: CGFloat = 34
        let aboveY = round(selectionRect.maxY + aboveBadgeGap)

        var y: CGFloat
        if hasRoomBelowForFullToolbar && belowY >= minSafeBottomY {
            // 1. Plenty of room below selectionRect (accounting for full toolbar height + Dock) -> place outside below
            y = belowY
        } else if aboveY + fit.height <= maxSafeTopY {
            // 2. Bottom edge is getting close -> flip cleanly ABOVE selectionRect & dimension badge
            y = aboveY
        } else if round(selectionRect.maxY + gap) + fit.height <= maxSafeTopY {
            // 2b. Tight top clearance -> place right above selectionRect
            y = round(selectionRect.maxY + gap)
        } else {
            // 3. Selected window/region spans nearly the full screen height (from Dock to Menu Bar),
            // leaving no room outside top or bottom -> place cleanly inside the bottom-center above Dock
            y = round(max(minSafeBottomY + 12, selectionRect.minY + 18))
        }

        // Final strict on-screen clamp so the toolbar or window selector can NEVER go off-screen
        x = max(16, min(x, bounds.width - fit.width - 16))
        y = max(minSafeBottomY, min(y, maxSafeTopY - fit.height))
        hosting.frame.origin = CGPoint(x: x, y: y)
    }

    private func makeToolbarSwiftUIView() -> CaptureToolbarSwiftUIView {
        CaptureToolbarSwiftUIView(
            selectedTool: currentTool,
            isRecordingSubbarExpanded: isRecordingSubbarExpanded,
            detectedWindows: detectedWindows,
            selectedWindowRect: selectionRect,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            isFilled: isShapeFilled,
            canUndo: !annotations.isEmpty,
            canRedo: !redoStack.isEmpty,
            textFontSize: textFontSize,
            textBold: textBold,
            textItalic: textItalic,
            onSelectTool: { [weak self] tool in
                guard let self = self else { return }
                self.commitInlineTextIfNeeded()
                self.currentTool = tool
            },
            onSelectColor: { [weak self] color in
                self?.strokeColor = color
                self?.inlineTextField?.textColor = color
            },
            onSelectWidth: { [weak self] width in
                self?.strokeWidth = width
            },
            onToggleFill: { [weak self] in
                guard let self = self else { return }
                self.isShapeFilled.toggle()
            },
            onAdjustFontSize: { [weak self] up in
                guard let self = self else { return }
                self.textFontSize = SnipTextStyle.steppedSize(self.textFontSize, up: up)
            },
            onToggleBold: { [weak self] in
                self?.textBold.toggle()
            },
            onToggleItalic: { [weak self] in
                self?.textItalic.toggle()
            },
            onUndo: { [weak self] in
                self?.undoAnnotation()
            },
            onRedo: { [weak self] in
                self?.redoAnnotation()
            },
            onScrollingCapture: { [weak self] in
                self?.triggerScrollingCaptureAction()
            },
            onToggleRecordSubbar: { [weak self] in
                guard let self = self else { return }
                self.commitInlineTextIfNeeded()
                ScreenRecorderManager.shared.targetMode = .region
                self.isRecordingSubbarExpanded.toggle()
                if self.isRecordingSubbarExpanded {
                    // If current selection spans nearly the full screen height (leaving no outer room for the recording toolbar),
                    // inset it into a clean centered region with room below for the recording toolbar.
                    if self.selectionRect.minY < 115 && self.selectionRect.maxY > self.bounds.height - 115 {
                        let w: CGFloat = min(self.selectionRect.width, min(860, self.bounds.width * 0.68))
                        let h: CGFloat = min(self.selectionRect.height, min(540, self.bounds.height * 0.62))
                        self.selectionRect = CGRect(
                            x: round((self.bounds.width - w) / 2),
                            y: round((self.bounds.height - h) / 2 + 28),
                            width: round(w),
                            height: round(h)
                        )
                    }
                }
                self.updateToolbarView()
                self.needsDisplay = true
            },
            onSelectRecordingMode: { [weak self] mode in
                guard let self = self else { return }
                ScreenRecorderManager.shared.targetMode = mode
                switch mode {
                case .region:
                    if (self.selectionRect.width >= self.bounds.width - 24 && self.selectionRect.height >= self.bounds.height - 24)
                        || (self.selectionRect.minY < 115 && self.selectionRect.maxY > self.bounds.height - 115) {
                        let w: CGFloat = min(800, self.bounds.width * 0.64)
                        let h: CGFloat = min(500, self.bounds.height * 0.60)
                        self.selectionRect = CGRect(
                            x: round((self.bounds.width - w) / 2),
                            y: round((self.bounds.height - h) / 2 + 28),
                            width: round(w),
                            height: round(h)
                        )
                    }
                case .window:
                    if let hovered = self.hoveredWindow {
                        self.selectionRect = hovered.frameInScreen
                    } else if let firstWin = self.detectedWindows.first {
                        self.selectionRect = firstWin.frameInScreen
                    }
                    self.showToast(L10n.string("🪟 请在下方窗口列表点击，或直接在屏幕上点击要录制的窗口"))
                case .fullScreen:
                    self.selectionRect = self.bounds
                }
                self.updateToolbarView()
                self.needsDisplay = true
            },
            onSelectDetectedWindow: { [weak self] winInfo in
                guard let self = self else { return }
                self.hoveredWindow = winInfo
                self.hasLockedSelection = true
                self.selectionRect = winInfo.frameInScreen
                self.updateToolbarView()
                self.needsDisplay = true
            },
            onStartRecordingNow: { [weak self] in
                self?.triggerScreenRecordAction()
            },
            onPinToScreen: { [weak self] in
                self?.triggerPinAction()
            },
            onApplyImageEffect: { [weak self] effect in
                self?.triggerImageEffect(effect)
            },
            onVisionTool: { [weak self] action in
                self?.triggerVisionTool(action)
            },
            onOCRTranslate: { [weak self] in
                self?.triggerOCRTranslateAction()
            },
            onOCRExtract: { [weak self] in
                self?.triggerOCRExtractAction()
            },
            onSaveFile: { [weak self] in
                self?.triggerSaveFileAction()
            },
            onCancel: { [weak self] in
                self?.commitInlineTextIfNeeded()
                self?.onFinish()
            },
            onCopyConfirm: { [weak self] in
                self?.triggerCopyAction()
            }
        )
    }

    // MARK: - Ultra-Fast Drawing (Zero Full-Screen Bitmap Redraw on Mouse Move!)

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Note: The frozen full-screen CGImage is held by `backgroundImageView.layer.contents` on the GPU!
        // Here in `canvasView.draw(_:)`, we ONLY draw lightweight vector overlays (< 0.2ms per frame at 120Hz)!

        // Determine active highlight rect (either locked selectionRect or hovered window)
        let activeRect: CGRect? = hasLockedSelection
            ? selectionRect
            : hoveredWindow?.frameInScreen

        let capturePreferences = AppSettings.shared.capturePreferences
        // 2. Draw dark dimming overlay outside activeRect
        ctx.saveGState()
        ctx.setFillColor(NSColor(
            srgbRed: capturePreferences.maskRed,
            green: capturePreferences.maskGreen,
            blue: capturePreferences.maskBlue,
            alpha: capturePreferences.maskAlpha
        ).cgColor)
        if let rect = activeRect, rect.width > 1, rect.height > 1 {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(rect)
            ctx.addPath(path)
            ctx.drawPath(using: .eoFill)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        if showsCapturedCursor, liveCaptureState == nil {
            drawCapturedCursor(in: ctx)
        }

        // 3. Draw annotations clipped inside selectionRect
        if let rect = activeRect, rect.width > 2, rect.height > 2 {
            if !annotations.isEmpty || activeAnnotation != nil {
                ctx.saveGState()
                ctx.clip(to: rect)
                for item in annotations {
                    drawAnnotationItem(item, in: ctx)
                }
                if let active = activeAnnotation {
                    drawAnnotationItem(active, in: ctx)
                }
                if let selected = annotations.first(where: { $0.id == selectedAnnotationID }) {
                    drawAnnotationSelection(selected, in: ctx)
                }
                ctx.restoreGState()
            }

            // 4. Selection border: Crisp White with Dark Drop Shadow + Contrast Outline (`选择框还是带点阴影`)
            let borderRect = rect.insetBy(dx: -0.5, dy: -0.5)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -1),
                blur: 6.0,
                color: NSColor.black.withAlphaComponent(0.75).cgColor
            )
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
            let borderWidth = CGFloat(capturePreferences.borderWidth)
            ctx.setLineWidth(borderWidth + 1.6)
            ctx.stroke(borderRect)
            ctx.restoreGState()

            ctx.saveGState()
            let borderColor = hasLockedSelection
                ? NSColor.white
                : NSColor.white.withAlphaComponent(0.95)
            ctx.setStrokeColor(borderColor.cgColor)
            ctx.setLineWidth(borderWidth)
            ctx.stroke(borderRect)
            ctx.restoreGState()

            // 5. 8 Resize handles when selection is locked
            if hasLockedSelection, capturePreferences.showAnchors {
                drawResizeHandles(for: rect, in: ctx)
            }

            // 6. Top-left dimension & window badge
            drawDimensionBadge(for: rect)
        }

        // 6B. When in Window Recording mode (`窗口录制`), highlight whichever open window the user hovers over!
        if isRecordingSubbarExpanded,
           ScreenRecorderManager.shared.targetMode == .window,
           let hovered = hoveredWindow,
           hovered.frameInScreen != selectionRect {
            let candidateRect = hovered.frameInScreen.insetBy(dx: -1, dy: -1)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -1),
                blur: 5.0,
                color: NSColor.black.withAlphaComponent(0.75).cgColor
            )
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.60).cgColor)
            ctx.setLineWidth(4.0)
            ctx.stroke(candidateRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(2.2)
            ctx.setLineDash(phase: 0, lengths: [8, 5])
            ctx.stroke(candidateRect)
            ctx.restoreGState()
            drawHoveredWindowCandidateBadge(for: hovered)
        }

        if capturePreferences.showCrossLines, !isRecordingSubbarExpanded {
            drawFullscreenCrossLines(at: mouseLocationInView, in: ctx)
        }

        let guideFrame = shortcutGuideFrame
        if capturePreferences.showKeyTips, !guideFrame.isNull {
            CaptureShortcutGuideRenderer.draw(in: ctx, frame: guideFrame)
        }

        // Keep pixel inspection available inside the selection; leave the toolbar unobstructed.
        let shouldShowLoupe: Bool = {
            if let toolbar = toolbarHostingView, !toolbar.isHidden,
               toolbar.frame.insetBy(dx: -12, dy: -12).contains(mouseLocationInView) { return false }
            if !hasLockedSelection { return true }
            if case .creatingSelection = interaction { return true }
            if case .resizingSelection = interaction { return true }
            if currentTool == .selectMove, !isRecordingSubbarExpanded {
                return selectionRect.contains(mouseLocationInView)
                    || hitTestResizeHandle(at: mouseLocationInView, in: selectionRect) != nil
            }
            return false
        }()
        if shouldShowLoupe {
            drawPixelMagnifierHUD(at: mouseLocationInView, in: ctx)
        }

        // 8. Draw transient toast if present
        if let toast = statusToast {
            drawToast(toast)
        }
    }

    private func drawResizeHandles(for rect: CGRect, in ctx: CGContext) {
        let handleRadius: CGFloat = 4.5
        ctx.saveGState()
        for handle in ResizeHandlePosition.allCases {
            let pt = handlePoint(for: handle, in: rect)
            let hRect = CGRect(x: pt.x - handleRadius, y: pt.y - handleRadius, width: handleRadius * 2, height: handleRadius * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: hRect)
            let anchor = AppSettings.shared.capturePreferences
            ctx.setStrokeColor(NSColor(
                srgbRed: anchor.anchorBorderRed,
                green: anchor.anchorBorderGreen,
                blue: anchor.anchorBorderBlue,
                alpha: anchor.anchorBorderAlpha
            ).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: hRect)
        }
        ctx.restoreGState()
    }

    private func drawDimensionBadge(for rect: CGRect) {
        let w = Int(round(rect.width))
        let h = Int(round(rect.height))
        var label = "\(w) × \(h)"
        if !hasLockedSelection, let win = hoveredWindow {
            label = L10n.format("%@  ·  %d × %d  (单击选中窗口 / 拖拽自由框选)", win.appName, w, h)
        } else if isRecordingSubbarExpanded, ScreenRecorderManager.shared.targetMode == .window {
            if let matched = detectedWindows.first(where: { $0.frameInScreen == rect }) {
                label = L10n.format("当前录制窗口: %@  ·  %d × %d", matched.displayLabel, w, h)
            } else {
                label = L10n.format("窗口录制  ·  %d × %d  (可点击其他窗口切换)", w, h)
            }
        } else if hasLockedSelection {
            label = L10n.format("%d × %d   [F3 贴图 · Enter 复制 · 拖拽四边微调]", w, h)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: themeForeground
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let strSize = str.size()
        let padX: CGFloat = 8
        let padY: CGFloat = 4
        var bx = rect.minX
        var by = rect.maxY + 6
        if by + strSize.height + padY * 2 > bounds.height - 8 {
            by = rect.maxY - strSize.height - padY * 2 - 6
            bx = rect.minX + 6
        }
        bx = max(8, min(bx, bounds.width - strSize.width - padX * 2 - 8))

        let pillRect = CGRect(x: bx, y: by, width: strSize.width + padX * 2, height: strSize.height + padY * 2)
        let bezier = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
        themeBackground.setFill()
        bezier.fill()
        SnapLexTheme.appKitToolbarBorder(for: effectiveAppearance).setStroke()
        bezier.lineWidth = 0.8
        bezier.stroke()
        str.draw(at: CGPoint(x: pillRect.minX + padX, y: pillRect.minY + padY))
    }

    private func drawHoveredWindowCandidateBadge(for win: DetectedWindowInfo) {
        let rect = win.frameInScreen
        let label = L10n.format("%@  [单击选择此窗口录制]", win.displayLabel)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: themeForeground
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let strSize = str.size()
        let padX: CGFloat = 9
        let padY: CGFloat = 4
        let bx = max(8, min(rect.minX + 8, bounds.width - strSize.width - padX * 2 - 8))
        let by = max(8, min(rect.maxY - strSize.height - padY * 2 - 8, bounds.height - strSize.height - padY * 2 - 8))

        let pillRect = CGRect(x: bx, y: by, width: strSize.width + padX * 2, height: strSize.height + padY * 2)
        let bezier = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
        themeBackground.setFill()
        bezier.fill()
        SnapLexTheme.appKitToolbarBorder(for: effectiveAppearance).setStroke()
        bezier.lineWidth = 0.8
        bezier.stroke()
        str.draw(at: CGPoint(x: pillRect.minX + padX, y: pillRect.minY + padY))
    }

    // MARK: - Pixel magnifier and color picker

    private var shortcutGuideFrame: CGRect {
        guard !isRecordingSubbarExpanded else { return .null }
        return CaptureShortcutGuideRenderer.frame(in: bounds, bottomInset: dockBottomInset)
    }

    private var selectionLimit: CGRect {
        let rect = capturedImageRect
        guard rect.width > 1, rect.height > 1 else { return bounds }
        return rect
    }

    private var sourceImageSize: CGSize {
        guard let cgImage else { return bounds.size }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    private var pixelStep: CGSize {
        CapturePixelGeometry.step(imageSize: sourceImageSize, imageRect: capturedImageRect)
    }

    private func sourcePixel(at point: CGPoint) -> CGPoint {
        CapturePixelGeometry.pixel(at: point, imageSize: sourceImageSize, imageRect: capturedImageRect)
    }

    private func drawPixelMagnifierHUD(at cursor: CGPoint, in ctx: CGContext) {
        guard let cgImage, capturedImageRect.contains(cursor) else { return }
        let (r, g, b, sampledColor) = sampleRGB(at: cursor)
        let colorCode = colorFormat.format(r: r, g: g, b: b)
        let copyHint = L10n.string("按 C 复制色值")
        let formatHint = L10n.format("按 Shift 切换 %@", L10n.string(colorFormat.next().rawValue))
        let textWidth = max(CaptureShortcutGuideRenderer.width(of: copyHint, size: 11),
                            CaptureShortcutGuideRenderer.width(of: formatHint, size: 11))
        let hudWidth = max(170, min(260, max(textWidth + 24, CGFloat(colorCode.count) * 7.3 + 40)))
        let infoHeight: CGFloat = 94
        let loupeHeight: CGFloat = 143
        let hudRect = CapturePixelGeometry.hudFrame(
            at: cursor, size: CGSize(width: hudWidth, height: loupeHeight + infoHeight), within: bounds,
            avoiding: shortcutGuideFrame
        )
        let hx = hudRect.minX
        let hy = hudRect.minY
        let path = CGPath(roundedRect: hudRect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor(calibratedWhite: 0.075, alpha: 0.97).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path)
        ctx.clip()

        // Each source pixel occupies a square, including at the display edges.
        // Clip the source crop instead of shifting its center away from the cursor.
        let count: CGFloat = 13
        let cell: CGFloat = 11
        let pixel = sourcePixel(at: cursor)
        let loupeRect = CGRect(x: hx + (hudWidth - loupeHeight) / 2, y: hy + infoHeight,
                               width: loupeHeight, height: loupeHeight)
        let requested = CGRect(x: pixel.x - 6, y: pixel.y - 6, width: count, height: count)
        let crop = requested.intersection(CGRect(origin: .zero, size: sourceImageSize))
        ctx.saveGState()
        ctx.clip(to: loupeRect)
        if let image = cgImage.cropping(to: crop) {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(
                x: loupeRect.minX + (crop.minX - requested.minX) * cell,
                y: loupeRect.maxY - (crop.maxY - requested.minY) * cell,
                width: crop.width * cell, height: crop.height * cell
            ))
        }
        drawMagnifierSelectionDecorations(loupeRect: loupeRect, requested: requested, cell: cell, in: ctx)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        for index in 1..<Int(count) {
            let offset = CGFloat(index) * cell
            ctx.move(to: CGPoint(x: loupeRect.minX + offset, y: loupeRect.minY))
            ctx.addLine(to: CGPoint(x: loupeRect.minX + offset, y: loupeRect.maxY))
            ctx.move(to: CGPoint(x: loupeRect.minX, y: loupeRect.minY + offset))
            ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: loupeRect.minY + offset))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: loupeRect.minX, y: loupeRect.midY))
        ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: loupeRect.midY))
        ctx.move(to: CGPoint(x: loupeRect.midX, y: loupeRect.minY))
        ctx.addLine(to: CGPoint(x: loupeRect.midX, y: loupeRect.maxY))
        ctx.strokePath()
        let centerCell = CGRect(x: loupeRect.midX - cell / 2, y: loupeRect.midY - cell / 2, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(centerCell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(centerCell)
        ctx.restoreGState()

        let swatch = CGRect(x: hx + 12, y: hy + 54, width: 13, height: 13)
        ctx.setFillColor(sampledColor.cgColor)
        ctx.fill(swatch)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(swatch)
        MagnifierHUDTextRenderer.draw(
            "(\(Int(pixel.x)), \(Int(pixel.y)))", fontName: "Menlo", fontSize: 11,
            color: NSColor.white.withAlphaComponent(0.75).cgColor,
            at: CGPoint(x: hx + 12, y: hy + 76), in: ctx
        )
        MagnifierHUDTextRenderer.draw(
            colorCode, fontName: "Menlo-Bold", fontSize: 11, color: NSColor.white.cgColor,
            at: CGPoint(x: hx + 33, y: hy + 55), in: ctx
        )
        for (text, y) in [(copyHint, hy + 31), (formatHint, hy + 13)] {
            MagnifierHUDTextRenderer.draw(
                text, fontName: "HelveticaNeue-Medium", fontSize: 11,
                color: NSColor.white.withAlphaComponent(0.85).cgColor,
                at: CGPoint(x: hx + 12, y: y), in: ctx
            )
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func sampleRGB(at viewPoint: CGPoint) -> (Int, Int, Int, NSColor) {
        guard let cgImage, let pixelCtx = singlePixelContext, let data = pixelCtx.data else {
            return (0, 0, 0, .black)
        }
        let pixel = sourcePixel(at: viewPoint)
        if let onePx = cgImage.cropping(to: CGRect(origin: pixel, size: CGSize(width: 1, height: 1))) {
            pixelCtx.setBlendMode(.copy)
            pixelCtx.draw(onePx, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let ptr = data.assumingMemoryBound(to: UInt8.self)
            let r = Int(ptr[0]), g = Int(ptr[1]), b = Int(ptr[2])
            return (r, g, b, NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        }
        return (0, 0, 0, .black)
    }

    private func drawCapturedCursor(in context: CGContext) {
        guard showsCapturedCursor, liveCaptureState == nil, let cursor = capturedCursor else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        cursor.image.draw(in: cursor.rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawToast(_ text: String) {
        let visibleSelection = selectionRect.intersection(bounds)
        let container = hasLockedSelection && visibleSelection.width >= 120 && visibleSelection.height >= 44
            ? visibleSelection
            : bounds.insetBy(dx: 8, dy: 8)
        let maxTextWidth = max(48, min(container.width - 44, bounds.width - 44))
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        var visibleText = text
        var attrStr = NSAttributedString(string: visibleText, attributes: [
            .font: font,
            .foregroundColor: themeForeground
        ])
        while attrStr.size().width > maxTextWidth, visibleText.count > 2 {
            visibleText = String(visibleText.dropLast(2)) + "…"
            attrStr = NSAttributedString(string: visibleText, attributes: [
                .font: font,
                .foregroundColor: themeForeground
            ])
        }

        let size = attrStr.size()
        let width = min(size.width + 28, container.width - 12)
        let height = size.height + 14
        let x = max(container.minX + 6, min(container.midX - width / 2, container.maxX - width - 6))
        let y = min(container.minY + 12, container.maxY - height - 8)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: themeForeground
        ]
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        themeBackground.setFill()
        path.fill()
        SnapLexTheme.appKitToolbarBorder(for: effectiveAppearance).setStroke()
        path.lineWidth = 0.8
        path.stroke()
        NSAttributedString(string: visibleText, attributes: attrs)
            .draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 7))
    }

    private func showToast(_ message: String) {
        statusToast = message
        statusToastToken = UUID()
        let token = statusToastToken
        needsDisplay = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if self.statusToastToken == token {
                self.statusToast = nil
                self.needsDisplay = true
            }
        }
    }

    // MARK: - Annotation Rendering (10 Tools)

    private func drawAnnotationItem(_ item: SnipAnnotationItem, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        if item.hasRotation {
            let center = item.transformCenter
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: item.rotationDegrees * .pi / 180)
            ctx.translateBy(x: -center.x, y: -center.y)
        }

        let rect = item.boundingRect
        switch item.tool {
        case .selectMove:
            break

        case .rectangle:
            if item.isFilled {
                ctx.setFillColor(item.color.withAlphaComponent(0.85).cgColor)
                ctx.fill(rect)
            } else {
                ctx.setStrokeColor(item.color.cgColor)
                ctx.setLineWidth(item.lineWidth)
                ctx.stroke(rect)
            }

        case .ellipse:
            if item.isFilled {
                ctx.setFillColor(item.color.withAlphaComponent(0.85).cgColor)
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setStrokeColor(item.color.cgColor)
                ctx.setLineWidth(item.lineWidth)
                ctx.strokeEllipse(in: rect)
            }

        case .line:
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(item.lineWidth)
            ctx.setLineCap(.round)
            ctx.move(to: item.startPoint)
            ctx.addLine(to: item.endPoint)
            ctx.strokePath()

        case .arrow:
            drawArrow(from: item.startPoint, to: item.endPoint, color: item.color, lineWidth: item.lineWidth, in: ctx)

        case .pencil:
            guard item.points.count > 1 else { break }
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setLineWidth(item.lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(item.freehandPath)
            ctx.strokePath()

        case .marker:
            guard item.points.count > 1 else { break }
            ctx.setStrokeColor(item.color.withAlphaComponent(0.36).cgColor)
            ctx.setLineWidth(max(14, item.lineWidth * 3.5))
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.round)
            ctx.addPath(item.freehandPath)
            ctx.strokePath()

        case .mosaic:
            drawFastMosaic(in: rect, blockSize: max(10, Int(item.lineWidth * 3)), ctx: ctx)

        case .blur:
            drawFastBlur(in: rect, ctx: ctx)

        case .counter:
            let radius = max(13, item.lineWidth * 3)
            let badgeRect = CGRect(
                x: item.startPoint.x - radius,
                y: item.startPoint.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            ctx.setFillColor(item.color.cgColor)
            ctx.fillEllipse(in: badgeRect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: badgeRect)

            let numStr = "\(item.counterNumber)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(13, item.lineWidth * 3), weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = numStr.size(withAttributes: attrs)
            numStr.draw(
                at: CGPoint(x: item.startPoint.x - size.width / 2, y: item.startPoint.y - size.height / 2),
                withAttributes: attrs
            )

        case .text:
            guard !item.text.isEmpty else { break }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: item.textFont,
                .foregroundColor: item.color
            ]
            let size = (item.text as NSString).size(withAttributes: attrs)
            (item.text as NSString).draw(
                at: CGPoint(x: item.startPoint.x, y: item.startPoint.y - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor, lineWidth: CGFloat, in ctx: CGContext) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 4 else { return }

        let angle = atan2(dy, dx)
        let headLength = max(14.0, lineWidth * 3.8)
        let headAngle: CGFloat = .pi / 6.5

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        let shaftEnd = CGPoint(
            x: end.x - headLength * 0.65 * cos(angle),
            y: end.y - headLength * 0.65 * sin(angle)
        )
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        ctx.move(to: end)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }

    private func drawAnnotationSelection(_ item: SnipAnnotationItem, in ctx: CGContext) {
        let rect = item.selectionBounds
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(rect)

        let rotatePoint = AnnotationGeometry.rotateHandlePoint(for: item, yAxisDown: false)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        ctx.addLine(to: rotatePoint)
        ctx.strokePath()

        for handle in ResizeHandlePosition.allCases {
            let point = AnnotationGeometry.point(for: handle, in: rect, yAxisDown: false)
            let knob = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: knob)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: knob)
        }

        let knob = CGRect(x: rotatePoint.x - 5, y: rotatePoint.y - 5, width: 10, height: 10)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: knob)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: knob)
        ctx.restoreGState()
    }

    private func updateAnnotation(id: UUID, with updated: SnipAnnotationItem) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index] = updated
        selectedAnnotationID = id
        needsDisplay = true
    }

    /// Downsamples & upsamples with `.none` interpolation for hardware-accelerated pixel mosaic!
    private func drawFastMosaic(in rect: CGRect, blockSize: Int, ctx: CGContext) {
        guard let cgImage = cgImage, rect.width >= 6, rect.height >= 6 else { return }
        let scaleX = CGFloat(cgImage.width) / max(1, bounds.width)
        let scaleY = CGFloat(cgImage.height) / max(1, bounds.height)
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: (bounds.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        guard let cropped = cgImage.cropping(to: cropRect) else { return }

        let cols = max(2, Int(rect.width) / max(8, blockSize))
        let rows = max(2, Int(rect.height) / max(8, blockSize))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let smallCtx = CGContext(
            data: nil,
            width: cols,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: cols * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        smallCtx.interpolationQuality = .low
        smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        if let smallImg = smallCtx.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(smallImg, in: rect)
            ctx.restoreGState()
        }
    }

    private func drawFastBlur(in rect: CGRect, ctx: CGContext) {
        guard let cgImage = cgImage, rect.width >= 6, rect.height >= 6 else { return }
        let scaleX = CGFloat(cgImage.width) / max(1, bounds.width)
        let scaleY = CGFloat(cgImage.height) / max(1, bounds.height)
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: (bounds.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        guard let cropped = cgImage.cropping(to: cropRect) else { return }

        let cols = max(3, Int(rect.width / 10))
        let rows = max(3, Int(rect.height / 10))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let smallCtx = CGContext(
            data: nil,
            width: cols,
            height: rows,
            bitsPerComponent: 8,
            bytesPerRow: cols * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        smallCtx.interpolationQuality = .medium
        smallCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        if let smallImg = smallCtx.makeImage() {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(smallImg, in: rect)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        }
    }

    // MARK: - Mouse Events

    override public func mouseMoved(with event: NSEvent) {
        mouseLocationInView = convert(event.locationInWindow, from: nil)
        if currentTool == .selectMove { needsDisplay = true }
        if !hasLockedSelection {
            hoveredWindow = detectedWindows.first(where: { $0.frameInScreen.contains(mouseLocationInView) })
            needsDisplay = true
        } else if isRecordingSubbarExpanded && ScreenRecorderManager.shared.targetMode == .window {
            let previousFrame = hoveredWindow?.frameInScreen
            hoveredWindow = detectedWindows.first(where: { $0.frameInScreen.contains(mouseLocationInView) })
            if previousFrame != hoveredWindow?.frameInScreen { needsDisplay = true }
        }
    }

    override public func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseLocationInView = pt

        // Never intercept clicks aimed at the visible floating toolbar (ignore top 30pt transparent tooltip headroom)!
        if let tb = toolbarHostingView, !tb.isHidden {
            let visibleRect = CGRect(
                x: tb.frame.minX,
                y: tb.frame.minY,
                width: tb.frame.width,
                height: max(38, tb.frame.height - 30)
            )
            if visibleRect.insetBy(dx: -4, dy: -4).contains(pt) {
                return
            }
        }

        // In Window Recording mode (`窗口录制`), clicking any open window on screen selects that window!
        if isRecordingSubbarExpanded,
           ScreenRecorderManager.shared.targetMode == .window,
           let targetWin = detectedWindows.first(where: { $0.frameInScreen.contains(pt) }) {
            hoveredWindow = targetWin
            hasLockedSelection = true
            selectionRect = targetWin.frameInScreen
            updateToolbarView()
            needsDisplay = true
            return
        }

        let annotationAtPoint = annotations.indices.reversed().first(where: { annotations[$0].contains(pt) })
        if event.clickCount == 2,
           hasLockedSelection,
           selectionRect.contains(pt),
           annotationAtPoint == nil {
            triggerCopyAction()
            return
        }

        if !hasLockedSelection {
            guard !shortcutGuideFrame.contains(pt) else { return }
            interaction = .creatingSelection(start: pt)
            return
        }

        if let selectedIndex = annotations.firstIndex(where: { $0.id == selectedAnnotationID }),
           let handle = AnnotationGeometry.hitTestHandle(
                at: pt,
                for: annotations[selectedIndex],
                yAxisDown: false
           ) {
            let item = annotations[selectedIndex]
            switch handle {
            case .rotate:
                let center = item.transformCenter
                let startAngle = atan2(pt.y - center.y, pt.x - center.x)
                interaction = .rotatingAnnotation(id: item.id, initial: item, center: center, startAngle: startAngle)
            case .resize(let resizeHandle):
                let anchor = AnnotationGeometry.oppositeAnchor(
                    for: resizeHandle,
                    in: item.selectionBounds,
                    yAxisDown: false
                )
                let distance = max(4, hypot(pt.x - anchor.x, pt.y - anchor.y))
                interaction = .scalingAnnotation(id: item.id, initial: item, anchor: anchor, startDistance: distance)
            }
            return
        }

        if let index = annotationAtPoint {
            let item = annotations[index]
            if selectedAnnotationID == item.id {
                interaction = .movingAnnotation(id: item.id, initial: item, startMouse: pt)
            } else {
                selectedAnnotationID = item.id
                interaction = .selectingAnnotation(id: item.id)
            }
            needsDisplay = true
            return
        }
        selectedAnnotationID = nil

        if let handle = hitTestResizeHandle(at: pt, in: selectionRect) {
            interaction = .resizingSelection(handle: handle, initialRect: selectionRect)
            return
        }

        if selectionRect.contains(pt) {
            commitInlineTextIfNeeded()
            if currentTool == .selectMove {
                interaction = .movingSelection(startMouse: pt, initialRect: selectionRect)
            } else if currentTool == .counter {
                let item = SnipAnnotationItem(
                    tool: .counter,
                    startPoint: pt,
                    endPoint: pt,
                    color: strokeColor,
                    lineWidth: strokeWidth,
                    counterNumber: nextCounterValue
                )
                nextCounterValue += 1
                annotations.append(item)
                redoStack.removeAll()
                updateToolbarView()
                needsDisplay = true
            } else if currentTool == .text {
                beginInlineTextAnnotation(at: pt)
            } else {
                interaction = .drawingAnnotation
                activeAnnotation = SnipAnnotationItem(
                    tool: currentTool,
                    startPoint: pt,
                    endPoint: pt,
                    points: [pt],
                    color: strokeColor,
                    lineWidth: strokeWidth,
                    isFilled: isShapeFilled
                )
                needsDisplay = true
            }
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseLocationInView = pt
        updateDrag(to: pt)
    }

    private func updateDrag(to pt: CGPoint) {
        switch interaction {
        case .none:
            break

        case .creatingSelection(let start):
            let dx = abs(pt.x - start.x)
            let dy = abs(pt.y - start.y)
            if dx >= 4 || dy >= 4 {
                hasLockedSelection = true
                selectionRect = CGRect(
                    x: min(start.x, pt.x),
                    y: min(start.y, pt.y),
                    width: dx,
                    height: dy
                ).intersection(selectionLimit)
            }

        case .movingSelection(let startMouse, let initialRect):
            selectionRect = CapturePixelGeometry.moving(
                initialRect,
                by: CGPoint(x: pt.x - startMouse.x, y: pt.y - startMouse.y),
                within: selectionLimit
            )

        case .resizingSelection(let handle, let initialRect):
            selectionRect = resizedRect(from: initialRect, handle: handle, to: pt)

        case .drawingAnnotation:
            guard let tool = activeAnnotation?.tool else { break }
            let clampedPt = CGPoint(
                x: max(selectionRect.minX, min(pt.x, selectionRect.maxX)),
                y: max(selectionRect.minY, min(pt.y, selectionRect.maxY))
            )
            if tool == .pencil || tool == .marker {
                // Mutate optional storage directly: a local value copy keeps the
                // growing point array shared and forces a copy on every drag.
                activeAnnotation?.appendFreehandPoint(clampedPt)
            } else {
                activeAnnotation?.endPoint = clampedPt
            }
            needsDisplay = true

        case .selectingAnnotation:
            break

        case .movingAnnotation(let id, let initial, let startMouse):
            updateAnnotation(
                id: id,
                with: initial.translated(by: CGPoint(x: pt.x - startMouse.x, y: pt.y - startMouse.y))
            )

        case .scalingAnnotation(let id, let initial, let anchor, let startDistance):
            let currentDistance = hypot(pt.x - anchor.x, pt.y - anchor.y)
            updateAnnotation(id: id, with: initial.scaled(by: currentDistance / startDistance, around: anchor))

        case .rotatingAnnotation(let id, let initial, let center, let startAngle):
            let currentAngle = atan2(pt.y - center.y, pt.x - center.x)
            updateAnnotation(id: id, with: initial.rotated(by: (currentAngle - startAngle) * 180 / .pi))
        }
    }

    override public func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseLocationInView = pt

        var didCreateSelection = false
        switch interaction {
        case .creatingSelection(let start):
            let dx = abs(pt.x - start.x)
            let dy = abs(pt.y - start.y)
            if dx < 5 && dy < 5 {
                if let win = hoveredWindow {
                    hasLockedSelection = true
                    selectionRect = win.frameInScreen
                } else {
                    hasLockedSelection = true
                    selectionRect = CGRect(x: max(0, pt.x - 180), y: max(0, pt.y - 120), width: 360, height: 240)
                        .intersection(selectionLimit)
                }
            } else {
                hasLockedSelection = true
            }
            didCreateSelection = hasLockedSelection

        case .drawingAnnotation:
            if let active = activeAnnotation {
                annotations.append(active)
                redoStack.removeAll()
                activeAnnotation = nil
                updateToolbarView()
            }

        default:
            break
        }

        let shouldCopy = didCreateSelection && copyOnRelease
        interaction = .none
        needsDisplay = true
        if shouldCopy {
            triggerCopyAction()
        }
    }

    override public func rightMouseDown(with event: NSEvent) {
        if hasLockedSelection {
            hasLockedSelection = false
            annotations.removeAll()
            redoStack.removeAll()
            toolbarHostingView?.isHidden = true
            needsDisplay = true
        } else {
            onFinish()
        }
    }

    // MARK: - Keyboard Shortcuts

    override public func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53: // Esc
            onFinish()

        case 36, 76: // Return / Enter -> Copy & Finish
            triggerCopyAction()

        case 99: // F3 -> Pin to Screen!
            triggerPinAction()

        case 17 where flags.contains(.command): // Cmd + T -> Pin to Screen!
            triggerPinAction()

        case 1 where flags.contains(.command): // Cmd + S -> Save File
            triggerSaveFileAction()

        case 0 where flags.contains(.command): // Cmd + A -> Current screen
            commitInlineTextIfNeeded()
            interaction = .none
            selectedAnnotationID = nil
            hasLockedSelection = true
            selectionRect = capturedImageRect
            updateToolbarView()

        case 33 where flags.intersection([.command, .option, .control]).isEmpty: // [ -> Replay history
            replayHistory()

        case 30 where flags.intersection([.command, .option, .control]).isEmpty: // ] -> Captured cursor
            toggleCapturedCursor()

        case 13, 0, 1, 2: // WASD -> Source pixel
            guard flags.intersection([.command, .option, .control]).isEmpty else { return }
            moveCursor(keyCode: event.keyCode)

        case 6 where flags.contains([.command, .shift]): // Cmd + Shift + Z -> Redo
            redoAnnotation()

        case 6 where flags.contains(.command): // Cmd + Z -> Undo
            undoAnnotation()

        case 8 where !flags.contains(.command): // 'C' -> Copy pixel color under cursor!
            guard cgImage != nil, capturedImageRect.contains(mouseLocationInView) else { return }
            let (r, g, b, _) = sampleRGB(at: mouseLocationInView)
            let code = colorFormat.format(r: r, g: g, b: b)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            showToast(L10n.format("🎨 已复制色值: %@", code))

        case 123, 124, 125, 126: // Left, Right, Down, Up -> 1px nudge (10px with Shift)
            guard hasLockedSelection else { return }
            let step: CGFloat = flags.contains(.shift) ? 10.0 : 1.0
            let dx: CGFloat = event.keyCode == 123 ? -step : (event.keyCode == 124 ? step : 0)
            let dy: CGFloat = event.keyCode == 125 ? -step : (event.keyCode == 126 ? step : 0)
            let moved = CapturePixelGeometry.moving(
                selectionRect, by: CGPoint(x: dx * pixelStep.width, y: dy * pixelStep.height), within: capturedImageRect
            )
            let delta = CGPoint(x: moved.minX - selectionRect.minX, y: moved.minY - selectionRect.minY)
            annotations = annotations.map { $0.translated(by: delta) }
            redoStack = redoStack.map { $0.translated(by: delta) }
            selectionRect = moved

        default:
            break
        }
    }

    override public func flagsChanged(with event: NSEvent) {
        if event.keyCode == 56 || event.keyCode == 60 {
            if event.modifierFlags.contains(.shift),
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                colorFormat = colorFormat.next()
                needsDisplay = true
            }
        }
    }

    private func moveCursor(keyCode: UInt16) {
        guard cgImage != nil else { return }
        let dx: CGFloat = keyCode == 0 ? -pixelStep.width : (keyCode == 2 ? pixelStep.width : 0)
        let dy: CGFloat = keyCode == 1 ? -pixelStep.height : (keyCode == 13 ? pixelStep.height : 0)
        let point = CGPoint(
            x: max(capturedImageRect.minX, min(capturedImageRect.maxX - pixelStep.width / 2, mouseLocationInView.x + dx)),
            y: max(capturedImageRect.minY + pixelStep.height / 2, min(capturedImageRect.maxY, mouseLocationInView.y + dy))
        )
        mouseLocationInView = point
        if !hasLockedSelection {
            hoveredWindow = detectedWindows.first { $0.frameInScreen.contains(point) }
        }
        updateDrag(to: point)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? bounds.height
        CGWarpMouseCursorPosition(CGPoint(x: screenOrigin.x + point.x, y: primaryHeight - screenOrigin.y - point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        needsDisplay = true
    }

    private func toggleCapturedCursor() {
        guard liveCaptureState == nil else {
            showToast(L10n.string("历史截图没有单独的鼠标指针"))
            return
        }
        showsCapturedCursor.toggle()
        needsDisplay = true
        showToast(L10n.string(showsCapturedCursor ? "已显示截取的鼠标指针" : "已隐藏截取的鼠标指针"))
    }

    private func restoreLiveCapture() {
        guard let live = liveCaptureState else {
            showToast(L10n.string("已是最早的截图"))
            return
        }
        liveCaptureState = nil
        replayIndex = -1
        capturedImageRect = bounds
        setCapturedCGImage(live.image)
        annotations = live.annotations
        redoStack = live.redoStack
        hasLockedSelection = live.locked
        selectionRect = live.selection
        currentTool = live.tool
        nextCounterValue = live.counter
        detectedWindows = live.windows
        showsCapturedCursor = live.showsCursor
        hoveredWindow = detectedWindows.first { $0.frameInScreen.contains(mouseLocationInView) }
        interaction = .none
        selectedAnnotationID = nil
        updateToolbarView()
        showToast(L10n.string("已返回当前截图"))
    }

    private func replayHistory() {
        guard !isRecordingSubbarExpanded else { return }
        commitInlineTextIfNeeded()
        if liveCaptureState == nil {
            guard let cgImage else { return }
            replayRecords = screenshotHistory.records
            guard !replayRecords.isEmpty else {
                showToast(L10n.string("还没有截图记录"))
                return
            }
            liveCaptureState = LiveCaptureState(
                image: cgImage, selection: selectionRect, locked: hasLockedSelection,
                annotations: annotations, redoStack: redoStack, tool: currentTool,
                counter: nextCounterValue, windows: detectedWindows, showsCursor: showsCapturedCursor
            )
        }
        let nextIndex = replayIndex + 1
        if nextIndex >= replayRecords.count {
            restoreLiveCapture()
            return
        }
        let token = UUID()
        replayLoadToken = token
        replayIndex = nextIndex
        let record = replayRecords[nextIndex]
        let session = sessionID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let source = CGImageSourceCreateWithURL(record.fileURL as CFURL, nil)
            let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
            DispatchQueue.main.async {
                guard let self, self.sessionID == session, self.replayLoadToken == token else { return }
                guard let image, image.width > 0, image.height > 0 else {
                    self.showToast(L10n.string("无法读取这张图片。"))
                    return
                }
                let scale = min(self.bounds.width / CGFloat(image.width), self.bounds.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                self.capturedImageRect = CGRect(x: self.bounds.midX - size.width / 2, y: self.bounds.midY - size.height / 2,
                                                width: size.width, height: size.height)
                self.setCapturedCGImage(image)
                self.hasLockedSelection = true
                self.selectionRect = self.capturedImageRect
                self.annotations = []
                self.redoStack = []
                self.activeAnnotation = nil
                self.selectedAnnotationID = nil
                self.detectedWindows = []
                self.hoveredWindow = nil
                self.interaction = .none
                self.currentTool = .selectMove
                self.nextCounterValue = 1
                self.updateToolbarView()
                self.showToast(L10n.format("截图历史 %d / %d", nextIndex + 1, self.replayRecords.count))
            }
        }
    }

    // MARK: - Resize Handle Helpers

    private func handlePoint(for handle: ResizeHandlePosition, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func hitTestResizeHandle(at pt: CGPoint, in rect: CGRect) -> ResizeHandlePosition? {
        guard AppSettings.shared.capturePreferences.showAnchors else { return nil }
        for handle in ResizeHandlePosition.allCases {
            let hPt = handlePoint(for: handle, in: rect)
            if hypot(pt.x - hPt.x, pt.y - hPt.y) <= 8.0 {
                return handle
            }
        }
        return nil
    }

    private func resizedRect(from initial: CGRect, handle: ResizeHandlePosition, to pt: CGPoint) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY

        switch handle {
        case .topLeft:
            minX = pt.x; maxY = pt.y
        case .top:
            maxY = pt.y
        case .topRight:
            maxX = pt.x; maxY = pt.y
        case .right:
            maxX = pt.x
        case .bottomRight:
            maxX = pt.x; minY = pt.y
        case .bottom:
            minY = pt.y
        case .bottomLeft:
            minX = pt.x; minY = pt.y
        case .left:
            minX = pt.x
        }

        let x1 = min(minX, maxX)
        let x2 = max(minX, maxX)
        let y1 = min(minY, maxY)
        let y2 = max(minY, maxY)
        return CGRect(x: x1, y: y1, width: max(16, x2 - x1), height: max(16, y2 - y1)).intersection(selectionLimit)
    }

    // MARK: - Direct Inline Text Input on Canvas (Zero Modal Popup!)

    private func beginInlineTextAnnotation(at pt: CGPoint) {
        commitInlineTextIfNeeded()

        let font = currentTextFont
        let lineH = ceil(font.ascender - font.descender + font.leading)
        // Center the first line vertically on the click point
        let tf = NSTextField(frame: NSRect(x: pt.x - 2, y: pt.y - lineH / 2 - 2, width: 40, height: lineH + 4))
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false   // No background color — text sits directly on the image
        tf.backgroundColor = .clear
        tf.textColor = strokeColor
        tf.font = font
        tf.focusRingType = .none
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.placeholderAttributedString = NSAttributedString(
            string: L10n.string("输入文字"),
            attributes: [
                .font: font,
                .foregroundColor: strokeColor.withAlphaComponent(0.45)
            ]
        )
        tf.delegate = self
        tf.target = self
        tf.action = #selector(onInlineTextFieldSubmitted(_:))

        addSubview(tf)
        inlineTextField = tf
        resizeInlineTextFieldToFit()
        window?.makeFirstResponder(tf)
        updateInlineFieldInsertionColor()
    }

    /// Live-apply size / bold / italic / color changes to the text currently being typed
    private func applyTextStyleToInlineField() {
        guard let tf = inlineTextField else { return }
        let font = currentTextFont
        let oldLineH = tf.frame.height
        tf.font = font
        tf.textColor = strokeColor
        tf.placeholderAttributedString = NSAttributedString(
            string: L10n.string("输入文字"),
            attributes: [.font: font, .foregroundColor: strokeColor.withAlphaComponent(0.45)]
        )
        if let editor = tf.currentEditor() as? NSTextView {
            editor.font = font
            editor.textColor = strokeColor
            editor.typingAttributes[.font] = font
            editor.typingAttributes[.foregroundColor] = strokeColor
        }
        // Keep the vertical center stable while the font size changes
        let newLineH = ceil(font.ascender - font.descender + font.leading) + 4
        tf.frame.origin.y += (oldLineH - newLineH) / 2
        resizeInlineTextFieldToFit()
        updateInlineFieldInsertionColor()
        if tf.currentEditor() == nil {
            window?.makeFirstResponder(tf)
            tf.currentEditor()?.selectedRange = NSRange(location: (tf.stringValue as NSString).length, length: 0)
        }
    }

    private func updateInlineFieldInsertionColor() {
        (inlineTextField?.currentEditor() as? NSTextView)?.insertionPointColor = strokeColor
    }

    private func resizeInlineTextFieldToFit() {
        guard let tf = inlineTextField else { return }
        let font = currentTextFont
        let text = tf.stringValue.isEmpty ? L10n.string("输入文字") : tf.stringValue
        let size = (text as NSString).size(withAttributes: [.font: font])
        let lineH = ceil(font.ascender - font.descender + font.leading) + 4
        // Extra width for italic overhang + caret
        let width = ceil(size.width + (textItalic ? font.pointSize * 0.25 : 0) + 12)
        tf.frame.size = NSSize(width: max(40, width), height: lineH)
    }

    @objc private func onInlineTextFieldSubmitted(_ sender: NSTextField) {
        commitInlineTextIfNeeded()
        window?.makeFirstResponder(self)
    }

    public func commitInlineTextIfNeeded() {
        guard let tf = inlineTextField else { return }
        let str = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = currentTextFont
        // Store the center anchor so selection bounds match both the inline editor and rendered text.
        let origin = CGPoint(x: tf.frame.minX + 2, y: tf.frame.midY)
        tf.removeFromSuperview()
        inlineTextField = nil

        if !str.isEmpty {
            let item = SnipAnnotationItem(
                tool: .text,
                startPoint: origin,
                endPoint: origin,
                color: strokeColor,
                lineWidth: strokeWidth,
                text: str,
                fontSize: font.pointSize,
                isBold: textBold,
                isItalic: textItalic
            )
            annotations.append(item)
            selectedAnnotationID = nil
            redoStack.removeAll()
            updateToolbarView()
            needsDisplay = true
        }
    }

    // MARK: - Undo / Redo

    public func undoAnnotation() {
        commitInlineTextIfNeeded()
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        updateToolbarView()
        needsDisplay = true
    }

    public func redoAnnotation() {
        commitInlineTextIfNeeded()
        guard let item = redoStack.popLast() else { return }
        annotations.append(item)
        updateToolbarView()
        needsDisplay = true
    }

    // MARK: - Crop & Composite Annotated Output Image

    public func renderCroppedAnnotatedImage() -> (NSImage, CGRect)? {
        commitInlineTextIfNeeded()
        let targetRect: CGRect = hasLockedSelection
            ? selectionRect
            : (hoveredWindow?.frameInScreen ?? CGRect(x: 100, y: 100, width: 400, height: 300))

        guard targetRect.width >= 8, targetRect.height >= 8 else { return nil }

        // Ensure we have the underlying CGImage (if user clicked within 20ms of F1, capture synchronously)
        let baseCGImage: CGImage
        if let existing = cgImage {
            baseCGImage = existing
        } else {
            let winID = CGWindowID(max(0, window?.windowNumber ?? 0))
            guard let fallback = FastScreenCapture.captureScreen(quartzRect: .infinite, belowWindowID: winID) else {
                return nil
            }
            baseCGImage = fallback
        }

        guard let outputImage = PixelPreservingImageRenderer.capture(
            base: baseCGImage, screenBounds: bounds, imageRect: capturedImageRect, selection: targetRect,
            drawAnnotations: { ctx in
                drawCapturedCursor(in: ctx)
                for item in annotations {
                    drawAnnotationItem(item, in: ctx)
                }
            }
        ) else { return nil }

        let screenRect = CGRect(
            x: screenOrigin.x + targetRect.minX,
            y: screenOrigin.y + targetRect.minY,
            width: targetRect.width,
            height: targetRect.height
        )
        screenshotHistory.saveInBackground(outputImage)
        return (outputImage, screenRect)
    }

    // MARK: - Final Actions (Scrolling Capture / Pin F3 / In-Place Translate / Side OCR / Save / Copy)

    public func triggerScrollingCaptureAction() {
        commitInlineTextIfNeeded()
        let targetRect: CGRect = hasLockedSelection
            ? selectionRect
            : (hoveredWindow?.frameInScreen ?? CGRect(x: 100, y: 100, width: 480, height: 360))
        let screenRect = CGRect(
            x: screenOrigin.x + targetRect.minX,
            y: screenOrigin.y + targetRect.minY,
            width: targetRect.width,
            height: targetRect.height
        )
        onFinish()
        ScrollingCaptureEngine.shared.startScrollingCapture(screenRect: screenRect)
    }

    public func triggerScreenRecordAction() {
        commitInlineTextIfNeeded()
        let targetRect: CGRect = hasLockedSelection
            ? selectionRect
            : (hoveredWindow?.frameInScreen ?? CGRect(x: 100, y: 100, width: 640, height: 440))
        let screenRect = CGRect(
            x: screenOrigin.x + targetRect.minX,
            y: screenOrigin.y + targetRect.minY,
            width: targetRect.width,
            height: targetRect.height
        )
        onFinish()
        ScreenRecorderManager.shared.startRecording(screenRect: screenRect)
    }

    public func triggerPinAction() {
        guard let (image, screenRect) = renderCroppedAnnotatedImage() else { return }
        autoSaveFinishedSnip(image)
        onFinish()
        PinManager.shared.pinImage(image, at: screenRect)
    }

    public func triggerImageEffect(_ effect: VisionImageEffect) {
        guard !isApplyingImageEffect else { return }
        guard let (image, screenRect) = renderCroppedAnnotatedImage() else { return }
        isApplyingImageEffect = true
        showToast(effect.progressMessage)
        let sessionID = sessionID

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.sessionID == sessionID { self.isApplyingImageEffect = false } }
            do {
                let processed = try await VisionImageEffectsService.shared.apply(effect, to: image)
                guard self.sessionID == sessionID else { return }
                self.onFinish()
                self.autoSaveFinishedSnip(processed)
                PinManager.shared.pinImage(
                    processed,
                    at: screenRect,
                    startWithShadow: effect == .extractSubject ? false : nil
                )
            } catch {
                guard self.sessionID == sessionID else { return }
                self.showToast((error as? VisionImageEffectsError)?.errorDescription ?? L10n.string("无法生成图片效果。"))
            }
        }
    }

    private func triggerVisionTool(_ action: CaptureVisionToolAction) {
        guard hasLockedSelection else {
            showToast(L10n.string("请先框选要处理的截图区域"))
            return
        }
        guard let (image, _) = renderCroppedAnnotatedImage() else { return }

        switch action {
        case .scanBarcodes:
            guard !isScanningBarcodes else { return }
            isScanningBarcodes = true
            showToast(L10n.string("正在扫描二维码 / 条码…"))
            let sessionID = sessionID
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if self.sessionID == sessionID { self.isScanningBarcodes = false } }
                do {
                    let codes = try await VisionBarcodeScanningService.shared.scanBarcodes(in: image)
                    guard self.sessionID == sessionID else { return }
                    guard !codes.isEmpty else {
                        self.showToast(L10n.string("没有识别到二维码或条码"))
                        return
                    }
                    let copyText = codes.map(\.payload).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                    if codes.count == 1 {
                        let payload = codes[0].payload
                        let preview = payload.count > 32 ? String(payload.prefix(32)) + "…" : payload
                        self.showToast(L10n.format("扫码结果已复制：%@", preview))
                    } else {
                        self.showToast(L10n.format("扫描到 %d 个码，内容已复制", codes.count))
                    }
                } catch {
                    guard self.sessionID == sessionID else { return }
                    self.showToast(L10n.string("无法读取这张图片。"))
                }
            }
        }
    }

    /// Opens the Image 2 In-Place Image Translation Viewer directly!
    public func triggerOCRTranslateAction() {
        guard let (image, screenRect) = renderCroppedAnnotatedImage() else { return }
        onFinish()
        autoSaveFinishedSnip(image)
        PinManager.shared.pinImage(
            image,
            at: screenRect,
            startWithInPlaceTranslation: true,
            startWithOCRSidebar: false
        )
    }

    /// Opens the Image 1 Right-Side OCR Text Drawer Viewer directly!
    public func triggerOCRExtractAction() {
        guard let (image, screenRect) = renderCroppedAnnotatedImage() else { return }
        onFinish()
        autoSaveFinishedSnip(image)
        PinManager.shared.pinImage(
            image,
            at: screenRect,
            startWithInPlaceTranslation: false,
            startWithOCRSidebar: true
        )
    }

    public func triggerSaveFileAction() {
        guard let (image, _) = renderCroppedAnnotatedImage(),
              let imageSnapshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        autoSaveFinishedSnip(image)
        onFinish()
        let defaultName = SnapPreferences.fileName(
            pattern: AppSettings.shared.capturePreferences.fileNamePattern,
            at: Date()
        )

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = defaultName
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        if savePanel.runModal() == .OK, let url = savePanel.url {
            Task { _ = await PNGImageWriter.write(imageSnapshot, to: url) }
        }
    }

    public func triggerCopyAction() {
        guard let (image, _) = renderCroppedAnnotatedImage() else { return }
        autoSaveFinishedSnip(image)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        onFinish()
    }

    func copyNowOrArm() {
        if hasLockedSelection || hoveredWindow != nil {
            triggerCopyAction()
        } else {
            copyOnRelease = true
        }
    }

    func quickSaveSelection() {
        guard hasLockedSelection || hoveredWindow != nil,
              let (image, _) = renderCroppedAnnotatedImage() else {
            showToast(L10n.string("请先框选要保存的区域"))
            return
        }
        let preferences = AppSettings.shared.capturePreferences
        autoSaveFinishedSnip(image)
        let notify = preferences.quickSaveNotification
        let directory = preferences.quickSaveDirectoryURL()
        let pattern = preferences.fileNamePattern
        Task { @MainActor in
            let url = await PNGImageWriter.export(image, to: directory, pattern: pattern)
            guard notify else { return }
            if let url {
                self.showToast(L10n.format("已快速保存到 %@", url.lastPathComponent))
            } else {
                self.showToast(L10n.string("快速保存失败"))
            }
        }
    }

    private func autoSaveFinishedSnip(_ image: NSImage) {
        let preferences = AppSettings.shared.capturePreferences
        guard preferences.autoSaveEnabled else { return }
        let directory = preferences.autoSaveDirectoryURL()
        let pattern = preferences.fileNamePattern
        Task { _ = await PNGImageWriter.export(image, to: directory, pattern: pattern) }
    }

    private func drawFullscreenCrossLines(at point: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: bounds.minX, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        ctx.move(to: CGPoint(x: point.x, y: bounds.minY))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawMagnifierSelectionDecorations(loupeRect: CGRect, requested: CGRect, cell: CGFloat, in ctx: CGContext) {
        let preferences = AppSettings.shared.capturePreferences
        guard preferences.magnifierShowsMask || preferences.magnifierShowsBorder || preferences.magnifierShowsAnchors else { return }
        let active: CGRect? = hasLockedSelection ? selectionRect : hoveredWindow?.frameInScreen
        guard let active, active.width > 1, active.height > 1 else { return }
        let topLeft = loupePoint(for: CGPoint(x: active.minX, y: active.maxY), requested: requested, cell: cell, loupeRect: loupeRect)
        let bottomRight = loupePoint(for: CGPoint(x: active.maxX, y: active.minY), requested: requested, cell: cell, loupeRect: loupeRect)
        let magnified = CGRect(x: topLeft.x, y: bottomRight.y, width: bottomRight.x - topLeft.x, height: topLeft.y - bottomRight.y)

        if preferences.magnifierShowsMask {
            let path = CGMutablePath()
            path.addRect(loupeRect)
            path.addRect(magnified)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(
                srgbRed: preferences.maskRed,
                green: preferences.maskGreen,
                blue: preferences.maskBlue,
                alpha: preferences.maskAlpha
            ).cgColor)
            ctx.drawPath(using: .eoFill)
        }
        if preferences.magnifierShowsBorder {
            let scale = cell / max(pixelStep.width, 0.01)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(1, CGFloat(preferences.borderWidth) * scale))
            ctx.stroke(magnified)
        }
        if preferences.magnifierShowsAnchors, hasLockedSelection {
            let radius = max(2, 4.5 * cell / max(pixelStep.width, 0.01))
            let border = NSColor(
                srgbRed: preferences.anchorBorderRed,
                green: preferences.anchorBorderGreen,
                blue: preferences.anchorBorderBlue,
                alpha: preferences.anchorBorderAlpha
            )
            for handle in ResizeHandlePosition.allCases {
                let point = loupePoint(
                    for: handlePoint(for: handle, in: active),
                    requested: requested, cell: cell, loupeRect: loupeRect
                )
                let handleRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: handleRect)
                ctx.setStrokeColor(border.cgColor)
                ctx.setLineWidth(max(1, radius / 4))
                ctx.strokeEllipse(in: handleRect)
            }
        }
    }

    private func loupePoint(for viewPoint: CGPoint, requested: CGRect, cell: CGFloat, loupeRect: CGRect) -> CGPoint {
        let imageRect = capturedImageRect
        let imageSize = sourceImageSize
        let sourceX = (viewPoint.x - imageRect.minX) * imageSize.width / max(imageRect.width, 0.01)
        let sourceY = (imageRect.maxY - viewPoint.y) * imageSize.height / max(imageRect.height, 0.01)
        return CGPoint(
            x: loupeRect.minX + (sourceX - requested.minX) * cell,
            y: loupeRect.maxY - (sourceY - requested.minY) * cell
        )
    }
}

extension CaptureCanvasView: NSTextFieldDelegate {
    /// Grow the borderless text field as the user types
    public func controlTextDidChange(_ obj: Notification) {
        resizeInlineTextFieldToFit()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitInlineTextIfNeeded()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}

// MARK: - Pure Black Icon-Only Toolbar with Instant 0ms Tooltips (SwiftUI)

public struct CaptureToolbarSwiftUIView: View {
    public let selectedTool: SnipAnnotationTool
    public let isRecordingSubbarExpanded: Bool
    public let detectedWindows: [DetectedWindowInfo]
    public let selectedWindowRect: CGRect
    public let strokeColor: NSColor
    public let strokeWidth: CGFloat
    public let isFilled: Bool
    public let canUndo: Bool
    public let canRedo: Bool
    public let textFontSize: CGFloat
    public let textBold: Bool
    public let textItalic: Bool

    public let onSelectTool: (SnipAnnotationTool) -> Void
    public let onSelectColor: (NSColor) -> Void
    public let onSelectWidth: (CGFloat) -> Void
    public let onToggleFill: () -> Void
    public let onAdjustFontSize: (Bool) -> Void
    public let onToggleBold: () -> Void
    public let onToggleItalic: () -> Void
    public let onUndo: () -> Void
    public let onRedo: () -> Void
    public let onScrollingCapture: () -> Void
    public let onToggleRecordSubbar: () -> Void
    public let onSelectRecordingMode: (RecordingTargetMode) -> Void
    public let onSelectDetectedWindow: (DetectedWindowInfo) -> Void
    public let onStartRecordingNow: () -> Void
    public let onPinToScreen: () -> Void
    public let onApplyImageEffect: (VisionImageEffect) -> Void
    public let onVisionTool: (CaptureVisionToolAction) -> Void
    public let onOCRTranslate: () -> Void
    public let onOCRExtract: () -> Void
    public let onSaveFile: () -> Void
    public let onCancel: () -> Void
    public let onCopyConfirm: () -> Void

    @ObservedObject private var recorder = ScreenRecorderManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private let palette: [NSColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemBlue,
        .systemPurple,
        .white
    ]

    public var body: some View {
        VStack(alignment: .center, spacing: 6) {
            // Row 1: Pure Black Icon-Only Bar with Instant 0ms Hover Tooltips
            HStack(spacing: 2) {
                ForEach(SnipAnnotationTool.allCases.filter { $0 != .selectMove }) { tool in
                    InstantBlackIconButton(
                        icon: tool.iconName,
                        isSelected: selectedTool == tool,
                        tooltip: tool.rawValue,
                        action: { onSelectTool(tool) }
                    )
                }

                toolbarDivider

                InstantBlackIconButton(
                    icon: "arrow.uturn.backward",
                    isDisabled: !canUndo,
                    tooltip: "撤销 (⌘Z)",
                    action: onUndo
                )

                InstantBlackIconButton(
                    icon: "arrow.uturn.forward",
                    isDisabled: !canRedo,
                    tooltip: "重做 (⌘⇧Z)",
                    action: onRedo
                )

                toolbarDivider

                // Scrolling Long Capture (微信级滑动长截图)
                InstantBlackIconButton(
                    icon: "arrow.up.and.down.text.horizontal",
                    tooltip: "长截图",
                    action: onScrollingCapture
                )

                // Screen Recorder Sub-Toolbar Toggle
                InstantBlackIconButton(
                    icon: "video",
                    isSelected: isRecordingSubbarExpanded,
                    tooltip: "录屏",
                    action: onToggleRecordSubbar
                )

                // WeChat-style In-Place Image Translation ([文A])
                InstantBlackIconButton(
                    icon: "wechat:translate",
                    tooltip: "翻译",
                    action: onOCRTranslate
                )

                // WeChat-style OCR Text Extraction (⌜A⌟)
                InstantBlackIconButton(
                    icon: "wechat:ocr",
                    tooltip: "提取文字",
                    action: onOCRExtract
                )

                InstantBlackIconButton(
                    icon: "drop.halffull",
                    tooltip: "背景虚化",
                    action: { onApplyImageEffect(.blurBackground) }
                )

                InstantBlackIconButton(
                    icon: "person.crop.rectangle",
                    tooltip: "提取主体（透明背景）",
                    action: { onApplyImageEffect(.extractSubject) }
                )

                InstantBlackIconButton(
                    icon: "qrcode.viewfinder",
                    tooltip: L10n.string("扫描二维码 / 条码"),
                    action: { onVisionTool(.scanBarcodes) }
                )

                // Pin to Screen (F3)
                InstantBlackIconButton(
                    icon: "pin",
                    tooltip: "贴图 (F3)",
                    action: onPinToScreen
                )

                // Save File (Cmd+S)
                InstantBlackIconButton(
                    icon: "square.and.arrow.down",
                    tooltip: "保存 (⌘S)",
                    action: onSaveFile
                )

                toolbarDivider

                // Cancel (Esc)
                InstantBlackIconButton(
                    icon: "xmark",
                    tooltip: "取消 (Esc)",
                    action: onCancel
                )

                // Confirm Copy (Enter / Double-Click)
                InstantBlackIconButton(
                    icon: "checkmark",
                    tooltip: "完成复制 (Enter)",
                    action: onCopyConfirm
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                    )
            )
            .padding(.top, 30)

            // Row 2A: Pure-Black Screen Recording Sub-Toolbar (Default: 区域录屏, Consistent Black Style!)
            if isRecordingSubbarExpanded {
                VStack(alignment: .center, spacing: 6) {
                    HStack(spacing: 4) {
                        // Target modes: 区域 (Default) | 窗口 | 全屏
                        ForEach(RecordingTargetMode.allCases) { mode in
                            InstantBlackIconButton(
                                icon: mode.iconName,
                                isSelected: recorder.targetMode == mode,
                                tooltip: L10n.format("%@录制", mode.localizedLabel),
                                action: { onSelectRecordingMode(mode) }
                            )
                        }

                        toolbarDivider

                        // Countdown: 0s | 3s | 5s (with 0ms instant hover tooltips!)
                        ForEach([0, 3, 5], id: \.self) { sec in
                            InstantBlackTextPillButton(
                                label: sec == 0 ? "0s" : "\(sec)s",
                                isSelected: recorder.countdownSeconds == sec,
                                tooltip: sec == 0 ? "无倒计时 (立即录制)" : L10n.format("倒计时 %d 秒", sec),
                                action: { recorder.countdownSeconds = sec }
                            )
                        }

                        toolbarDivider

                        // Operation & Audio Overlays
                        InstantBlackIconButton(
                            icon: "cursorarrow",
                            isSelected: recorder.recordMouseCursor,
                            tooltip: "录制鼠标指针",
                            action: { recorder.recordMouseCursor.toggle() }
                        )

                        InstantBlackIconButton(
                            icon: "hand.tap",
                            isSelected: recorder.recordMouseClick,
                            tooltip: "录制点击波纹",
                            action: { recorder.recordMouseClick.toggle() }
                        )

                        InstantBlackIconButton(
                            icon: "keyboard",
                            isSelected: recorder.recordKeystrokes,
                            tooltip: "录制按键显示",
                            action: { recorder.recordKeystrokes.toggle() }
                        )

                        InstantBlackIconButton(
                            icon: "speaker.wave.2",
                            isSelected: recorder.recordSpeaker,
                            tooltip: "系统扬声器",
                            action: { recorder.recordSpeaker.toggle() }
                        )

                        InstantBlackIconButton(
                            icon: "mic",
                            isSelected: recorder.recordMicrophone,
                            tooltip: "麦克风",
                            action: { recorder.recordMicrophone.toggle() }
                        )

                        toolbarDivider

                        // Start Recording Button right on the sub-toolbar (with 0ms hover tooltip!)
                        InstantBlackStartRecordButton(
                            tooltip: "开始录制 (F10 结束)",
                            action: onStartRecordingNow
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                            )
                    )

                    // Row 2A-Sub: Open Window Selector when `.window` mode is active!
                    if recorder.targetMode == .window && !detectedWindows.isEmpty {
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "macwindow.on.rectangle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.75))
                                Text(L10n.string("选择打开的窗口:"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.78))
                                    .fixedSize()
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Array(detectedWindows.prefix(10))) { win in
                                        let isCurrent = abs(win.frameInScreen.minX - selectedWindowRect.minX) < 2
                                            && abs(win.frameInScreen.minY - selectedWindowRect.minY) < 2
                                            && abs(win.frameInScreen.width - selectedWindowRect.width) < 2
                                        Button(action: { onSelectDetectedWindow(win) }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: isCurrent ? "checkmark.circle.fill" : "macwindow")
                                                    .font(.system(size: 10.5))
                                                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isCurrent ? 1 : 0.7))
                                                Text(L10n.string(win.displayLabel))
                                                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium))
                                                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                                                    .fixedSize()
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                    .fill(isCurrent ? SnapLexTheme.toolbarSelection(for: colorScheme) : SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.06))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                            .strokeBorder(isCurrent ? SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.65) : Color.clear, lineWidth: 1)
                                                    )
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(width: min(460, CGFloat(detectedWindows.prefix(10).count) * 145), height: 28)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                                )
                        )
                    }
                }
            }

            // Row 2B: Secondary Style Bar when a drawing tool is selected (pure black theme)
            if selectedTool != .selectMove {
                HStack(spacing: 8) {
                    if selectedTool == .text {
                        // Text style: Bold / Italic / Font size (− 20 +)
                        InstantBlackIconButton(
                            icon: "glyph:B",
                            isSelected: textBold,
                            tooltip: "加粗",
                            action: onToggleBold
                        )
                        InstantBlackIconButton(
                            icon: "glyph:I",
                            isSelected: textItalic,
                            tooltip: "斜体",
                            action: onToggleItalic
                        )

                        toolbarDivider

                        InstantBlackIconButton(
                            icon: "minus",
                            isDisabled: textFontSize <= SnipTextStyle.minFontSize,
                            tooltip: "减小字号",
                            action: { onAdjustFontSize(false) }
                        )
                        Text("\(Int(textFontSize))")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme))
                            .frame(minWidth: 26)
                        InstantBlackIconButton(
                            icon: "plus",
                            isDisabled: textFontSize >= SnipTextStyle.maxFontSize,
                            tooltip: "增大字号",
                            action: { onAdjustFontSize(true) }
                        )
                    } else {
                        ForEach([2.0, 4.0, 8.0], id: \.self) { w in
                            Button(action: { onSelectWidth(CGFloat(w)) }) {
                                Circle()
                                    .fill(strokeWidth == CGFloat(w) ? SnapLexTheme.toolbarForeground(for: colorScheme) : SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.45))
                                    .frame(width: CGFloat(w) + 5, height: CGFloat(w) + 5)
                                    .frame(width: 22, height: 22)
                                    .background(
                                        Circle()
                                            .strokeBorder(strokeWidth == CGFloat(w) ? SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.8) : Color.clear, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if selectedTool == .rectangle || selectedTool == .ellipse {
                        toolbarDivider
                        InstantBlackIconButton(
                            icon: isFilled ? "square.fill" : "square",
                            tooltip: isFilled ? "实心" : "空心",
                            action: onToggleFill
                        )
                    }

                    toolbarDivider

                    ForEach(Array(palette.enumerated()), id: \.offset) { _, nsColor in
                        Button(action: { onSelectColor(nsColor) }) {
                            Circle()
                                .fill(Color(nsColor: nsColor))
                                .frame(width: 15, height: 15)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            strokeColor == nsColor ? SnapLexTheme.toolbarForeground(for: colorScheme) : SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.35),
                                            lineWidth: strokeColor == nsColor ? 2.2 : 1.0
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 1)
                        )
                )
            }
        }
        .snapLexAppearance()
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.18))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }
}
