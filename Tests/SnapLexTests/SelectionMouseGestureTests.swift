import XCTest
@testable import SnapLex

final class SelectionMouseGestureTests: XCTestCase {
    func testMouseGesturePreflightAcross3456PIDWindowAndTimingScenarios() {
        let ownPID: pid_t = 100
        let pids: [pid_t?] = [nil, ownPID, 200, 300]
        let distances: [Double] = [0, 10, 25]
        let durations: [TimeInterval] = [0.01, 0.1, 13]
        let clickCounts = [1, 2, 3]
        var scenarios = 0

        for downPID in pids {
            for upPID in pids {
                for downOwned in [false, true] {
                    for upOwned in [false, true] {
                        for distance in distances {
                            for duration in durations {
                                for clickCount in clickCounts {
                                    for isEnabled in [false, true] {
                                        var tracker = SelectionMouseGestureTracker()
                                        tracker.recordMouseDown(.init(
                                            x: 100,
                                            y: 100,
                                            timestamp: 1,
                                            processIdentifier: downPID,
                                            isInsideSnapLexWindow: downOwned
                                        ))
                                        let gesture = tracker.recordMouseUp(.init(
                                            x: 100 + distance,
                                            y: 100,
                                            timestamp: 1 + duration,
                                            processIdentifier: upPID,
                                            clickCount: clickCount,
                                            isInsideSnapLexWindow: upOwned
                                        ))!

                                        let expected: MouseSelectionGestureEvaluation
                                        let isSelection = (distance >= 10 && duration >= 0.05 && duration <= 12)
                                            || clickCount == 2
                                            || clickCount == 3
                                        if !isSelection {
                                            expected = .suppressed(.notSelectionGesture)
                                        } else if !isEnabled {
                                            expected = .suppressed(.settingDisabled)
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
                                                isEnabled: isEnabled
                                            ),
                                            expected,
                                            "downPID=\(String(describing: downPID)) upPID=\(String(describing: upPID)) downOwned=\(downOwned) upOwned=\(upOwned) distance=\(distance) duration=\(duration) clicks=\(clickCount) enabled=\(isEnabled)"
                                        )
                                        scenarios += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(scenarios, 3_456)
    }

    func testMouseUpFreezesCoordinatesTimePIDAndClickCountFromBothEvents() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 12, y: 24, timestamp: 10, processIdentifier: 41))

        let gesture = tracker.recordMouseUp(.init(
            x: 80,
            y: 98,
            timestamp: 10.25,
            processIdentifier: 41,
            clickCount: 1
        ))

        XCTAssertEqual(gesture?.down.x, 12)
        XCTAssertEqual(gesture?.down.y, 24)
        XCTAssertEqual(gesture?.down.processIdentifier, 41)
        XCTAssertEqual(gesture?.up.x, 80)
        XCTAssertEqual(gesture?.up.y, 98)
        XCTAssertEqual(gesture?.up.processIdentifier, 41)
        XCTAssertEqual(gesture?.up.clickCount, 1)
        XCTAssertEqual(gesture?.duration ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(gesture?.distance ?? 0, hypot(68.0, 74.0), accuracy: 0.0001)
    }

    func testSecondMouseDownSupersedesAnUnmatchedFirstDown() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 1, y: 2, timestamp: 3, processIdentifier: 10))
        tracker.recordMouseDown(.init(x: 30, y: 40, timestamp: 4, processIdentifier: 20))

        let gesture = tracker.recordMouseUp(.init(
            x: 50,
            y: 70,
            timestamp: 4.3,
            processIdentifier: 20,
            clickCount: 1
        ))

        XCTAssertEqual(gesture?.down.x, 30)
        XCTAssertEqual(gesture?.down.y, 40)
        XCTAssertEqual(gesture?.down.processIdentifier, 20)
        XCTAssertEqual(gesture?.generation, 2)
    }

    func testCompletedGestureIsConsumedAndCannotBeReusedByAnotherMouseUp() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 10, y: 10, timestamp: 1, processIdentifier: 7))

        let first = tracker.recordMouseUp(.init(x: 20, y: 20, timestamp: 1.1, processIdentifier: 7, clickCount: 1))
        let orphanUp = tracker.recordMouseUp(.init(x: 25, y: 25, timestamp: 1.2, processIdentifier: 7, clickCount: 1))

        XCTAssertNotNil(first)
        XCTAssertNil(orphanUp)
    }

    func testLaterGestureInvalidatesAnEarlierQueuedAsyncResult() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 0, y: 0, timestamp: 1, processIdentifier: 12))
        let first = tracker.recordMouseUp(.init(x: 20, y: 20, timestamp: 1.1, processIdentifier: 12, clickCount: 1))
        tracker.recordMouseDown(.init(x: 100, y: 100, timestamp: 1.2, processIdentifier: 12))
        let second = tracker.recordMouseUp(.init(x: 140, y: 130, timestamp: 1.3, processIdentifier: 12, clickCount: 1))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(tracker.isCurrent(first!))
        XCTAssertTrue(tracker.isCurrent(second!))
        XCTAssertEqual(first?.down.x, 0)
        XCTAssertEqual(second?.down.x, 100)
    }

    func testOlderAsyncGestureIsInvalidatedImmediatelyAtTheNextMouseDown() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 0, y: 0, timestamp: 1, processIdentifier: 12))
        let first = tracker.recordMouseUp(.init(x: 20, y: 20, timestamp: 1.1, processIdentifier: 12, clickCount: 1))
        tracker.recordMouseDown(.init(x: 100, y: 100, timestamp: 1.2, processIdentifier: 12))

        XCTAssertNotNil(first)
        XCTAssertFalse(tracker.isCurrent(first!))
    }

    func testSwitchFromAnotherExternalAppIsPreservedForPolicyRejection() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 10, y: 10, timestamp: 1, processIdentifier: 51))

        let gesture = tracker.recordMouseUp(.init(x: 30, y: 30, timestamp: 1.2, processIdentifier: 52, clickCount: 1))

        XCTAssertEqual(gesture?.down.processIdentifier, 51)
        XCTAssertEqual(gesture?.up.processIdentifier, 52)
        XCTAssertFalse(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: gesture?.down.processIdentifier,
            mouseUpProcessIdentifier: gesture?.up.processIdentifier,
            ownProcessIdentifier: 99
        ))
    }

    func testMouseDownInsideSnapLexStillKeepsItsOwnProcessIdentity() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 2, y: 4, timestamp: 1, processIdentifier: 99))

        let gesture = tracker.recordMouseUp(.init(x: 40, y: 50, timestamp: 1.1, processIdentifier: 99, clickCount: 1))

        XCTAssertFalse(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: gesture?.down.processIdentifier,
            mouseUpProcessIdentifier: gesture?.up.processIdentifier,
            ownProcessIdentifier: 99
        ))
    }

    func testFirstClickIntoInactiveAppCanStartSelectionOutsideSnapLexWindows() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(
            x: 10,
            y: 10,
            timestamp: 1,
            processIdentifier: 99,
            isInsideSnapLexWindow: false
        ))
        let gesture = tracker.recordMouseUp(.init(
            x: 60,
            y: 10,
            timestamp: 1.2,
            processIdentifier: 42,
            clickCount: 1
        ))!

        XCTAssertEqual(
            SelectionTriggerPolicy.evaluateMouseSelection(
                gesture: gesture,
                ownProcessIdentifier: 99,
                isEnabled: true
            ),
            .eligible
        )
    }

    func testGestureStartingInsideSnapLexWindowIsMarkedAsOwnedEvenIfAppPIDStaysExternal() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(
            x: 10,
            y: 10,
            timestamp: 1,
            processIdentifier: 7,
            isInsideSnapLexWindow: true
        ))

        let gesture = tracker.recordMouseUp(.init(
            x: 50,
            y: 50,
            timestamp: 1.1,
            processIdentifier: 7,
            clickCount: 1
        ))

        XCTAssertTrue(gesture?.touchesSnapLexWindow == true)
    }

    func testGestureEndingInsideSnapLexWindowIsMarkedAsOwned() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 10, y: 10, timestamp: 1, processIdentifier: 7))

        let gesture = tracker.recordMouseUp(.init(
            x: 50,
            y: 50,
            timestamp: 1.1,
            processIdentifier: 7,
            clickCount: 1,
            isInsideSnapLexWindow: true
        ))

        XCTAssertTrue(gesture?.touchesSnapLexWindow == true)
    }

    func testExternalGestureIsNotSuppressedByWindowOwnership() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 10, y: 10, timestamp: 1, processIdentifier: 7))

        let gesture = tracker.recordMouseUp(.init(x: 50, y: 50, timestamp: 1.1, processIdentifier: 7, clickCount: 1))

        XCTAssertFalse(gesture?.touchesSnapLexWindow == true)
    }

    func testRightMouseDownCancelsLeftMouseGesturePairing() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 10, y: 10, timestamp: 1, processIdentifier: 7))
        tracker.cancelPendingGesture()

        let leftMouseUp = tracker.recordMouseUp(.init(x: 50, y: 50, timestamp: 1.1, processIdentifier: 7, clickCount: 1))

        XCTAssertNil(leftMouseUp)
    }

    func testRightMouseDownInvalidatesAnInFlightLeftMouseGesture() {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(x: 10, y: 10, timestamp: 1, processIdentifier: 7))
        let leftGesture = tracker.recordMouseUp(.init(x: 50, y: 50, timestamp: 1.1, processIdentifier: 7, clickCount: 1))
        tracker.cancelPendingGesture()

        XCTAssertNotNil(leftGesture)
        XCTAssertFalse(tracker.isCurrent(leftGesture!))
        XCTAssertNil(tracker.recordMouseUp(.init(x: 60, y: 60, timestamp: 1.2, processIdentifier: 7, clickCount: 1)))
    }

    func testTrackerAllowsRapidSequentialGesturesWithoutSharingEventData() {
        var tracker = SelectionMouseGestureTracker()
        let firstGeneration = tracker.recordMouseDown(.init(x: 1, y: 2, timestamp: 1, processIdentifier: 31))
        let first = tracker.recordMouseUp(.init(x: 11, y: 12, timestamp: 1.1, processIdentifier: 31, clickCount: 1))
        let secondGeneration = tracker.recordMouseDown(.init(x: 101, y: 202, timestamp: 1.2, processIdentifier: 32))
        let second = tracker.recordMouseUp(.init(x: 211, y: 212, timestamp: 1.3, processIdentifier: 32, clickCount: 2))

        XCTAssertEqual(firstGeneration, 1)
        XCTAssertEqual(secondGeneration, 2)
        XCTAssertEqual(first?.down.x, 1)
        XCTAssertEqual(first?.up.x, 11)
        XCTAssertEqual(second?.down.x, 101)
        XCTAssertEqual(second?.up.x, 211)
        XCTAssertEqual(second?.up.clickCount, 2)
    }
}
