import XCTest
@testable import SnapLex

@MainActor
final class SelectionMouseSelectionRecoveryTests: XCTestCase {
    func testNewSelectionSucceedsWhileSupersededSettleWaitIsDiscarded() async {
        var adapter = SelectionMouseEventAdapter()
        let firstGesture = completeGesture(&adapter, startTime: 10)
        let settleStarted = AsyncTestSignal()
        let settleGate = AsyncTestGate()
        var firstAccessibilityReads = 0
        var secondAccessibilityReads = 0
        var presentations: [String] = []

        let firstTask = Task {
            await SelectionMouseSelectionFlow.resolve(
                gesture: firstGesture,
                ownProcessIdentifier: 1,
                isEnabled: { true },
                isCurrentGesture: { adapter.isCurrent(firstGesture) },
                foregroundProcessIdentifier: { 42 },
                waitForSelectionToSettle: {
                    settleStarted.signal()
                    await settleGate.wait()
                },
                readAccessibility: { _ in
                    firstAccessibilityReads += 1
                    return makeSnapshot("stale first selection")
                },
                isDuplicate: { _, _ in false },
                onAccepted: { presentations.append($0) }
            )
        }

        await settleStarted.wait()
        let secondGesture = completeGesture(&adapter, startTime: 11)
        let secondOutcome = await SelectionMouseSelectionFlow.resolve(
            gesture: secondGesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { adapter.isCurrent(secondGesture) },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in
                secondAccessibilityReads += 1
                return makeSnapshot("latest selection")
            },
            isDuplicate: { _, _ in false },
            onAccepted: { presentations.append($0) }
        )

        settleGate.open()
        let firstOutcome = await firstTask.value

        XCTAssertEqual(secondOutcome, .accepted(makeSnapshot("latest selection")))
        XCTAssertEqual(firstOutcome, .cancelledBeforeAccessibility)
        XCTAssertEqual(firstAccessibilityReads, 0)
        XCTAssertEqual(secondAccessibilityReads, 1)
        XCTAssertEqual(presentations, ["latest selection"])
    }

    func testLatestSelectionWinsWhenOlderAccessibilityReplyArrivesLate() async {
        var adapter = SelectionMouseEventAdapter()
        let firstGesture = completeGesture(&adapter, startTime: 20)
        let accessibilityStarted = AsyncTestSignal()
        let accessibilityGate = AsyncTestGate()
        var firstAccessibilityReads = 0
        var secondAccessibilityReads = 0
        var presentations: [String] = []

        let firstTask = Task {
            await SelectionMouseSelectionFlow.resolve(
                gesture: firstGesture,
                ownProcessIdentifier: 1,
                isEnabled: { true },
                isCurrentGesture: { adapter.isCurrent(firstGesture) },
                foregroundProcessIdentifier: { 42 },
                waitForSelectionToSettle: {},
                readAccessibility: { _ in
                    firstAccessibilityReads += 1
                    accessibilityStarted.signal()
                    await accessibilityGate.wait()
                    return makeSnapshot("late older result")
                },
                isDuplicate: { _, _ in false },
                onAccepted: { presentations.append($0) }
            )
        }

        await accessibilityStarted.wait()
        let secondGesture = completeGesture(&adapter, startTime: 21)
        let secondOutcome = await SelectionMouseSelectionFlow.resolve(
            gesture: secondGesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { adapter.isCurrent(secondGesture) },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in
                secondAccessibilityReads += 1
                return makeSnapshot("new result")
            },
            isDuplicate: { _, _ in false },
            onAccepted: { presentations.append($0) }
        )

        accessibilityGate.open()
        let firstOutcome = await firstTask.value

        XCTAssertEqual(secondOutcome, .accepted(makeSnapshot("new result")))
        XCTAssertEqual(firstOutcome, .cancelledAfterAccessibility(makeSnapshot("late older result")))
        XCTAssertEqual(firstAccessibilityReads, 1)
        XCTAssertEqual(secondAccessibilityReads, 1)
        XCTAssertEqual(presentations, ["new result"])
    }

    func testMissingForegroundBeforeSettleDoesNotSpendTimeOnAccessibility() async {
        let gesture = standaloneGesture(processIdentifier: 42)
        var settleWaits = 0
        var accessibilityReads = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { nil },
            waitForSelectionToSettle: { settleWaits += 1 },
            readAccessibility: { _ in
                accessibilityReads += 1
                return makeSnapshot("must not be read")
            },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("missing foreground app must not present a selection") }
        )

        XCTAssertEqual(outcome, .cancelledBeforeAccessibility)
        XCTAssertEqual(settleWaits, 0)
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testDuplicateGateReceivesTrimmedSelectionAndMouseUpTimestamp() async {
        let gesture = standaloneGesture(processIdentifier: 42, releaseTime: 42.75)
        var duplicateChecks = 0
        var presentations = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in makeSnapshot("  repeated term  ") },
            isDuplicate: { text, timestamp in
                duplicateChecks += 1
                XCTAssertEqual(text, "repeated term")
                XCTAssertEqual(timestamp, 42.75)
                return true
            },
            onAccepted: { _ in presentations += 1 }
        )

        guard case let .suppressedAfterAccessibility(reason, snapshot) = outcome else {
            return XCTFail("a duplicate candidate must be rejected after AX validation")
        }
        XCTAssertEqual(reason, .duplicate)
        XCTAssertEqual(snapshot.selectedText, "  repeated term  ")
        XCTAssertEqual(duplicateChecks, 1)
        XCTAssertEqual(presentations, 0)
    }

    private func completeGesture(
        _ adapter: inout SelectionMouseEventAdapter,
        startTime: TimeInterval
    ) -> SelectionMouseGestureSnapshot {
        _ = adapter.receive(.leftMouseDown(.init(
            x: 10,
            y: 20,
            timestamp: startTime,
            processIdentifier: 42
        )))
        guard case let .gestureCompleted(gesture) = adapter.receive(.leftMouseUp(.init(
            x: 50,
            y: 20,
            timestamp: startTime + 0.2,
            processIdentifier: 42,
            clickCount: 1
        ))) else {
            XCTFail("a matched down/up sequence should form one gesture")
            return standaloneGesture(processIdentifier: 42, releaseTime: startTime + 0.2)
        }
        return gesture
    }

    private func standaloneGesture(
        processIdentifier: pid_t?,
        releaseTime: TimeInterval = 10.2
    ) -> SelectionMouseGestureSnapshot {
        SelectionMouseGestureSnapshot(
            down: SelectionMouseDownSnapshot(
                x: 10,
                y: 20,
                timestamp: releaseTime - 0.2,
                processIdentifier: processIdentifier
            ),
            up: SelectionMouseUpSnapshot(
                x: 50,
                y: 20,
                timestamp: releaseTime,
                processIdentifier: processIdentifier,
                clickCount: 1
            ),
            generation: 1
        )
    }

    private func makeSnapshot(_ text: String) -> SelectionAXSnapshot {
        SelectionAXSnapshot(
            focusedTarget: .unavailable,
            focusedProcessIdentifier: nil,
            downTarget: .nonEditable,
            upTarget: .nonEditable,
            downProcessIdentifier: 42,
            upProcessIdentifier: 42,
            downAncestorLimitReached: false,
            upAncestorLimitReached: false,
            selectedText: text,
            durationMilliseconds: 8,
            queueWaitMilliseconds: 0,
            workerDurationMilliseconds: 8,
            accessibilityCallCount: 6,
            lastAccessibilityError: nil,
            timedOut: false
        )
    }
}

@MainActor
private final class AsyncTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class AsyncTestSignal {
    private var isSignalled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignalled else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        guard !isSignalled else { return }
        isSignalled = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
