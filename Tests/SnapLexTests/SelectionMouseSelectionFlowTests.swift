import XCTest
@testable import SnapLex

@MainActor
final class SelectionMouseSelectionFlowTests: XCTestCase {
    func testAcceptedFlowReadsAccessibilityAndPresentsExactlyOnce() async {
        let gesture = makeGesture()
        let snapshot = makeAXSnapshot(text: "word")
        var accessibilityReads = 0
        var presentationTexts: [String] = []

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { receivedGesture in
                accessibilityReads += 1
                XCTAssertEqual(receivedGesture, gesture)
                return snapshot
            },
            isDuplicate: { _, _ in false },
            onAccepted: { presentationTexts.append($0) }
        )

        XCTAssertEqual(outcome, .accepted(snapshot))
        XCTAssertEqual(accessibilityReads, 1)
        XCTAssertEqual(presentationTexts, ["word"])
    }

    func testFocusedWebAreaFallbackFlowsThroughToSelectionPill() async {
        let gesture = makeGesture()
        let snapshot = makeAXSnapshot(
            text: "selected browser text",
            focusedTarget: .nonEditable
        )
        var presentationTexts: [String] = []

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in snapshot },
            isDuplicate: { _, _ in false },
            onAccepted: { presentationTexts.append($0) }
        )

        XCTAssertEqual(outcome, .accepted(snapshot))
        XCTAssertEqual(presentationTexts, ["selected browser text"])
    }

    func testFocusedWebAreaFallbackRecoversWhenHitTestEndpointsAreUnavailable() async {
        let gesture = makeGesture()
        let snapshot = makeAXSnapshot(
            text: "selected browser text",
            downTarget: .unavailable,
            upTarget: .unavailable,
            focusedTarget: .nonEditable,
            downProcessIdentifier: nil,
            upProcessIdentifier: nil
        )
        var presentationTexts: [String] = []

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in snapshot },
            isDuplicate: { _, _ in false },
            onAccepted: { presentationTexts.append($0) }
        )

        XCTAssertEqual(outcome, .accepted(snapshot))
        XCTAssertEqual(presentationTexts, ["selected browser text"])
    }

    func testUnavailableHitTestFallbackRejectsWrongFocusOwnerAndEditableEndpoint() async {
        var wrongFocusOwner = makeAXSnapshot(
            text: "must stay suppressed",
            downTarget: .unavailable,
            upTarget: .unavailable,
            focusedTarget: .nonEditable,
            downProcessIdentifier: nil,
            upProcessIdentifier: nil,
            focusedProcessIdentifier: 77
        )
        let wrongOwnerOutcome = await resolve(gesture: makeGesture(), snapshot: wrongFocusOwner)
        guard case let .suppressedAfterAccessibility(wrongOwnerReason, _) = wrongOwnerOutcome else {
            return XCTFail("focused selection from another process must be suppressed")
        }
        XCTAssertEqual(wrongOwnerReason, .timedOutOrWrongProcess)

        wrongFocusOwner = makeAXSnapshot(
            text: "must stay suppressed",
            downTarget: .editable,
            upTarget: .unavailable,
            focusedTarget: .nonEditable,
            downProcessIdentifier: 42,
            upProcessIdentifier: nil
        )
        let editableOutcome = await resolve(gesture: makeGesture(), snapshot: wrongFocusOwner)
        guard case let .suppressedAfterAccessibility(editableReason, _) = editableOutcome else {
            return XCTFail("an explicitly editable endpoint must always be suppressed")
        }
        XCTAssertEqual(editableReason, .editableOrUnknownEndpoint)
    }

    func testSelectionFlowAcross672InjectedLifecycleAndAXScenarios() async {
        enum AXCase: CaseIterable {
            case safeEndpoints
            case focusedFallback
            case editableEndpoint
            case untrustedUnknownEndpoints
            case foreignEndpoint
            case timedOut
            case emptyText
        }

        var scenarios = 0
        for disabledStage in 0...3 { // initially, after settle, after AX, never
            for staleStage in 0...3 { // before settle, after settle, after AX, never
                for foregroundSwitchStage in 0...2 { // never, during settle, during AX
                    for axCase in AXCase.allCases {
                        for duplicate in [false, true] {
                            scenarios += 1
                            var didSettle = false
                            var didReadAX = false
                            var accessibilityReads = 0
                            var presentationCount = 0
                            var foregroundPID: pid_t = 42

                            let snapshot: SelectionAXSnapshot
                            switch axCase {
                            case .safeEndpoints:
                                snapshot = makeAXSnapshot(text: "selected word")
                            case .focusedFallback:
                                snapshot = makeAXSnapshot(
                                    text: "selected browser text",
                                    downTarget: .unavailable,
                                    upTarget: .unavailable,
                                    focusedTarget: .nonEditable,
                                    downProcessIdentifier: nil,
                                    upProcessIdentifier: nil
                                )
                            case .editableEndpoint:
                                snapshot = makeAXSnapshot(text: "draft text", downTarget: .editable)
                            case .untrustedUnknownEndpoints:
                                snapshot = makeAXSnapshot(
                                    text: "stale selection",
                                    downTarget: .unavailable,
                                    upTarget: .unavailable,
                                    downProcessIdentifier: nil,
                                    upProcessIdentifier: nil
                                )
                            case .foreignEndpoint:
                                snapshot = makeAXSnapshot(text: "foreign", downProcessIdentifier: 77)
                            case .timedOut:
                                var timedOut = makeAXSnapshot(text: "too late")
                                timedOut = SelectionAXSnapshot(
                                    focusedTarget: timedOut.focusedTarget,
                                    focusedProcessIdentifier: timedOut.focusedProcessIdentifier,
                                    downTarget: timedOut.downTarget,
                                    upTarget: timedOut.upTarget,
                                    downProcessIdentifier: timedOut.downProcessIdentifier,
                                    upProcessIdentifier: timedOut.upProcessIdentifier,
                                    downAncestorLimitReached: false,
                                    upAncestorLimitReached: false,
                                    selectedText: timedOut.selectedText,
                                    durationMilliseconds: 280,
                                    queueWaitMilliseconds: 0,
                                    workerDurationMilliseconds: 280,
                                    accessibilityCallCount: 40,
                                    lastAccessibilityError: nil,
                                    timedOut: true
                                )
                                snapshot = timedOut
                            case .emptyText:
                                snapshot = makeAXSnapshot(text: " \n ")
                            }

                            let outcome = await SelectionMouseSelectionFlow.resolve(
                                gesture: makeGesture(),
                                ownProcessIdentifier: 1,
                                isEnabled: {
                                    switch disabledStage {
                                    case 0: return false
                                    case 1: return !didSettle
                                    case 2: return !didReadAX
                                    default: return true
                                    }
                                },
                                isCurrentGesture: {
                                    switch staleStage {
                                    case 1: return false
                                    case 2: return !didSettle
                                    case 3: return !didReadAX
                                    default: return true
                                    }
                                },
                                foregroundProcessIdentifier: { foregroundPID },
                                waitForSelectionToSettle: {
                                    didSettle = true
                                    if foregroundSwitchStage == 1 { foregroundPID = 77 }
                                },
                                readAccessibility: { _ in
                                    accessibilityReads += 1
                                    didReadAX = true
                                    if foregroundSwitchStage == 2 { foregroundPID = 77 }
                                    return snapshot
                                },
                                isDuplicate: { _, _ in duplicate },
                                onAccepted: { _ in presentationCount += 1 }
                            )

                            let shouldReadAX = disabledStage != 0
                                && disabledStage != 1
                                && staleStage != 1
                                && staleStage != 2
                                && foregroundSwitchStage != 1
                            XCTAssertEqual(accessibilityReads, shouldReadAX ? 1 : 0, "scenario=\(scenarios)")

                            let shouldAccept: Bool
                            if !shouldReadAX || staleStage == 3 || foregroundSwitchStage == 2 || disabledStage == 2 {
                                shouldAccept = false
                            } else {
                                if case .accepted = SelectionTriggerPolicy.evaluateMouseSelection(
                                    snapshot: snapshot,
                                    sourceProcessIdentifier: 42,
                                    foregroundProcessIdentifier: 42,
                                    ownProcessIdentifier: 1,
                                    isEnabled: true,
                                    isDuplicate: duplicate
                                ) {
                                    shouldAccept = true
                                } else {
                                    shouldAccept = false
                                }
                            }

                            if shouldAccept {
                                guard case .accepted = outcome else {
                                    return XCTFail("Expected accepted flow at scenario=\(scenarios), got \(outcome)")
                                }
                            } else {
                                guard case .accepted = outcome else {
                                    XCTAssertEqual(presentationCount, 0, "scenario=\(scenarios)")
                                    continue
                                }
                                XCTFail("Unexpected accepted flow at scenario=\(scenarios)")
                            }
                            XCTAssertEqual(presentationCount, shouldAccept ? 1 : 0, "scenario=\(scenarios)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 672)
    }

    func testSelectionSurvivesMouseDownActivationTransitionIntoInactiveApp() async {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(
            x: 10,
            y: 20,
            timestamp: 10,
            processIdentifier: 1,
            isInsideSnapLexWindow: false
        ))
        let gesture = tracker.recordMouseUp(.init(
            x: 50,
            y: 20,
            timestamp: 10.2,
            processIdentifier: 42,
            clickCount: 1
        ))!
        var presentationCount = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in self.makeAXSnapshot(text: "activation-safe selection") },
            isDuplicate: { _, _ in false },
            onAccepted: { text in
                XCTAssertEqual(text, "activation-safe selection")
                presentationCount += 1
            }
        )

        XCTAssertEqual(outcome, .accepted(makeAXSnapshot(text: "activation-safe selection")))
        XCTAssertEqual(presentationCount, 1)
    }

    func testActivationTransitionStillRejectsAXDownEndpointOwnedBySnapLex() async {
        let gesture = makeActivationTransitionGesture()
        let snapshot = SelectionAXSnapshot(
            focusedTarget: .unavailable,
            focusedProcessIdentifier: nil,
            downTarget: .nonEditable,
            upTarget: .nonEditable,
            downProcessIdentifier: 1,
            upProcessIdentifier: 42,
            downAncestorLimitReached: false,
            upAncestorLimitReached: false,
            selectedText: "must stay suppressed",
            durationMilliseconds: 8,
            queueWaitMilliseconds: 0,
            workerDurationMilliseconds: 8,
            accessibilityCallCount: 6,
            lastAccessibilityError: nil,
            timedOut: false
        )
        var presentations = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in snapshot },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in presentations += 1 }
        )

        XCTAssertEqual(outcome, .suppressedAfterAccessibility(.timedOutOrWrongProcess, snapshot))
        XCTAssertEqual(presentations, 0)
    }

    func testGestureSupersededBeforeSettleSkipsWaitAndAccessibility() async {
        let gesture = makeGesture()
        var waited = false
        var accessibilityReads = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { false },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: { waited = true },
            readAccessibility: { _ in accessibilityReads += 1; return makeAXSnapshot(text: "never") },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("stale gesture must not show a pill") }
        )

        XCTAssertEqual(outcome, .cancelledBeforeAccessibility)
        XCTAssertFalse(waited)
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testForegroundSwitchDuringSettleSkipsAccessibility() async {
        let gesture = makeGesture()
        var foregroundPID: pid_t? = 42
        var accessibilityReads = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { foregroundPID },
            waitForSelectionToSettle: { foregroundPID = 77 },
            readAccessibility: { _ in accessibilityReads += 1; return makeAXSnapshot(text: "stale") },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("app switch must not show a pill") }
        )

        XCTAssertEqual(outcome, .cancelledBeforeAccessibility)
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testGestureSupersededDuringAccessibilityDiscardsLateResult() async {
        let gesture = makeGesture()
        var isCurrent = true
        var accessibilityStarted = false
        var resumeAccessibility: CheckedContinuation<SelectionAXSnapshot, Never>?
        var presentationCount = 0

        let task = Task {
            await SelectionMouseSelectionFlow.resolve(
                gesture: gesture,
                ownProcessIdentifier: 1,
                isEnabled: { true },
                isCurrentGesture: { isCurrent },
                foregroundProcessIdentifier: { 42 },
                waitForSelectionToSettle: {},
                readAccessibility: { _ in
                    await withCheckedContinuation { continuation in
                        accessibilityStarted = true
                        resumeAccessibility = continuation
                    }
                },
                isDuplicate: { _, _ in false },
                onAccepted: { _ in presentationCount += 1 }
            )
        }

        for _ in 0..<100 where !accessibilityStarted {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(accessibilityStarted)
        isCurrent = false
        let lateSnapshot = makeAXSnapshot(text: "late")
        resumeAccessibility?.resume(returning: lateSnapshot)

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelledAfterAccessibility(lateSnapshot))
        XCTAssertEqual(presentationCount, 0)
    }

    func testForegroundSwitchDuringAccessibilityDiscardsLateResult() async {
        let gesture = makeGesture()
        var foregroundPID: pid_t? = 42
        var accessibilityStarted = false
        var resumeAccessibility: CheckedContinuation<SelectionAXSnapshot, Never>?
        var presentationCount = 0

        let task = Task {
            await SelectionMouseSelectionFlow.resolve(
                gesture: gesture,
                ownProcessIdentifier: 1,
                isEnabled: { true },
                isCurrentGesture: { true },
                foregroundProcessIdentifier: { foregroundPID },
                waitForSelectionToSettle: {},
                readAccessibility: { _ in
                    await withCheckedContinuation { continuation in
                        accessibilityStarted = true
                        resumeAccessibility = continuation
                    }
                },
                isDuplicate: { _, _ in false },
                onAccepted: { _ in presentationCount += 1 }
            )
        }

        for _ in 0..<100 where !accessibilityStarted {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(accessibilityStarted)
        foregroundPID = 77
        let lateSnapshot = makeAXSnapshot(text: "late")
        resumeAccessibility?.resume(returning: lateSnapshot)

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelledAfterAccessibility(lateSnapshot))
        XCTAssertEqual(presentationCount, 0)
    }

    func testDisabledSettingRejectsBeforeWaitingOrReadingAccessibility() async {
        var waited = false
        var accessibilityReads = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: makeGesture(),
            ownProcessIdentifier: 1,
            isEnabled: { false },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: { waited = true },
            readAccessibility: { _ in accessibilityReads += 1; return makeAXSnapshot(text: "word") },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("disabled automatic selection must not show a pill") }
        )

        XCTAssertEqual(outcome, .suppressedBeforeAccessibility(.settingDisabled))
        XCTAssertFalse(waited)
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testDisablingSettingDuringSettleWaitSkipsAccessibility() async {
        var enabled = true
        var accessibilityReads = 0
        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: makeGesture(),
            ownProcessIdentifier: 1,
            isEnabled: { enabled },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: { enabled = false },
            readAccessibility: { _ in accessibilityReads += 1; return makeAXSnapshot(text: "word") },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("setting disabled while waiting must not show a pill") }
        )

        XCTAssertEqual(outcome, .suppressedBeforeAccessibility(.settingDisabled))
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testDisablingSettingDuringAccessibilityDiscardsResult() async {
        var enabled = true
        let snapshot = makeAXSnapshot(text: "word")
        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: makeGesture(),
            ownProcessIdentifier: 1,
            isEnabled: { enabled },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in enabled = false; return snapshot },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("setting disabled during AX must not show a pill") }
        )

        XCTAssertEqual(outcome, .suppressedAfterAccessibility(.settingDisabled, snapshot))
    }

    func testSnapLexWindowGestureIsRejectedBeforeAccessibility() async {
        let gesture = makeActivationTransitionGesture(downInsideSnapLexWindow: true)
        var accessibilityReads = 0

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in accessibilityReads += 1; return makeAXSnapshot(text: "underlying page") },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("clicks inside the overlay must not select underlying text") }
        )

        XCTAssertEqual(outcome, .suppressedBeforeAccessibility(.touchesSnapLexWindow))
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testTimedOutOrWrongProcessAXSnapshotFailsClosed() async {
        let gesture = makeGesture()
        var snapshot = makeAXSnapshot(text: "unsafe")
        snapshot = SelectionAXSnapshot(
            focusedTarget: snapshot.focusedTarget,
            focusedProcessIdentifier: snapshot.focusedProcessIdentifier,
            downTarget: snapshot.downTarget,
            upTarget: snapshot.upTarget,
            downProcessIdentifier: 42,
            upProcessIdentifier: 77,
            downAncestorLimitReached: false,
            upAncestorLimitReached: false,
            selectedText: snapshot.selectedText,
            durationMilliseconds: 2,
            queueWaitMilliseconds: 0,
            workerDurationMilliseconds: 2,
            accessibilityCallCount: 3,
            lastAccessibilityError: nil,
            timedOut: false
        )

        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in snapshot },
            isDuplicate: { _, _ in false },
            onAccepted: { _ in XCTFail("wrong-process AX result must not be shown") }
        )

        guard case let .suppressedAfterAccessibility(reason, returnedSnapshot) = outcome else {
            return XCTFail("Expected AX process validation to suppress the selection")
        }
        XCTAssertEqual(reason, .timedOutOrWrongProcess)
        XCTAssertEqual(returnedSnapshot, snapshot)
    }

    func testEditableAXEndpointAndDuplicateSelectionAreSuppressed() async {
        let gesture = makeGesture()
        let editable = makeAXSnapshot(text: "word", downTarget: .editable)
        let editableOutcome = await resolve(gesture: gesture, snapshot: editable)
        guard case let .suppressedAfterAccessibility(editableReason, _) = editableOutcome else {
            return XCTFail("Expected editable endpoint suppression")
        }
        XCTAssertEqual(editableReason, .editableOrUnknownEndpoint)

        let nonEditable = makeAXSnapshot(text: "word")
        let duplicateOutcome = await resolve(gesture: gesture, snapshot: nonEditable, duplicate: true)
        guard case let .suppressedAfterAccessibility(duplicateReason, _) = duplicateOutcome else {
            return XCTFail("Expected duplicate selection suppression")
        }
        XCTAssertEqual(duplicateReason, .duplicate)
    }

    func testUnknownAXEndpointAndInvalidTextAreSuppressed() async {
        let unknownEndpoint = makeAXSnapshot(text: "word", downTarget: .unavailable)
        let unknownOutcome = await resolve(gesture: makeGesture(), snapshot: unknownEndpoint)
        guard case let .suppressedAfterAccessibility(unknownReason, _) = unknownOutcome else {
            return XCTFail("Expected unknown endpoint suppression")
        }
        XCTAssertEqual(unknownReason, .editableOrUnknownEndpoint)

        for invalidText in [" \n ", String(repeating: "a", count: 4_001)] {
            let invalidOutcome = await resolve(
                gesture: makeGesture(),
                snapshot: makeAXSnapshot(text: invalidText)
            )
            guard case let .suppressedAfterAccessibility(reason, _) = invalidOutcome else {
                return XCTFail("Expected invalid text suppression")
            }
            XCTAssertEqual(reason, .emptyOrInvalidText)
        }
    }

    private func resolve(
        gesture: SelectionMouseGestureSnapshot,
        snapshot: SelectionAXSnapshot,
        duplicate: Bool = false
    ) async -> SelectionMouseFlowOutcome {
        await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: 1,
            isEnabled: { true },
            isCurrentGesture: { true },
            foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {},
            readAccessibility: { _ in snapshot },
            isDuplicate: { _, _ in duplicate },
            onAccepted: { _ in XCTFail("suppressed selection must not be presented") }
        )
    }

    private func makeGesture(touchesSnapLex: Bool = false) -> SelectionMouseGestureSnapshot {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(
            x: 10,
            y: 20,
            timestamp: 10,
            processIdentifier: 42,
            isInsideSnapLexWindow: touchesSnapLex
        ))
        return tracker.recordMouseUp(.init(
            x: 50,
            y: 20,
            timestamp: 10.2,
            processIdentifier: 42,
            clickCount: 1
        ))!
    }

    private func makeActivationTransitionGesture(
        downInsideSnapLexWindow: Bool = false
    ) -> SelectionMouseGestureSnapshot {
        var tracker = SelectionMouseGestureTracker()
        tracker.recordMouseDown(.init(
            x: 10,
            y: 20,
            timestamp: 10,
            processIdentifier: 1,
            isInsideSnapLexWindow: downInsideSnapLexWindow
        ))
        return tracker.recordMouseUp(.init(
            x: 50,
            y: 20,
            timestamp: 10.2,
            processIdentifier: 42,
            clickCount: 1
        ))!
    }

    private func makeAXSnapshot(
        text: String?,
        downTarget: SelectionAXTargetKind = .nonEditable,
        upTarget: SelectionAXTargetKind = .nonEditable,
        focusedTarget: SelectionAXTargetKind = .unavailable,
        downProcessIdentifier: pid_t? = 42,
        upProcessIdentifier: pid_t? = 42,
        focusedProcessIdentifier: pid_t? = nil,
        timedOut: Bool = false
    ) -> SelectionAXSnapshot {
        SelectionAXSnapshot(
            focusedTarget: focusedTarget,
            focusedProcessIdentifier: focusedProcessIdentifier ?? (focusedTarget == .nonEditable ? 42 : nil),
            downTarget: downTarget,
            upTarget: upTarget,
            downProcessIdentifier: downProcessIdentifier,
            upProcessIdentifier: upProcessIdentifier,
            downAncestorLimitReached: false,
            upAncestorLimitReached: false,
            selectedText: text,
            durationMilliseconds: 8,
            queueWaitMilliseconds: 0,
            workerDurationMilliseconds: 8,
            accessibilityCallCount: 6,
            lastAccessibilityError: nil,
            timedOut: timedOut
        )
    }
}
