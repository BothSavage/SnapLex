import XCTest
@testable import SnapLex

final class PermissionCoordinatorTests: XCTestCase {
    func testOptionalMicrophoneCanBeDeferredWithoutHidingMissingOtherPermissions() {
        let microphoneMissing = PermissionSnapshot(screenRecording: .granted, accessibility: .granted,
                                                   inputMonitoring: .granted, microphone: .notRequested)
        XCTAssertTrue(microphoneMissing.shouldPresentAtStartup(optionalDeferred: false))
        XCTAssertFalse(microphoneMissing.shouldPresentAtStartup(optionalDeferred: true))

        let accessibilityMissing = PermissionSnapshot(screenRecording: .granted, accessibility: .needsSetup,
                                                      inputMonitoring: .granted, microphone: .notRequested)
        XCTAssertTrue(accessibilityMissing.shouldPresentAtStartup(optionalDeferred: true))
        XCTAssertEqual(accessibilityMissing[.accessibility], .needsSetup)
        XCTAssertEqual(accessibilityMissing[.microphone], .notRequested)
    }

    @MainActor
    func testConcurrentRefreshCallsDeliverStartupCallbackAndPublishStatus() async {
        let expected = PermissionSnapshot(screenRecording: .granted, accessibility: .needsSetup,
                                          inputMonitoring: .granted, microphone: .restricted)
        let coordinator = PermissionCoordinator(readPermissions: { expected }, observeActivation: false)
        let completed = expectation(description: "startup scan completed")
        coordinator.refresh()
        coordinator.refresh { snapshot in
            XCTAssertEqual(snapshot, expected)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(coordinator.snapshot, expected)
    }

    func testSettingsLinksMatchEachPermission() {
        XCTAssertTrue(SnapLexPermission.screenRecording.settingsURL?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        XCTAssertTrue(SnapLexPermission.accessibility.settingsURL?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        XCTAssertTrue(SnapLexPermission.inputMonitoring.settingsURL?.absoluteString.hasSuffix("Privacy_ListenEvent") == true)
        XCTAssertTrue(SnapLexPermission.microphone.settingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)
    }
}
