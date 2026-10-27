import AppKit
import XCTest
@testable import SnapLex

@MainActor
final class EditableSelectionTests: XCTestCase {
    func testInputSelectionTraversesTheMouseFlowAndPreparesExactWordForPill() async {
        let snapshot = makeSnapshot(text: "  agent  ")
        let model = TranslatorViewModel(historyRecorder: { _, _, _, _, _, _ in XCTFail("Preparing a selection must not create history") })
        var presented = 0
        let outcome = await resolve(snapshot) { text in
            presented += 1
            model.preparePillSelection(text: text, sourceApp: "TextEdit", trigger: .mouseSelect)
        }
        XCTAssertEqual(outcome, .accepted(snapshot))
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(model.inputText, "agent")
        XCTAssertEqual(model.sourceApp, "TextEdit")
        XCTAssertEqual(model.triggerSource, .mouseSelect)
        XCTAssertFalse(model.isTranslating, "Only the user's translate action starts translation.")
    }

    func testOrdinaryTextEntryRolesPreserveOnlyExplicitSelectedText() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextEntryArea"] {
            let result = SelectionTriggerPolicy.inspectAXAncestorChain(startingAt: 0, maximumDepth: 4) { node in
                node == 0
                    ? .parent(role: "AXStaticText", selectedText: "agent", valueIsSettable: nil, node: 1)
                    : .root(role: role, selectedText: nil, valueIsSettable: true)
            }
            XCTAssertEqual(result.target, .editable, role)
            XCTAssertEqual(result.selectedText, "agent", role)
        }
    }

    func testNativeSecureSubroleConstantIsRecognizedAndItsTextIsDiscarded() {
        let role = SelectionTriggerPolicy.normalizedTextEntryRole(
            role: NSAccessibility.Role.textField.rawValue,
            subrole: NSAccessibility.Subrole.secureTextField.rawValue
        )
        XCTAssertEqual(role, "AXSecureTextField")
        let result = SelectionTriggerPolicy.inspectAXAncestorChain(startingAt: 0, maximumDepth: 4) { _ in
            SelectionAXAncestorRead<Int>.root(role: role, selectedText: "must not escape", valueIsSettable: true)
        }
        XCTAssertEqual(result.target, .secure)
        XCTAssertNil(result.selectedText)
    }

    func testSecureEndpointCannotPresentEvenIfProviderExposesText() async {
        for pair: (SelectionAXTargetKind, SelectionAXTargetKind) in [(.secure, .secure), (.secure, .nonEditable), (.nonEditable, .secure)] {
            let result = await resolve(makeSnapshot(text: "must not escape", down: pair.0, up: pair.1)) { _ in
                XCTFail("Protected text must not reach the popup")
            }
            guard case .suppressedAfterAccessibility = result else { return XCTFail("Expected protected selection suppression") }
        }
    }

    func testEmptyInputSelectionCannotPresent() async {
        let result = await resolve(makeSnapshot(text: nil)) { _ in XCTFail("Empty input selection") }
        guard case .suppressedAfterAccessibility(.emptyOrInvalidText, _) = result else {
            return XCTFail("An editor without an actual selection must remain quiet")
        }
    }

    func testDirectShortcutAcceptsInputAXSelectionWithoutSyntheticCopy() async {
        let snapshot = makeSnapshot(text: "agent")
        let result = await SelectionDirectCaptureFlow.resolve(
            sourceProcessIdentifier: 42, ownProcessIdentifier: 1,
            hasAccessibilityPermission: { true }, foregroundProcessIdentifier: { 42 },
            readAccessibility: { snapshot },
            synthesizeCopy: { XCTFail("An explicit AX selection requires no clipboard change"); return nil }
        )
        XCTAssertEqual(result, .accepted(text: "agent", source: .accessibility, snapshot: snapshot))
    }

    func testOrdinarySingleClickIsNotASelectionGesture() {
        XCTAssertFalse(SelectionTriggerPolicy.isSelectionGesture(distance: 0, duration: 0.1, clickCount: 1))
        XCTAssertTrue(SelectionTriggerPolicy.isSelectionGesture(distance: 0, duration: 0.1, clickCount: 2))
    }

    func testEventCoordinatesAndTimeDoNotDependOnTheLaterLivePointerPosition() throws {
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 123, y: -50), mouseButton: .left
        ))
        cgEvent.timestamp = 12_500_000_000
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        var didReadLiveMouse = false
        func liveMouse() -> NSPoint { didReadLiveMouse = true; return NSPoint(x: 999, y: 999) }
        let point = SelectionMouseEventAdapter.screenPoint(for: event, zeroScreenMaxY: 900, fallbackLocation: liveMouse())
        XCTAssertEqual(point, NSPoint(x: 123, y: 950))
        XCTAssertFalse(didReadLiveMouse)
        XCTAssertEqual(SelectionMouseEventAdapter.timestamp(for: event, fallback: 999), event.timestamp)
    }

    private func resolve(_ snapshot: SelectionAXSnapshot, onAccepted: @MainActor (String) -> Void) async -> SelectionMouseFlowOutcome {
        let gesture = SelectionMouseGestureSnapshot(
            down: SelectionMouseDownSnapshot(x: 100, y: 100, timestamp: 10, processIdentifier: 42, isInsideSnapLexWindow: false),
            up: SelectionMouseUpSnapshot(x: 150, y: 100, timestamp: 10.2, processIdentifier: 42, clickCount: 1, isInsideSnapLexWindow: false),
            generation: 1
        )
        return await SelectionMouseSelectionFlow.resolve(
            gesture: gesture, ownProcessIdentifier: 1, isEnabled: { true },
            isCurrentGesture: { true }, foregroundProcessIdentifier: { 42 },
            waitForSelectionToSettle: {}, readAccessibility: { _ in snapshot },
            isDuplicate: { _, _ in false }, onAccepted: onAccepted
        )
    }

    private func makeSnapshot(text: String?, down: SelectionAXTargetKind = .editable, up: SelectionAXTargetKind = .editable) -> SelectionAXSnapshot {
        SelectionAXSnapshot(
            focusedTarget: .unavailable, focusedProcessIdentifier: nil,
            downTarget: down, upTarget: up, downProcessIdentifier: 42, upProcessIdentifier: 42,
            downAncestorLimitReached: false, upAncestorLimitReached: false, selectedText: text,
            durationMilliseconds: 1, queueWaitMilliseconds: 0, workerDurationMilliseconds: 1,
            accessibilityCallCount: 2, lastAccessibilityError: nil, timedOut: false
        )
    }
}
