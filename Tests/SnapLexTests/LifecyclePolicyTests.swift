import XCTest
@testable import SnapLex

final class LifecyclePolicyTests: XCTestCase {
    func testRecordingStartGateAcrossAllEightCountdownRecordingFinalizationStates() {
        var scenarios = 0
        for countdown in [false, true] {
            for recording in [false, true] {
                for finalizing in [false, true] {
                    XCTAssertEqual(
                        ScreenRecordingStartPolicy.canStart(
                            isCountingDown: countdown,
                            isRecording: recording,
                            isFinalizing: finalizing
                        ),
                        !countdown && !recording && !finalizing,
                        "countdown=\(countdown) recording=\(recording) finalizing=\(finalizing)"
                    )
                    scenarios += 1
                }
            }
        }
        XCTAssertEqual(scenarios, 8)
    }

    func testRecentHistoryKeepsNewestFirstAndRespectsLimit() {
        var history: [Int] = []
        for item in 1...40 {
            history = RecentHistoryPolicy.inserting(item, into: history, limit: 25)
        }

        XCTAssertEqual(history.count, 25)
        XCTAssertEqual(history.first, 40)
        XCTAssertEqual(history.last, 16)
        XCTAssertEqual(history, Array((16...40).reversed()))
    }

    func testRecentHistoryLimitOneAndZero() {
        let one = RecentHistoryPolicy.inserting(2, into: [1], limit: 1)
        let none = RecentHistoryPolicy.inserting(2, into: [1], limit: 0)

        XCTAssertEqual(one, [2])
        XCTAssertTrue(none.isEmpty)
    }

    func testSmallBatchCloseHistoryAlwaysUsesSameBoundedInsertRule() {
        var history = Array((1...23).reversed())
        for item in 24...30 {
            history = RecentHistoryPolicy.inserting(item, into: history, limit: 25)
        }

        XCTAssertEqual(history.count, 25)
        XCTAssertEqual(history, Array((6...30).reversed()))
    }
}
