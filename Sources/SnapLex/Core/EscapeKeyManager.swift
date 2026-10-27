import AppKit

enum EscapeDismissalTarget: Equatable {
    case scrollingCapture
    case screenshotCapture
    case recordingCountdown
    case pinnedWindow
    case keyWindow
    case visiblePin
    case activeRecording
    case utilityWindow
    case none
}

enum EscapeKeyPolicy {
    static func isEscapeKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 53
    }

    static func dismissalTarget(
        isScrollingCaptureActive: Bool,
        isScreenshotCaptureActive: Bool,
        isRecordingCountdownActive: Bool,
        keyWindowIsPin: Bool,
        hasVisibleKeyWindow: Bool,
        hasVisiblePin: Bool,
        isRecordingActive: Bool,
        hasVisibleUtilityWindow: Bool
    ) -> EscapeDismissalTarget {
        if isScrollingCaptureActive { return .scrollingCapture }
        if isScreenshotCaptureActive { return .screenshotCapture }
        if isRecordingCountdownActive { return .recordingCountdown }
        if keyWindowIsPin { return .pinnedWindow }
        if hasVisibleKeyWindow { return .keyWindow }
        if hasVisiblePin { return .visiblePin }
        if isRecordingActive { return .activeRecording }
        if hasVisibleUtilityWindow { return .utilityWindow }
        return .none
    }
}

@MainActor
final class EscapeKeyManager {
    static let shared = EscapeKeyManager()

    private var localMonitor: Any?

    private init() {}

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard EscapeKeyPolicy.isEscapeKeyCode(event.keyCode) else { return event }

            // Let native modal panels process Escape (for example, canceling a Save panel).
            guard NSApp.modalWindow == nil else { return event }

            Task { @MainActor in
                self?.dismissActiveWindow()
            }
            return nil
        }
    }

    @discardableResult
    func dismissActiveWindow() -> EscapeDismissalTarget {
        let keyWindow = NSApp.keyWindow
        let pins = PinManager.shared.activePins
        let target = EscapeKeyPolicy.dismissalTarget(
            isScrollingCaptureActive: ScrollingCaptureEngine.shared.isCaptureActive,
            isScreenshotCaptureActive: CaptureManager.shared.isCapturing,
            isRecordingCountdownActive: ScreenRecorderManager.shared.isCountingDown,
            keyWindowIsPin: keyWindow is PinnedImageWindow,
            hasVisibleKeyWindow: keyWindow?.isVisible == true,
            hasVisiblePin: pins.contains(where: \.isVisible),
            isRecordingActive: ScreenRecorderManager.shared.isRecording,
            hasVisibleUtilityWindow: WindowManager.shared.hasVisibleUtilityWindow
        )

        switch target {
        case .scrollingCapture:
            ScrollingCaptureEngine.shared.cancelScrollingCapture()
        case .screenshotCapture:
            CaptureManager.shared.closeCapture()
        case .recordingCountdown:
            ScreenRecorderManager.shared.dismissForEscape()
        case .pinnedWindow:
            if let pin = keyWindow as? PinnedImageWindow {
                PinManager.shared.closePin(pin)
            }
        case .keyWindow:
            keyWindow?.orderOut(nil)
        case .visiblePin:
            if let pin = pins.last(where: \.isVisible) {
                PinManager.shared.closePin(pin)
            }
        case .activeRecording:
            ScreenRecorderManager.shared.dismissForEscape()
        case .utilityWindow:
            WindowManager.shared.dismissVisibleUtilityWindow()
        case .none:
            break
        }

        return target
    }
}
