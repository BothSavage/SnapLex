import AppKit
import XCTest
@testable import SnapLex

final class SelectionTriggerPolicyTests: XCTestCase {
    func testOrdinaryInputUnderBothEndpointsAllowsAutomaticSelectionWhenAXFocusIsUnavailable() {
        XCTAssertTrue(SelectionTriggerPolicy.shouldShowMouseSelection(
            focusedTarget: .unavailable,
            downTarget: .editable,
            upTarget: .editable
        ))
    }

    func testBodySelectionIsAllowedWhenAXFocusStillPointsToSearchField() {
        XCTAssertTrue(SelectionTriggerPolicy.shouldShowMouseSelection(
            focusedTarget: .editable,
            downTarget: .nonEditable,
            upTarget: .nonEditable
        ))
    }

    func testUnknownAXContextFailsClosedForAutomaticSelection() {
        XCTAssertFalse(SelectionTriggerPolicy.shouldShowMouseSelection(
            focusedTarget: .unavailable,
            downTarget: .unavailable,
            upTarget: .unavailable
        ))
    }

    func testDeepBrowserLikeAXHierarchyIsSupportedButEditableAncestorsStillWin() {
        let readableHierarchy = Array(repeating: "AXGroup", count: 24)
            + ["AXStaticText", "AXWebArea", "AXWindow", "AXApplication"]
        XCTAssertGreaterThanOrEqual(SelectionAccessibilityReader.maximumAncestorDepth, readableHierarchy.count)
        XCTAssertEqual(
            SelectionTriggerPolicy.classifyAXRoleChain(readableHierarchy, reachedAXRoot: true),
            .nonEditable
        )

        let nestedEditorHierarchy = Array(repeating: "AXGroup", count: 24)
            + ["AXTextArea", "AXWebArea", "AXWindow", "AXApplication"]
        XCTAssertEqual(
            SelectionTriggerPolicy.classifyAXRoleChain(nestedEditorHierarchy, reachedAXRoot: false),
            .editable
        )
        XCTAssertEqual(
            SelectionTriggerPolicy.classifyAXRoleChain(["AXStaticText"], reachedAXRoot: false),
            .unavailable
        )
    }

    func testMouseSelectionRequiresSameExternalAppExceptWhenDownActivatesIt() {
        XCTAssertTrue(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: 42,
            mouseUpProcessIdentifier: 42,
            ownProcessIdentifier: 7
        ))
        XCTAssertTrue(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: 7,
            mouseUpProcessIdentifier: 42,
            ownProcessIdentifier: 7
        ))
        XCTAssertFalse(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: 7,
            mouseUpProcessIdentifier: 42,
            ownProcessIdentifier: 7,
            mouseDownIsInsideSnapLexWindow: true
        ))
        XCTAssertFalse(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: 42,
            mouseUpProcessIdentifier: 43,
            ownProcessIdentifier: 7
        ))
        XCTAssertFalse(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: 7,
            mouseUpProcessIdentifier: 7,
            ownProcessIdentifier: 7
        ))
        XCTAssertFalse(SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: nil,
            mouseUpProcessIdentifier: 42,
            ownProcessIdentifier: 7
        ))
    }

    func testSyntheticCopyRequiresKnownNonEditableSelectionContext() {
        XCTAssertTrue(SelectionTriggerPolicy.shouldAllowSyntheticCopy(
            focusedTarget: .nonEditable,
            downTarget: .nonEditable,
            upTarget: .nonEditable
        ))
        XCTAssertFalse(SelectionTriggerPolicy.shouldAllowSyntheticCopy(
            focusedTarget: .editable,
            downTarget: .nonEditable,
            upTarget: .nonEditable
        ))
        XCTAssertFalse(SelectionTriggerPolicy.shouldAllowSyntheticCopy(
            focusedTarget: .nonEditable,
            downTarget: .unavailable,
            upTarget: .nonEditable
        ))
        XCTAssertFalse(SelectionTriggerPolicy.shouldAllowSyntheticCopy(
            focusedTarget: .editable,
            downTarget: .editable,
            upTarget: .editable
        ))
        XCTAssertFalse(SelectionTriggerPolicy.shouldAllowSyntheticCopy(
            focusedTarget: .unavailable,
            downTarget: .unavailable,
            upTarget: .unavailable
        ))
    }

    func testRepeatedSameSelectionInSameAppIsSuppressedOnlyInsideCooldown() {
        XCTAssertTrue(SelectionTriggerPolicy.isDuplicate(
            text: "word", processIdentifier: 42,
            lastText: "word", lastProcessIdentifier: 42,
            now: 10.79, lastTime: 10
        ))
        XCTAssertFalse(SelectionTriggerPolicy.isDuplicate(
            text: "word", processIdentifier: 42,
            lastText: "word", lastProcessIdentifier: 42,
            now: 10.8, lastTime: 10
        ))
        XCTAssertFalse(SelectionTriggerPolicy.isDuplicate(
            text: "word", processIdentifier: 43,
            lastText: "word", lastProcessIdentifier: 42,
            now: 10.1, lastTime: 10
        ))
    }

    func testOptionLetterShortcutsAreRejectedButFunctionKeyShortcutsRemainAvailable() {
        let option = NSEvent.ModifierFlags.option.rawValue
        XCTAssertTrue(ShortcutBinding(keyCode: 0, modifiers: option, keyLabel: "A").isReservedForTextEditing)
        XCTAssertTrue(ShortcutBinding(keyCode: 0, modifiers: option | NSEvent.ModifierFlags.shift.rawValue, keyLabel: "A").isReservedForTextEditing)
        XCTAssertFalse(ShortcutBinding(keyCode: 122, modifiers: option, keyLabel: "F1").isReservedForTextEditing)
    }

    func testEveryGlobalDefaultShortcutIsSafeForTextEntry() {
        for shortcut in GlobalShortcut.allCases where shortcut.isGlobal {
            XCTAssertFalse(shortcut.defaultBinding.isReservedForTextEditing, "Unsafe default for \(shortcut.rawValue)")
        }
    }

    func testDefaultShortcutLabelsMatchTheRegisteredModifierCombinations() {
        XCTAssertEqual(GlobalShortcut.selectionTranslate.defaultBinding.displayString, "⌃⌘A")
        XCTAssertEqual(GlobalShortcut.screenshotOptionS.defaultBinding.displayString, "⌃⌘S")
        XCTAssertEqual(GlobalShortcut.pinOptionP.defaultBinding.displayString, "⌃⌘P")
        XCTAssertEqual(GlobalShortcut.openTranslationCard.defaultBinding.displayString, "⌃⌘D")
        XCTAssertEqual(GlobalShortcut.screenRecorder.defaultBinding.displayString, "⌃⌘R")
    }
}
