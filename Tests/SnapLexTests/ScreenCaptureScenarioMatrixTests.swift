import XCTest
@testable import SnapLex

final class ScreenCaptureScenarioMatrixTests: XCTestCase {
    private enum CaptureEntry: String, CaseIterable {
        case region
        case window
        case fullScreen
    }

    func testPermissionPromptTransitionsForEveryCaptureEntry() {
        var scenarios = 0

        for entry in CaptureEntry.allCases {
            var requestCount = 0
            var preflightCount = 0
            let alreadyAuthorized = ScreenCapturePermissionGate.ensureAccess(
                preflight: {
                    preflightCount += 1
                    return true
                },
                request: {
                    requestCount += 1
                    XCTFail("An already-authorized \(entry.rawValue) capture must not request permission")
                    return false
                }
            )

            XCTAssertTrue(alreadyAuthorized, "entry=\(entry.rawValue) initialPermission=true")
            XCTAssertEqual(preflightCount, 1, "entry=\(entry.rawValue) initialPermission=true")
            XCTAssertEqual(requestCount, 0, "entry=\(entry.rawValue) initialPermission=true")
            scenarios += 1

            for requestResult in [false, true] {
                for permissionGrantedAfterPrompt in [false, true] {
                    var preflightCall = 0
                    var promptCount = 0
                    let mayShowCaptureUI = ScreenCapturePermissionGate.ensureAccess(
                        preflight: {
                            preflightCall += 1
                            return preflightCall == 1 ? false : permissionGrantedAfterPrompt
                        },
                        request: {
                            promptCount += 1
                            return requestResult
                        }
                    )

                    XCTAssertEqual(
                        mayShowCaptureUI,
                        permissionGrantedAfterPrompt,
                        "entry=\(entry.rawValue) promptResult=\(requestResult) postPromptPermission=\(permissionGrantedAfterPrompt)"
                    )
                    XCTAssertEqual(preflightCall, 2, "entry=\(entry.rawValue) promptResult=\(requestResult)")
                    XCTAssertEqual(promptCount, 1, "entry=\(entry.rawValue) promptResult=\(requestResult)")
                    scenarios += 1
                }
            }
        }

        XCTAssertEqual(scenarios, 15)
    }

    func testDeniedOrCancelledPromptCanRetryAfterPermissionBecomesAvailable() {
        var authorized = false
        var requestCount = 0

        let firstAttempt = ScreenCapturePermissionGate.ensureAccess(
            preflight: { authorized },
            request: {
                requestCount += 1
                return false // User dismissed the prompt or macOS has not applied the grant yet.
            }
        )

        XCTAssertFalse(firstAttempt)
        XCTAssertEqual(requestCount, 1)

        authorized = true
        let retry = ScreenCapturePermissionGate.ensureAccess(
            preflight: { authorized },
            request: {
                requestCount += 1
                return false
            }
        )

        XCTAssertTrue(retry, "A later user-initiated retry should use the fresh permission preflight")
        XCTAssertEqual(requestCount, 1, "Do not show another permission prompt after the grant is visible")
    }

    func testRecordingStartRetriesAfterEachTransientBusyStateClears() {
        let busyStates: [(name: String, countdown: Bool, recording: Bool, finalizing: Bool)] = [
            ("countdown", true, false, false),
            ("recording", false, true, false),
            ("finalizing", false, false, true)
        ]

        for state in busyStates {
            XCTAssertFalse(
                ScreenRecordingStartPolicy.canStart(
                    isCountingDown: state.countdown,
                    isRecording: state.recording,
                    isFinalizing: state.finalizing
                ),
                "busyState=\(state.name)"
            )
            XCTAssertTrue(
                ScreenRecordingStartPolicy.canStart(
                    isCountingDown: false,
                    isRecording: false,
                    isFinalizing: false
                ),
                "retryAfter=\(state.name)"
            )
        }
    }
}
