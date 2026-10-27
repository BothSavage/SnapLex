import AppKit
import XCTest
@testable import SnapLex

final class SelectionScenarioMatrixTests: XCTestCase {
    private let targets: [SelectionAXTargetKind] = [.editable, .nonEditable, .unavailable]

    func testMouseSelectionGateAcross216Scenarios() {
        var scenarios = 0
        for focus in targets {
            for down in targets {
                for up in targets {
                    for enabled in [false, true] {
                        for foregroundUnchanged in [false, true] {
                            for hitBelongsToSnapLex in [false, true] {
                                scenarios += 1
                                let expected: Bool
                                if !enabled || !foregroundUnchanged || hitBelongsToSnapLex {
                                    expected = false
                                } else if down == .editable || up == .editable {
                                    expected = down == .editable && up == .editable
                                } else if down == .nonEditable && up == .nonEditable {
                                    expected = true
                                } else {
                                    expected = focus == .nonEditable
                                }
                                XCTAssertEqual(
                                    SelectionTriggerPolicy.shouldShowMouseSelection(
                                        focusedTarget: focus,
                                        downTarget: down,
                                        upTarget: up,
                                        isEnabled: enabled,
                                        foregroundAppUnchanged: foregroundUnchanged,
                                        selectionPointsBelongToSnapLex: hitBelongsToSnapLex
                                    ),
                                    expected,
                                    "scenario=\(scenarios) focus=\(focus) down=\(down) up=\(up) enabled=\(enabled) foreground=\(foregroundUnchanged) snaplexHit=\(hitBelongsToSnapLex)"
                                )
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 216)
    }

    func testSyntheticCopyGateAcross216Scenarios() {
        var scenarios = 0
        for focus in targets {
            for down in targets {
                for up in targets {
                    for hasAXSelection in [false, true] {
                        for hasPermission in [false, true] {
                            for enabled in [false, true] {
                                scenarios += 1
                                let expected = enabled
                                    && hasPermission
                                    && !hasAXSelection
                                    && focus == .nonEditable
                                    && down == .nonEditable
                                    && up == .nonEditable
                                XCTAssertEqual(
                                    SelectionTriggerPolicy.shouldAllowSyntheticCopy(
                                        focusedTarget: focus,
                                        downTarget: down,
                                        upTarget: up,
                                        hasAXSelection: hasAXSelection,
                                        hasAccessibilityPermission: hasPermission,
                                        isEnabled: enabled
                                    ),
                                    expected,
                                    "scenario=\(scenarios) focus=\(focus) down=\(down) up=\(up) hasAX=\(hasAXSelection) permission=\(hasPermission) enabled=\(enabled)"
                                )
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 216)
    }

    func testDoubleCopyGateAcross96Scenarios() {
        var scenarios = 0
        for focus in targets {
            for enabled in [false, true] {
                for withinWindow in [false, true] {
                    for foregroundUnchanged in [false, true] {
                        for isDuplicate in [false, true] {
                            for clipboardStable in [false, true] {
                                scenarios += 1
                                let expected = focus == .nonEditable
                                    && enabled
                                    && withinWindow
                                    && clipboardStable
                                    && foregroundUnchanged
                                    && !isDuplicate
                                XCTAssertEqual(
                                    SelectionTriggerPolicy.shouldShowDoubleCopy(
                                        focusedTarget: focus,
                                        isEnabled: enabled,
                                        isSecondClipboardChangeWithinWindow: withinWindow,
                                        clipboardSnapshotIsStable: clipboardStable,
                                        foregroundAppUnchanged: foregroundUnchanged,
                                        isDuplicateSelection: isDuplicate
                                    ),
                                    expected,
                                    "scenario=\(scenarios) focus=\(focus) enabled=\(enabled) within=\(withinWindow) stable=\(clipboardStable) foreground=\(foregroundUnchanged) duplicate=\(isDuplicate)"
                                )
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 96)
    }

    func testAXSnapshotGateAcross18TimeoutAndProcessScenarios() {
        let sourcePID: pid_t = 100
        let processTargets: [pid_t?] = [nil, sourcePID, sourcePID + 1]
        var scenarios = 0
        for timedOut in [false, true] {
            for downPID in processTargets {
                for upPID in processTargets {
                    scenarios += 1
                    let expected = !timedOut && downPID == sourcePID && upPID == sourcePID
                    XCTAssertEqual(
                        SelectionTriggerPolicy.canUseAXSnapshot(
                            timedOut: timedOut,
                            downProcessIdentifier: downPID,
                            upProcessIdentifier: upPID,
                            sourceProcessIdentifier: sourcePID
                        ),
                        expected,
                        "scenario=\(scenarios) timeout=\(timedOut) downPID=\(String(describing: downPID)) upPID=\(String(describing: upPID))"
                    )
                }
            }
        }
        XCTAssertEqual(scenarios, 18)
    }

    func testMouseGestureBoundariesAcross96Scenarios() {
        let distances: [CGFloat] = [0, 9, 10, 11]
        let durations: [TimeInterval] = [0, 0.049, 0.05, 0.051, 12, 12.001]
        let clickCounts = [1, 2, 3, 4]
        var scenarios = 0
        for distance in distances {
            for duration in durations {
                for clicks in clickCounts {
                    scenarios += 1
                    let isDrag = distance >= 10 && duration >= 0.05 && duration <= 12
                    let expected = isDrag || clicks == 2 || clicks == 3
                    XCTAssertEqual(
                        SelectionTriggerPolicy.isSelectionGesture(
                            distance: distance,
                            duration: duration,
                            clickCount: clicks
                        ),
                        expected,
                        "scenario=\(scenarios) distance=\(distance) duration=\(duration) clicks=\(clicks)"
                    )
                }
            }
        }
        XCTAssertEqual(scenarios, 96)
    }

    func testDuplicateCooldownAcross64Scenarios() {
        let deltas: [TimeInterval] = [-0.01, 0, 0.79, 0.8, 0.81, 1.49, 1.5, 1.51]
        let windows: [TimeInterval] = [0.8, 1.5]
        var scenarios = 0
        for sameText in [false, true] {
            for samePID in [false, true] {
                for delta in deltas {
                    for window in windows {
                        scenarios += 1
                        let result = SelectionTriggerPolicy.isDuplicate(
                            text: sameText ? "selected" : "different",
                            processIdentifier: 101,
                            lastText: "selected",
                            lastProcessIdentifier: samePID ? 101 : 202,
                            now: 20 + delta,
                            lastTime: 20,
                            window: window
                        )
                        XCTAssertEqual(
                            result,
                            sameText && samePID && delta >= 0 && delta < window,
                            "scenario=\(scenarios) sameText=\(sameText) samePID=\(samePID) delta=\(delta) window=\(window)"
                        )
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 64)
    }

    func testDoubleCopyCandidateStateAcrossSourceAndTimingScenarios() {
        var scenarios = 0
        let offsets: [TimeInterval] = [-0.01, 0, 0.599, 0.60, 0.601, 1]
        for firstPID: pid_t in [10, 20] {
            for secondPID: pid_t in [10, 20] {
                for offset in offsets {
                    scenarios += 1
                    var state = DoubleCopyCandidateState()
                    XCTAssertFalse(state.observeCopy(timestamp: 5, processIdentifier: firstPID))
                    let expected = firstPID == secondPID && offset >= 0 && offset <= 0.60
                    XCTAssertEqual(
                        state.observeCopy(timestamp: 5 + offset, processIdentifier: secondPID),
                        expected,
                        "scenario=\(scenarios) firstPID=\(firstPID) secondPID=\(secondPID) offset=\(offset)"
                    )
                    XCTAssertEqual(state.timestamp == nil, expected, "scenario=\(scenarios) candidate reset state")
                }
            }
        }
        XCTAssertEqual(scenarios, 24)
    }

    func testClipboardTransactionMatrixAcrossDeltaAndPayloadKind() {
        var scenarios = 0
        for delta in [-1, 0, 1, 2, 3, 4] {
            for containsString in [false, true] {
                scenarios += 1
                XCTAssertEqual(
                    SelectionTriggerPolicy.isPlausibleTextClipboardCopyChange(
                        changeCountDelta: delta,
                        pasteboardContainsString: containsString
                    ),
                    containsString && (1...2).contains(delta),
                    "scenario=\(scenarios) delta=\(delta) containsString=\(containsString)"
                )
            }
        }
        XCTAssertEqual(scenarios, 12)
    }

    func testMouseGestureAppIdentityMatrixAcrossDownAndUpTargets() {
        let processIdentifiers: [pid_t?] = [nil, 10, 20]
        var scenarios = 0
        for downPID in processIdentifiers {
            for upPID in processIdentifiers {
                for ownPID: pid_t in [10, 30, 40] {
                    scenarios += 1
                    let expected: Bool
                    if let downPID, let upPID {
                        expected = upPID != ownPID && (downPID == upPID || downPID == ownPID)
                    } else {
                        expected = false
                    }
                    XCTAssertEqual(
                        SelectionTriggerPolicy.mouseGestureHasSafeExternalSource(
                            mouseDownProcessIdentifier: downPID,
                            mouseUpProcessIdentifier: upPID,
                            ownProcessIdentifier: ownPID
                        ),
                        expected,
                        "scenario=\(scenarios) downPID=\(String(describing: downPID)) upPID=\(String(describing: upPID)) ownPID=\(ownPID)"
                    )
                }
            }
        }
        XCTAssertEqual(scenarios, 27)
    }

    func testMouseSelectionEvaluationAcross5184AXAndTriggerScenarios() {
        let texts: [String?] = [nil, "  selected word  ", String(repeating: "x", count: 4_001)]
        var scenarios = 0

        for focus in targets {
            for down in targets {
                for up in targets {
                    for enabled in [false, true] {
                        for foregroundMatches in [false, true] {
                            for timedOut in [false, true] {
                                for downPIDMatches in [false, true] {
                                    for upPIDMatches in [false, true] {
                                        for text in texts {
                                            for duplicate in [false, true] {
                                                scenarios += 1
                                                let snapshot = SelectionAXSnapshot(
                                                    focusedTarget: focus,
                                                    focusedProcessIdentifier: focus == .unavailable ? nil : 200,
                                                    downTarget: down,
                                                    upTarget: up,
                                                    downProcessIdentifier: downPIDMatches ? 200 : 201,
                                                    upProcessIdentifier: upPIDMatches ? 200 : 201,
                                                    downAncestorLimitReached: false,
                                                    upAncestorLimitReached: false,
                                                    selectedText: text,
                                                    durationMilliseconds: 0,
                                                    queueWaitMilliseconds: 0,
                                                    workerDurationMilliseconds: 0,
                                                    accessibilityCallCount: 0,
                                                    lastAccessibilityError: nil,
                                                    timedOut: timedOut
                                                )

                                                let expected: MouseSelectionEvaluation
                                                if !enabled {
                                                    expected = .suppressed(.settingDisabled)
                                                } else if !foregroundMatches {
                                                    expected = .suppressed(.foregroundChanged)
                                                } else if timedOut || !downPIDMatches || !upPIDMatches {
                                                    expected = .suppressed(.timedOutOrWrongProcess)
                                                } else if down == .unavailable && up == .unavailable && focus == .unavailable {
                                                    expected = .suppressed(.timedOutOrWrongProcess)
                                                } else if (down == .editable || up == .editable)
                                                    ? !(down == .editable && up == .editable)
                                                    : !((down == .nonEditable && up == .nonEditable) || focus == .nonEditable) {
                                                    expected = .suppressed(.editableOrUnknownEndpoint)
                                                } else if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 0,
                                                          text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 4_000 {
                                                    if duplicate {
                                                        expected = .suppressed(.duplicate)
                                                    } else {
                                                        expected = .accepted("selected word")
                                                    }
                                                } else {
                                                    expected = .suppressed(.emptyOrInvalidText)
                                                }

                                                XCTAssertEqual(
                                                    SelectionTriggerPolicy.evaluateMouseSelection(
                                                        snapshot: snapshot,
                                                        sourceProcessIdentifier: 200,
                                                        foregroundProcessIdentifier: foregroundMatches ? 200 : 201,
                                                        ownProcessIdentifier: 100,
                                                        isEnabled: enabled,
                                                        isDuplicate: duplicate
                                                    ),
                                                    expected,
                                                    "scenario=\(scenarios) focus=\(focus) down=\(down) up=\(up) enabled=\(enabled) foregroundMatches=\(foregroundMatches) timedOut=\(timedOut) downPIDMatches=\(downPIDMatches) upPIDMatches=\(upPIDMatches) textLength=\(text?.count ?? -1) duplicate=\(duplicate)"
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 5_184)
    }

    func testAXRoleClassificationAcrossAncestorDepths() {
        var scenarios = 0
        for role in SelectionTriggerPolicy.editableAXRoles {
            for depth in 0...8 {
                let chain = Array(repeating: "AXGroup", count: depth) + [role]
                for reachedRoot in [false, true] {
                    scenarios += 1
                    XCTAssertEqual(
                        SelectionTriggerPolicy.classifyAXRoleChain(chain, reachedAXRoot: reachedRoot),
                        role == "AXSecureTextField" ? .secure : .editable,
                        "scenario=\(scenarios) editableRole=\(role) depth=\(depth) root=\(reachedRoot)"
                    )
                }
            }
        }
        for role in SelectionTriggerPolicy.nonEditableAXRoles {
            for depth in 0...4 {
                let chain = [role] + Array(repeating: "AXGroup", count: depth)
                scenarios += 1
                XCTAssertEqual(
                    SelectionTriggerPolicy.classifyAXRoleChain(chain, reachedAXRoot: true),
                    .nonEditable,
                    "scenario=\(scenarios) readOnlyRole=\(role) depth=\(depth)"
                )
                scenarios += 1
                XCTAssertEqual(
                    SelectionTriggerPolicy.classifyAXRoleChain(chain, reachedAXRoot: false),
                    .unavailable,
                    "scenario=\(scenarios) truncatedRole=\(role) depth=\(depth)"
                )
            }
        }
        for root in [false, true] {
            scenarios += 1
            XCTAssertEqual(
                SelectionTriggerPolicy.classifyAXRoleChain(["AXUnknownRole"], reachedAXRoot: root),
                .unavailable
            )
        }
        scenarios += 1
        XCTAssertEqual(
            SelectionTriggerPolicy.classifyAXRoleChain(["AXStaticText"], hasEditableAncestor: true, reachedAXRoot: true),
            .editable
        )
        XCTAssertGreaterThan(scenarios, 300)
    }

    func testSelectedTextPriorityAcross648Scenarios() {
        let candidates: [String?] = [nil, "", " \n ", " up ", "down", String(repeating: "x", count: 4_001)]
        var scenarios = 0
        for up in candidates {
            for down in candidates {
                for focused in candidates {
                    for focusTarget in targets {
                        scenarios += 1
                        let expected: String?
                        if let up, SelectionTriggerPolicy.isValidSelectedText(up) {
                            expected = up.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let down, SelectionTriggerPolicy.isValidSelectedText(down) {
                            expected = down.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if focusTarget == .nonEditable,
                                  let focused,
                                  SelectionTriggerPolicy.isValidSelectedText(focused) {
                            expected = focused.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            expected = nil
                        }
                        XCTAssertEqual(
                            SelectionTriggerPolicy.preferredSelectedText(
                                upText: up,
                                downText: down,
                                focusedText: focused,
                                focusedTarget: focusTarget
                            ),
                            expected,
                            "scenario=\(scenarios) focus=\(focusTarget) up=\(String(describing: up)) down=\(String(describing: down)) focused=\(String(describing: focused).prefix(12))"
                        )
                    }
                }
            }
        }
        XCTAssertEqual(scenarios, 648)
    }

    func testSelectedTextLengthAndUnicodeBoundaries() {
        let validTexts = ["a", "\n  word  \t", "你好", "🙂", String(repeating: "🙂", count: 4_000)]
        let invalidTexts = ["", " \n\t ", String(repeating: "a", count: 4_001)]
        for text in validTexts {
            XCTAssertTrue(SelectionTriggerPolicy.isValidSelectedText(text), "validLength=\(text.count)")
        }
        for text in invalidTexts {
            XCTAssertFalse(SelectionTriggerPolicy.isValidSelectedText(text), "invalidLength=\(text.count)")
        }
    }

    func testShortcutTextSafetyAcrossPrintableKeyAndModifierMatrix() {
        let printableKeyCodes: [UInt16] = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17,
            32, 9, 13, 16, 6, 7, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24,
            49, 33, 30, 42, 41, 39, 43, 47, 44
        ]
        let modifiers = [
            UInt(0),
            NSEvent.ModifierFlags.shift.rawValue,
            NSEvent.ModifierFlags.option.rawValue,
            NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.shift.rawValue,
            NSEvent.ModifierFlags.control.rawValue,
            NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.shift.rawValue,
            NSEvent.ModifierFlags.command.rawValue,
            NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue,
            NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.command.rawValue
        ]
        var scenarios = 0
        for keyCode in printableKeyCodes {
            for modifier in modifiers {
                scenarios += 1
                let binding = ShortcutBinding(keyCode: keyCode, modifiers: modifier, keyLabel: "K")
                let flags = NSEvent.ModifierFlags(rawValue: modifier)
                    .intersection([.command, .option, .control, .shift])
                let expected: Bool
                if flags.subtracting(.shift).isEmpty {
                    expected = true
                } else if flags.contains(.option) && !flags.contains(.command) {
                    expected = true
                } else if flags.contains(.control) && !flags.contains(.command) {
                    expected = true
                } else if flags == .command || flags == [.command, .shift] {
                    expected = [0, 6, 7, 8, 9, 16, 51, 117, 123, 124, 125, 126].contains(keyCode)
                } else {
                    expected = false
                }
                XCTAssertEqual(
                    binding.isReservedForTextEditing,
                    expected,
                    "scenario=\(scenarios) keyCode=\(keyCode) modifiers=\(modifier)"
                )
            }
        }
        XCTAssertEqual(scenarios, printableKeyCodes.count * modifiers.count)
        for keyCode: UInt16 in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90] {
            for modifier in modifiers {
                XCTAssertFalse(
                    ShortcutBinding(keyCode: keyCode, modifiers: modifier, keyLabel: "F").isReservedForTextEditing,
                    "functionOrNavigationKey=\(keyCode) modifiers=\(modifier)"
                )
            }
        }
    }
}
