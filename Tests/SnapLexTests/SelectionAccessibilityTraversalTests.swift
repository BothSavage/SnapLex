import ApplicationServices
import XCTest
@testable import SnapLex

final class SelectionAccessibilityTraversalTests: XCTestCase {
    func testAXMessagingTimeoutErrorIsDistinguishedFromOtherFailures() {
        XCTAssertTrue(SelectionAccessibilityReader.isTimeoutError(Int32(AXError.cannotComplete.rawValue)))
        XCTAssertFalse(SelectionAccessibilityReader.isTimeoutError(Int32(AXError.attributeUnsupported.rawValue)))
        XCTAssertFalse(SelectionAccessibilityReader.isTimeoutError(Int32(AXError.noValue.rawValue)))
    }

    func testUnsupportedParentIsTerminalOnlyForTheApplicationRole() {
        let unsupported = Int32(AXError.attributeUnsupported.rawValue)

        XCTAssertTrue(SelectionAccessibilityReader.isUnsupportedParentOnApplicationRoot("AXApplication", errorCode: unsupported))
        XCTAssertFalse(SelectionAccessibilityReader.isUnsupportedParentOnApplicationRoot("AXWindow", errorCode: unsupported))
        XCTAssertFalse(SelectionAccessibilityReader.isUnsupportedParentOnApplicationRoot("AXVendorWidget", errorCode: unsupported))
        XCTAssertFalse(SelectionAccessibilityReader.isUnsupportedParentOnApplicationRoot("AXApplication", errorCode: Int32(AXError.cannotComplete.rawValue)))
    }

    func testDeepBrowserTextChainFindsSelectedTextBeforeAXRoot() {
        var nodes = Dictionary(uniqueKeysWithValues: (0..<25).map { index in
            (index, FakeAXNode(role: index == 24 ? "AXApplication" : "AXGroup", text: index == 0 ? "  selected browser text  " : nil, parentID: index == 24 ? nil : index + 1, terminal: index == 24 ? .root : nil))
        })
        nodes[23] = FakeAXNode(role: "AXWebArea", text: nil, parentID: 24, terminal: nil)

        let result = inspect(nodes: nodes, maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        XCTAssertEqual(result.target, .nonEditable)
        XCTAssertEqual(result.selectedText, "  selected browser text  ")
        XCTAssertTrue(result.reachedAXRoot)
        XCTAssertFalse(result.ancestorLimitReached)
        XCTAssertFalse(result.timedOut)
    }

    func testDeepReadOnlyBrowserTextBeyondThirtyTwoAncestorsReachesAXRoot() {
        let nodes = Dictionary(uniqueKeysWithValues: (0..<96).map { index in
            (index, FakeAXNode(
                role: index == 80 ? "AXWebArea" : (index == 95 ? "AXApplication" : "AXGroup"),
                text: index == 0 ? "selected browser text" : nil,
                parentID: index == 95 ? nil : index + 1,
                terminal: index == 95 ? .root : nil
            ))
        })

        let result = inspect(nodes: nodes, maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        XCTAssertEqual(SelectionAccessibilityReader.maximumAncestorDepth, 128)
        XCTAssertEqual(result.target, .nonEditable)
        XCTAssertEqual(result.selectedText, "selected browser text")
        XCTAssertTrue(result.reachedAXRoot)
        XCTAssertFalse(result.ancestorLimitReached)
        XCTAssertFalse(result.timedOut)
    }

    func testDeepEditableAncestorBeyondThirtyTwoAncestorsStillBlocksSelection() {
        let nodes = Dictionary(uniqueKeysWithValues: (0..<96).map { index in
            (index, FakeAXNode(
                role: index == 80 ? "AXTextArea" : (index == 95 ? "AXApplication" : "AXGroup"),
                text: index == 0 ? "selected editor text" : nil,
                valueIsSettable: index == 80 ? true : nil,
                parentID: index == 95 ? nil : index + 1,
                terminal: index == 95 ? .root : nil
            ))
        })

        let result = inspect(nodes: nodes, maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        XCTAssertEqual(result.target, .editable)
        XCTAssertEqual(result.selectedText, "selected editor text")
        XCTAssertFalse(result.ancestorLimitReached)
    }

    func testFocusedWebAreaSelectionRecoversWhenMouseEndpointsExposeNoText() {
        let focused = inspect(nodes: [
            0: FakeAXNode(role: "AXWebArea", text: "  selected page text  ", parentID: nil, terminal: .root)
        ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        let selectedText = SelectionAccessibilityReader.selectedText(
            upText: nil,
            downText: nil,
            focusedTarget: focused.target,
            focusedText: focused.selectedText
        )

        XCTAssertEqual(focused.target, .nonEditable)
        XCTAssertEqual(selectedText, "selected page text")
    }

    func testFocusedEditableSelectionIsNeverUsedAsPageTextFallback() {
        let focused = inspect(nodes: [
            0: FakeAXNode(role: "AXTextArea", text: "draft text", parentID: nil, terminal: .root)
        ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        let selectedText = SelectionAccessibilityReader.selectedText(
            upText: nil,
            downText: nil,
            focusedTarget: focused.target,
            focusedText: focused.selectedText
        )

        XCTAssertEqual(focused.target, .editable)
        XCTAssertNil(selectedText)
    }

    func testReadOnlyTextAreaRoleUsesValueMutabilityAndAllowsSelection() {
        let result = inspect(nodes: [
            0: FakeAXNode(role: "AXTextArea", text: "selected read-only text", valueIsSettable: false, parentID: 1, terminal: nil),
            1: FakeAXNode(role: "AXScrollArea", text: nil, parentID: 2, terminal: nil),
            2: FakeAXNode(role: "AXWindow", text: nil, parentID: 3, terminal: nil),
            3: FakeAXNode(role: "AXApplication", text: nil, parentID: nil, terminal: .root)
        ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        XCTAssertEqual(result.target, .nonEditable)
        XCTAssertEqual(result.selectedText, "selected read-only text")
        XCTAssertTrue(result.reachedAXRoot)
    }

    func testEditableAndUnknownTextAreaRolesRemainFailClosed() {
        let explicitlyEditable = inspect(nodes: [
            0: FakeAXNode(role: "AXTextArea", text: "draft", valueIsSettable: true, parentID: nil, terminal: .root)
        ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)
        let unknownMutability = inspect(nodes: [
            0: FakeAXNode(role: "AXTextArea", text: "draft", parentID: nil, terminal: .root)
        ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        XCTAssertEqual(explicitlyEditable.target, .editable)
        XCTAssertEqual(unknownMutability.target, .editable)
    }

    func testReadOnlyMutabilityMatrixAcrossTextEntryRoles() {
        let roles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextEntryArea"]
        let mutabilityValues: [Bool?] = [nil, true, false]
        var scenarios = 0

        for role in roles {
            for valueIsSettable in mutabilityValues {
                scenarios += 1
                let result = inspect(nodes: [
                    0: FakeAXNode(role: role, text: "selection", valueIsSettable: valueIsSettable, parentID: 1, terminal: nil),
                    1: FakeAXNode(role: "AXApplication", text: nil, parentID: nil, terminal: .root)
                ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)
                let expected: SelectionAXTargetKind = valueIsSettable == false ? .nonEditable : .editable
                XCTAssertEqual(
                    result.target,
                    expected,
                    "scenario=\(scenarios) role=\(role) valueIsSettable=\(String(describing: valueIsSettable))"
                )
            }
        }

        scenarios += 1
        let secureField = inspect(nodes: [
            0: FakeAXNode(role: "AXSecureTextField", text: "secret", valueIsSettable: false, parentID: 1, terminal: nil),
            1: FakeAXNode(role: "AXApplication", text: nil, parentID: nil, terminal: .root)
        ], maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)
        XCTAssertEqual(secureField.target, .secure, "scenario=\(scenarios) secure input remains protected")
        XCTAssertNil(secureField.selectedText)
        XCTAssertEqual(scenarios, 16)
    }

    func testFocusedSelectionReadGateAcross324EndpointScenarios() {
        let targets: [SelectionAXTargetKind] = [.editable, .nonEditable, .unavailable]
        let texts: [String?] = [
            nil,
            "",
            " \n ",
            " endpoint text ",
            String(repeating: "x", count: 4_000),
            String(repeating: "x", count: 4_001)
        ]
        var scenarios = 0

        for downTarget in targets {
            for upTarget in targets {
                for downText in texts {
                    for upText in texts {
                        scenarios += 1
                        let hasUsableEndpointText = [upText, downText].contains { candidate in
                            candidate.map { SelectionTriggerPolicy.isValidSelectedText($0) } ?? false
                        }
                        let expected = downTarget != .editable
                            && upTarget != .editable
                            && !hasUsableEndpointText
                        XCTAssertEqual(
                            SelectionAccessibilityReader.shouldReadFocusedSelection(
                                downTarget: downTarget,
                                upTarget: upTarget,
                                downText: downText,
                                upText: upText
                            ),
                            expected,
                            "scenario=\(scenarios) down=\(downTarget) up=\(upTarget) downTextLength=\(downText?.count ?? -1) upTextLength=\(upText?.count ?? -1)"
                        )
                    }
                }
            }
        }

        XCTAssertEqual(scenarios, 324)
    }

    func testDeepEditableAncestorWinsAndDoesNotBecomeSafePageText() {
        let nodes = Dictionary(uniqueKeysWithValues: (0..<27).map { index in
            (index, FakeAXNode(
                role: index == 20 ? "AXTextArea" : (index == 26 ? "AXApplication" : "AXGroup"),
                text: index == 0 ? "selected input text" : nil,
                parentID: index == 26 ? nil : index + 1,
                terminal: index == 26 ? .root : nil
            ))
        })

        let result = inspect(nodes: nodes, maximumDepth: SelectionAccessibilityReader.maximumAncestorDepth)

        XCTAssertEqual(result.target, .editable)
        XCTAssertFalse(result.ancestorLimitReached)
    }

    func testAXRootWithUnknownRoleAndFailedParentBothFailClosed() {
        let root = [0: FakeAXNode(role: "AXVendorWidget", text: nil, parentID: nil, terminal: .root)]
        let failedParent = [0: FakeAXNode(role: "AXStaticText", text: "text must not escape", parentID: nil, terminal: .failed(-25204))]

        let rootResult = inspect(nodes: root, maximumDepth: 32)
        let failedResult = inspect(nodes: failedParent, maximumDepth: 32)

        XCTAssertEqual(rootResult.target, .unavailable)
        XCTAssertTrue(rootResult.reachedAXRoot)
        XCTAssertEqual(failedResult.target, .unavailable)
        XCTAssertNil(failedResult.selectedText)
        XCTAssertEqual(failedResult.lastError, -25204)
    }

    func testTimeoutAndDepthLimitAreDistinguishedFromAXRoot() {
        let timedOut = [0: FakeAXNode(role: nil, text: nil, parentID: nil, terminal: .timedOut)]
        let deepNodes = Dictionary(uniqueKeysWithValues: (0...32).map { index in
            (index, FakeAXNode(role: "AXGroup", text: nil, parentID: index == 32 ? nil : index + 1, terminal: index == 32 ? .root : nil))
        })

        let timeoutResult = inspect(nodes: timedOut, maximumDepth: 32)
        let depthResult = inspect(nodes: deepNodes, maximumDepth: 32)

        XCTAssertTrue(timeoutResult.timedOut)
        XCTAssertFalse(timeoutResult.ancestorLimitReached)
        XCTAssertTrue(depthResult.ancestorLimitReached)
        XCTAssertFalse(depthResult.reachedAXRoot)
        XCTAssertEqual(depthResult.target, .unavailable)
    }

    private func inspect(nodes: [Int: FakeAXNode], maximumDepth: Int) -> SelectionAXAncestorInspection {
        SelectionTriggerPolicy.inspectAXAncestorChain(startingAt: 0, maximumDepth: maximumDepth) { id in
            guard let node = nodes[id] else { return .failed(error: -1) }
            if let parentID = node.parentID {
                return .parent(
                    role: node.role,
                    selectedText: node.text,
                    valueIsSettable: node.valueIsSettable,
                    node: parentID
                )
            }
            switch node.terminal ?? .root {
            case .root:
                return .root(role: node.role, selectedText: node.text, valueIsSettable: node.valueIsSettable)
            case let .failed(error):
                return .failed(error: error)
            case .timedOut:
                return .timedOut
            }
        }
    }
}

private struct FakeAXNode {
    let role: String?
    let text: String?
    var valueIsSettable: Bool? = nil
    let parentID: Int?
    let terminal: Terminal?

    enum Terminal {
        case root
        case failed(Int32)
        case timedOut
    }
}
