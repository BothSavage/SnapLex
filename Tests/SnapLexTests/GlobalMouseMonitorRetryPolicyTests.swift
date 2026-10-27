import XCTest
@testable import SnapLex

final class GlobalMouseMonitorRetryPolicyTests: XCTestCase {
    func testInitialRegistrationIsAttemptedImmediatelyWhenEitherMonitorIsMissing() {
        XCTAssertTrue(shouldAttempt(lastAttempt: nil, down: false, up: false))
        XCTAssertTrue(shouldAttempt(lastAttempt: nil, down: true, up: false))
        XCTAssertTrue(shouldAttempt(lastAttempt: nil, down: false, up: true))
    }

    func testNoRetryIsNeededWhenBothMonitorsAreRegistered() {
        XCTAssertFalse(shouldAttempt(lastAttempt: nil, down: true, up: true))
        XCTAssertFalse(shouldAttempt(lastAttempt: 1, down: true, up: true, now: 100))
    }

    func testRetryWaitsUntilBackoffBoundary() {
        XCTAssertFalse(shouldAttempt(lastAttempt: 10, down: false, up: false, now: 14.999))
        XCTAssertTrue(shouldAttempt(lastAttempt: 10, down: false, up: false, now: 15))
        XCTAssertTrue(shouldAttempt(lastAttempt: 10, down: true, up: false, now: 15))
    }

    func testPermissionGrantCanForceImmediateRetry() {
        XCTAssertTrue(shouldAttempt(lastAttempt: 10, down: false, up: false, now: 10.1, force: true))
    }

    func testClockMovingBackwardsDoesNotCauseRetryStorm() {
        XCTAssertFalse(shouldAttempt(lastAttempt: 10, down: false, up: false, now: 9))
    }

    func testFiveSecondBackoffAcrossEveryPartialRegistrationState() {
        for down in [false, true] {
            for up in [false, true] {
                let expected = !(down && up)
                XCTAssertEqual(
                    shouldAttempt(lastAttempt: 2, down: down, up: up, now: 7),
                    expected,
                    "down=\(down), up=\(up)"
                )
            }
        }
    }

    private func shouldAttempt(
        lastAttempt: TimeInterval?,
        down: Bool,
        up: Bool,
        now: TimeInterval = 0,
        force: Bool = false
    ) -> Bool {
        GlobalMouseMonitorRetryPolicy.shouldAttempt(
            now: now,
            lastAttempt: lastAttempt,
            downRegistered: down,
            upRegistered: up,
            force: force
        )
    }
}
