import XCTest
@testable import SnapLex

final class ScreenCapturePermissionGateTests: XCTestCase {
    func testAuthorizedCaptureDoesNotRequestPermission() {
        var requestCount = 0

        let canCapture = ScreenCapturePermissionGate.ensureAccess(
            preflight: { true },
            request: {
                requestCount += 1
                return false
            }
        )

        XCTAssertTrue(canCapture)
        XCTAssertEqual(requestCount, 0)
    }

    func testCaptureWaitsUntilPermissionIsGranted() {
        var authorized = false
        var requestCount = 0

        let canCapture = ScreenCapturePermissionGate.ensureAccess(
            preflight: { authorized },
            request: {
                requestCount += 1
                authorized = true
                return true
            }
        )

        XCTAssertTrue(canCapture)
        XCTAssertEqual(requestCount, 1)
    }

    func testDeniedOrPendingPermissionKeepsCaptureOverlayClosed() {
        var requestCount = 0

        let canCapture = ScreenCapturePermissionGate.ensureAccess(
            preflight: { false },
            request: {
                requestCount += 1
                return false
            }
        )

        XCTAssertFalse(canCapture)
        XCTAssertEqual(requestCount, 1)
    }
}
