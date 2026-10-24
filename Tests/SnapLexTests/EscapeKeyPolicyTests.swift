import XCTest
@testable import SnapLex

final class EscapeKeyPolicyTests: XCTestCase {
    func testRecognizesEscapeAndIgnoresOtherKeys() {
        XCTAssertTrue(EscapeKeyPolicy.isEscapeKeyCode(53))
        XCTAssertFalse(EscapeKeyPolicy.isEscapeKeyCode(36))
        XCTAssertFalse(EscapeKeyPolicy.isEscapeKeyCode(49))
    }

    func testCaptureModesTakePriorityOverFocusedWindows() {
        let scrollingTarget = EscapeKeyPolicy.dismissalTarget(
            isScrollingCaptureActive: true,
            isScreenshotCaptureActive: true,
            isRecordingCountdownActive: false,
            keyWindowIsPin: true,
            hasVisibleKeyWindow: true,
            hasVisiblePin: true,
            isRecordingActive: false,
            hasVisibleUtilityWindow: true
        )
        XCTAssertEqual(scrollingTarget, .scrollingCapture)

        let screenshotTarget = EscapeKeyPolicy.dismissalTarget(
            isScrollingCaptureActive: false,
            isScreenshotCaptureActive: true,
            isRecordingCountdownActive: false,
            keyWindowIsPin: true,
            hasVisibleKeyWindow: true,
            hasVisiblePin: true,
            isRecordingActive: false,
            hasVisibleUtilityWindow: true
        )
        XCTAssertEqual(screenshotTarget, .screenshotCapture)
    }

    func testPinnedWindowClosesEvenWhenItOwnsTheFocusedTextEditor() {
        let target = EscapeKeyPolicy.dismissalTarget(
            isScrollingCaptureActive: false,
            isScreenshotCaptureActive: false,
            isRecordingCountdownActive: false,
            keyWindowIsPin: true,
            hasVisibleKeyWindow: true,
            hasVisiblePin: true,
            isRecordingActive: false,
            hasVisibleUtilityWindow: false
        )

        XCTAssertEqual(target, .pinnedWindow)
    }

    func testFallbackDismissesVisiblePinOrUtilityWindow() {
        let pinTarget = EscapeKeyPolicy.dismissalTarget(
            isScrollingCaptureActive: false,
            isScreenshotCaptureActive: false,
            isRecordingCountdownActive: false,
            keyWindowIsPin: false,
            hasVisibleKeyWindow: false,
            hasVisiblePin: true,
            isRecordingActive: false,
            hasVisibleUtilityWindow: true
        )
        XCTAssertEqual(pinTarget, .visiblePin)

        let utilityTarget = EscapeKeyPolicy.dismissalTarget(
            isScrollingCaptureActive: false,
            isScreenshotCaptureActive: false,
            isRecordingCountdownActive: false,
            keyWindowIsPin: false,
            hasVisibleKeyWindow: false,
            hasVisiblePin: false,
            isRecordingActive: false,
            hasVisibleUtilityWindow: true
        )
        XCTAssertEqual(utilityTarget, .utilityWindow)
    }
}
