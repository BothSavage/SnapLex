import XCTest
@testable import SnapLex

private final class BlockingPermissionReader: @unchecked Sendable {
    let started: XCTestExpectation
    let secondRead: XCTestExpectation
    let unblock = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reads = 0

    init(started: XCTestExpectation, secondRead: XCTestExpectation) {
        self.started = started
        self.secondRead = secondRead
    }

    func read() -> PermissionSnapshot {
        lock.lock()
        reads += 1
        let number = reads
        lock.unlock()
        if number == 1 {
            started.fulfill()
            _ = unblock.wait(timeout: .now() + 3)
            return PermissionSnapshot(screenRecording: .needsSetup, accessibility: .granted,
                                      inputMonitoring: .granted, microphone: .granted)
        }
        if number == 2 { secondRead.fulfill() }
        return PermissionSnapshot(screenRecording: .granted, accessibility: .granted,
                                  inputMonitoring: .granted, microphone: .granted)
    }
}

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

    @MainActor
    func testRefreshRequestedDuringScanRunsAgainAndPicksUpNewPermission() async {
        let started = expectation(description: "first scan started")
        let secondRead = expectation(description: "second scan started")
        let reader = BlockingPermissionReader(started: started, secondRead: secondRead)
        let coordinator = PermissionCoordinator(readPermissions: { reader.read() }, observeActivation: false)
        coordinator.refresh()
        await fulfillment(of: [started], timeout: 2)
        coordinator.refresh()
        reader.unblock.signal()
        await fulfillment(of: [secondRead], timeout: 3)
        let published = expectation(description: "latest status published")
        coordinator.refresh { _ in published.fulfill() }
        await fulfillment(of: [published], timeout: 3)
        XCTAssertEqual(coordinator.snapshot.screenRecording, .granted)
    }

    @MainActor
    func testSettingsVisitSurvivesRelaunchAndEndsWhenGuideCloses() throws {
        let suite = "SnapLexPermissionGuideTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_000_000)
        let firstProcess = PermissionGuideSession(defaults: defaults, now: { date })
        XCTAssertFalse(firstProcess.isPending)
        firstProcess.begin()

        let relaunchedProcess = PermissionGuideSession(defaults: defaults, now: { date.addingTimeInterval(30) })
        XCTAssertTrue(relaunchedProcess.isPending)
        XCTAssertFalse(PermissionGuideSession(defaults: defaults, now: { date.addingTimeInterval(86_401) }).isPending)
        relaunchedProcess.finish()
        XCTAssertFalse(firstProcess.isPending)
    }

    func testReopenKeepsUserInPermissionGuideInsteadOfDashboard() {
        XCTAssertEqual(AppReopenTarget.resolve(guideVisible: true, permissionSessionPending: false, startupScanComplete: true), .permissionGuide)
        XCTAssertEqual(AppReopenTarget.resolve(guideVisible: false, permissionSessionPending: true, startupScanComplete: false), .permissionGuide)
        XCTAssertEqual(AppReopenTarget.resolve(guideVisible: false, permissionSessionPending: false, startupScanComplete: false), .waitForPermissionScan)
        XCTAssertEqual(AppReopenTarget.resolve(guideVisible: false, permissionSessionPending: false, startupScanComplete: true), .dashboard)
    }
}
