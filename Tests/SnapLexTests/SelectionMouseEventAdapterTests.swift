import XCTest
@testable import SnapLex

final class SelectionMouseEventAdapterTests: XCTestCase {
    func testLeftDownAndUpBridgeProducesOneImmutableGestureThenOrphan() {
        var adapter = SelectionMouseEventAdapter()
        let down = SelectionMouseDownSnapshot(
            x: 10, y: 20, timestamp: 1, processIdentifier: 41
        )
        let up = SelectionMouseUpSnapshot(
            x: 45, y: 62, timestamp: 1.2, processIdentifier: 41, clickCount: 1
        )

        XCTAssertEqual(
            adapter.receive(.leftMouseDown(down)),
            .leftMouseDownRecorded(generation: 1, replacedPendingDown: false)
        )
        guard case let .gestureCompleted(gesture) = adapter.receive(.leftMouseUp(up)) else {
            return XCTFail("matching left mouse-up should complete the gesture")
        }

        XCTAssertEqual(gesture.down, down)
        XCTAssertEqual(gesture.up, up)
        XCTAssertTrue(adapter.isCurrent(gesture))
        XCTAssertEqual(adapter.receive(.leftMouseUp(up)), .orphanMouseUp)
    }

    func testRightMouseDownCancelsPendingLeftGestureAndItsLaterMouseUpIsOrphaned() {
        var adapter = SelectionMouseEventAdapter()
        _ = adapter.receive(.leftMouseDown(.init(
            x: 10, y: 20, timestamp: 1, processIdentifier: 41
        )))

        XCTAssertEqual(
            adapter.receive(.rightMouseDown),
            .rightMouseDownCancelled(generation: 2, cancelledPendingDown: true)
        )
        XCTAssertEqual(
            adapter.receive(.leftMouseUp(.init(
                x: 45, y: 62, timestamp: 1.2, processIdentifier: 41, clickCount: 1
            ))),
            .orphanMouseUp
        )
    }

    func testSecondLeftMouseDownSupersedesFirstAndPairUsesOnlyLatestSnapshot() {
        var adapter = SelectionMouseEventAdapter()
        let firstDown = SelectionMouseDownSnapshot(
            x: 1, y: 2, timestamp: 1, processIdentifier: 41
        )
        let secondDown = SelectionMouseDownSnapshot(
            x: 90, y: 100, timestamp: 2, processIdentifier: 52
        )

        XCTAssertEqual(
            adapter.receive(.leftMouseDown(firstDown)),
            .leftMouseDownRecorded(generation: 1, replacedPendingDown: false)
        )
        XCTAssertEqual(
            adapter.receive(.leftMouseDown(secondDown)),
            .leftMouseDownRecorded(generation: 2, replacedPendingDown: true)
        )
        guard case let .gestureCompleted(gesture) = adapter.receive(.leftMouseUp(.init(
            x: 120, y: 135, timestamp: 2.2, processIdentifier: 52, clickCount: 1
        ))) else {
            return XCTFail("mouse-up should pair with the most recent mouse-down")
        }

        XCTAssertEqual(gesture.down, secondDown)
        XCTAssertEqual(gesture.generation, 2)
    }

    func testRightMouseDownInvalidatesAlreadyCompletedAsyncGesture() {
        var adapter = SelectionMouseEventAdapter()
        _ = adapter.receive(.leftMouseDown(.init(
            x: 10, y: 20, timestamp: 1, processIdentifier: 41
        )))
        guard case let .gestureCompleted(gesture) = adapter.receive(.leftMouseUp(.init(
            x: 45, y: 62, timestamp: 1.2, processIdentifier: 41, clickCount: 1
        ))) else {
            return XCTFail("left drag should produce a completed gesture")
        }

        _ = adapter.receive(.rightMouseDown)
        XCTAssertFalse(adapter.isCurrent(gesture))
    }

    func testWindowOwnershipIsFrozenAtBothGestureEndpoints() {
        var adapter = SelectionMouseEventAdapter()
        _ = adapter.receive(.leftMouseDown(.init(
            x: 10, y: 20, timestamp: 1, processIdentifier: 41,
            isInsideSnapLexWindow: true
        )))
        guard case let .gestureCompleted(gesture) = adapter.receive(.leftMouseUp(.init(
            x: 45, y: 62, timestamp: 1.2, processIdentifier: 41, clickCount: 1
        ))) else {
            return XCTFail("mouse-up should complete the gesture")
        }
        XCTAssertTrue(gesture.touchesSnapLexWindow)

        _ = adapter.receive(.leftMouseDown(.init(
            x: 100, y: 100, timestamp: 2, processIdentifier: 41
        )))
        guard case let .gestureCompleted(externalGesture) = adapter.receive(.leftMouseUp(.init(
            x: 135, y: 142, timestamp: 2.2, processIdentifier: 41,
            clickCount: 1, isInsideSnapLexWindow: false
        ))) else {
            return XCTFail("external mouse-up should complete the gesture")
        }
        XCTAssertFalse(externalGesture.touchesSnapLexWindow)
    }

    func testCompletedSelectionGestureSchedulesFlowExactlyOnce() {
        var adapter = SelectionMouseEventAdapter()
        var scheduled: [SelectionMouseGestureSnapshot] = []
        let events: [SelectionMouseEvent] = [
            .leftMouseDown(.init(x: 10, y: 20, timestamp: 1, processIdentifier: 41)),
            .leftMouseUp(.init(x: 45, y: 62, timestamp: 1.2, processIdentifier: 41, clickCount: 1)),
            .leftMouseUp(.init(x: 46, y: 63, timestamp: 1.21, processIdentifier: 41, clickCount: 1))
        ]

        for event in events {
            if case let .gestureCompleted(gesture) = adapter.receive(event) {
                scheduled.append(gesture)
            }
        }

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first?.down.processIdentifier, 41)
        XCTAssertEqual(scheduled.first?.up.processIdentifier, 41)
    }

    func testBridgePreservesOutcomeAcross384PIDWindowAndGestureScenarios() {
        let ownPID: pid_t = 99
        let downPIDs: [pid_t?] = [nil, 41, ownPID]
        let upPIDs: [pid_t?] = [nil, 41, 52, ownPID]
        let distances: [Double] = [5, 15]
        let durations: [TimeInterval] = [0.01, 0.1]
        let clickCounts = [1, 2]
        var scenarios = 0

        for downPID in downPIDs {
            for upPID in upPIDs {
                for downOwned in [false, true] {
                    for upOwned in [false, true] {
                        for distance in distances {
                            for duration in durations {
                                for clickCount in clickCounts {
                                    var adapter = SelectionMouseEventAdapter()
                                    let down = SelectionMouseDownSnapshot(
                                        x: 100,
                                        y: 200,
                                        timestamp: 10,
                                        processIdentifier: downPID,
                                        isInsideSnapLexWindow: downOwned
                                    )
                                    let up = SelectionMouseUpSnapshot(
                                        x: 100 + distance,
                                        y: 200,
                                        timestamp: 10 + duration,
                                        processIdentifier: upPID,
                                        clickCount: clickCount,
                                        isInsideSnapLexWindow: upOwned
                                    )

                                    XCTAssertEqual(
                                        adapter.receive(.leftMouseDown(down)),
                                        .leftMouseDownRecorded(generation: 1, replacedPendingDown: false)
                                    )
                                    guard case let .gestureCompleted(gesture) = adapter.receive(.leftMouseUp(up)) else {
                                        XCTFail("bridge lost a matched down/up pair")
                                        continue
                                    }
                                    XCTAssertEqual(gesture.down, down)
                                    XCTAssertEqual(gesture.up, up)

                                    let isSelectionGesture = (distance >= 10 && duration >= 0.05 && duration <= 12)
                                        || clickCount == 2
                                    let expected: MouseSelectionGestureEvaluation
                                    if !isSelectionGesture {
                                        expected = .suppressed(.notSelectionGesture)
                                    } else if downOwned || upOwned {
                                        expected = .suppressed(.touchesSnapLexWindow)
                                    } else if upPID == nil {
                                        expected = .suppressed(.foregroundChanged)
                                    } else if upPID == ownPID {
                                        expected = .suppressed(.snapLexIsFrontmost)
                                    } else if downPID == nil {
                                        expected = .suppressed(.foregroundChanged)
                                    } else if downPID != upPID && downPID != ownPID {
                                        expected = .suppressed(.foregroundChanged)
                                    } else {
                                        expected = .eligible
                                    }
                                    XCTAssertEqual(
                                        SelectionTriggerPolicy.evaluateMouseSelection(
                                            gesture: gesture,
                                            ownProcessIdentifier: ownPID,
                                            isEnabled: true
                                        ),
                                        expected,
                                        "downPID=\(String(describing: downPID)) upPID=\(String(describing: upPID)) downOwned=\(downOwned) upOwned=\(upOwned) distance=\(distance) duration=\(duration) clicks=\(clickCount)"
                                    )
                                    XCTAssertEqual(adapter.receive(.leftMouseUp(up)), .orphanMouseUp)
                                    scenarios += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(scenarios, 384)
    }
}
