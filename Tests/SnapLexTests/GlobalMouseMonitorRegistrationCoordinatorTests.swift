import XCTest
@testable import SnapLex

@MainActor
final class GlobalMouseMonitorRegistrationCoordinatorTests: XCTestCase {
    func testInitialAttemptTriesBothMonitorsExactlyOnce() {
        var coordinator = GlobalMouseMonitorRegistrationCoordinator()
        var downAttempts = 0
        var upAttempts = 0

        let attempted = coordinator.ensureRegistered(
            now: 10,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        )

        XCTAssertTrue(attempted)
        XCTAssertEqual(downAttempts, 1)
        XCTAssertEqual(upAttempts, 1)
        XCTAssertTrue(coordinator.downRegistered)
        XCTAssertTrue(coordinator.upRegistered)
    }

    func testPartialFailureRetriesOnlyMissingMonitorAfterBackoff() {
        var coordinator = GlobalMouseMonitorRegistrationCoordinator()
        var downAttempts = 0
        var upAttempts = 0

        coordinator.ensureRegistered(
            now: 10,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return false }
        )
        XCTAssertFalse(coordinator.ensureRegistered(
            now: 14,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ))
        XCTAssertEqual(coordinator.ensureRegistered(
            now: 15,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ), true)

        XCTAssertEqual(downAttempts, 1)
        XCTAssertEqual(upAttempts, 2)
        XCTAssertTrue(coordinator.downRegistered)
        XCTAssertTrue(coordinator.upRegistered)
    }

    func testPermissionChangeCanForceRetryAndSuccessfulMonitorsAreNotDuplicated() {
        var coordinator = GlobalMouseMonitorRegistrationCoordinator()
        var downAttempts = 0
        var upAttempts = 0

        coordinator.ensureRegistered(
            now: 20,
            registerDown: { downAttempts += 1; return false },
            registerUp: { upAttempts += 1; return true }
        )
        XCTAssertTrue(coordinator.ensureRegistered(
            now: 20.1,
            force: true,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ))
        XCTAssertFalse(coordinator.ensureRegistered(
            now: 200,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ))

        XCTAssertEqual(downAttempts, 2)
        XCTAssertEqual(upAttempts, 1)
        XCTAssertTrue(coordinator.downRegistered)
        XCTAssertTrue(coordinator.upRegistered)
    }

    func testPermissionChangeRefreshesPreviouslyRegisteredMonitors() {
        var coordinator = GlobalMouseMonitorRegistrationCoordinator()
        var downAttempts = 0
        var upAttempts = 0

        XCTAssertTrue(coordinator.ensureRegistered(
            now: 20,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ))
        XCTAssertFalse(coordinator.ensureRegistered(
            now: 20.1,
            force: true,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ), "force bypasses retry backoff; it must not duplicate live monitor tokens")

        coordinator.reset()

        XCTAssertTrue(coordinator.ensureRegistered(
            now: 20.2,
            force: true,
            registerDown: { downAttempts += 1; return true },
            registerUp: { upAttempts += 1; return true }
        ))
        XCTAssertEqual(downAttempts, 2)
        XCTAssertEqual(upAttempts, 2)
        XCTAssertTrue(coordinator.downRegistered)
        XCTAssertTrue(coordinator.upRegistered)
    }
}
