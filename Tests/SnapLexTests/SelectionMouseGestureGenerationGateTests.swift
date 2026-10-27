import XCTest
@testable import SnapLex

final class SelectionMouseGestureGenerationGateTests: XCTestCase {
    func testNewMouseGestureAndCancellationInvalidateQueuedOlderAXWork() {
        let gate = SelectionMouseGestureGenerationGate()

        gate.update(to: 12)
        XCTAssertTrue(gate.isCurrent(12))
        XCTAssertFalse(gate.isCurrent(11))

        gate.update(to: 13)
        XCTAssertFalse(gate.isCurrent(12))
        XCTAssertTrue(gate.isCurrent(13))
    }

    func testAccessibilityReaderSkipsAXCallsForSupersededQueuedGesture() async {
        let reader = SelectionAccessibilityReader()
        let gate = SelectionMouseGestureGenerationGate()
        gate.update(to: 2)

        let snapshot = await reader.inspectSelection(
            processIdentifier: getpid(),
            downX: 10,
            downY: 20,
            upX: 30,
            upY: 40,
            zeroScreenMaxY: 900,
            shouldProceed: { gate.isCurrent(1) }
        )

        XCTAssertNil(snapshot.selectedText)
        XCTAssertEqual(snapshot.accessibilityCallCount, 0)
        XCTAssertNil(snapshot.lastAccessibilityError)
        XCTAssertFalse(snapshot.timedOut, "a superseded request is cancellation, not an AX timeout")
    }

    func testGenerationUpdatesAcross256InterleavedGestureScenarios() {
        let gate = SelectionMouseGestureGenerationGate()
        var scenarios = 0

        for generation in 1...256 {
            let current = UInt64(generation)
            let previous = current - 1
            gate.update(to: current)
            scenarios += 1
            XCTAssertTrue(gate.isCurrent(current), "scenario=\(scenarios) current=\(current)")
            scenarios += 1
            XCTAssertFalse(gate.isCurrent(previous), "scenario=\(scenarios) stale=\(previous) current=\(current)")
            scenarios += 1
            XCTAssertFalse(gate.isCurrent(current + 1), "scenario=\(scenarios) future=\(current + 1) current=\(current)")
        }

        XCTAssertEqual(scenarios, 768)
    }
}
