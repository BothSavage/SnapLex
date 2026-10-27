import AppKit
import ApplicationServices
import XCTest
@testable import SnapLex

@MainActor
final class WeChatSelectionCompatibilityTests: XCTestCase {
    func testWeChatMissingAXSelectionCanFallBackButOtherAppsAndProtectedTargetsCannot() {
        let unavailable = snapshot()
        XCTAssertTrue(SelectionCompatibilityPolicy.canCopyWeChatSelection(bundleIdentifier: "com.tencent.xinWeChat", sourceProcessIdentifier: 42, snapshot: unavailable))
        XCTAssertFalse(SelectionCompatibilityPolicy.canCopyWeChatSelection(bundleIdentifier: "com.example.OtherApp", sourceProcessIdentifier: 42, snapshot: unavailable))
        for target in [SelectionAXTargetKind.editable, .secure] {
            XCTAssertFalse(SelectionCompatibilityPolicy.canCopyWeChatSelection(bundleIdentifier: "com.tencent.xinWeChat", sourceProcessIdentifier: 42, snapshot: snapshot(down: target)))
        }
        XCTAssertFalse(SelectionCompatibilityPolicy.canCopyWeChatSelection(bundleIdentifier: "com.tencent.xinWeChat", sourceProcessIdentifier: 42, snapshot: snapshot(downPID: 99)))
        XCTAssertFalse(SelectionCompatibilityPolicy.canCopyWeChatSelection(bundleIdentifier: "com.tencent.xinWeChat", sourceProcessIdentifier: 42, snapshot: snapshot(timedOut: true)))
    }

    func testCompatibilityCopyReadsNewTextAndRestoresAllOriginalClipboardRepresentations() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents() }
        let binaryType = NSPasteboard.PasteboardType("io.github.snaplex.test-binary")
        let first = NSPasteboardItem()
        first.setString("original clipboard", forType: .string)
        first.setData(Data([0, 1, 254, 255]), forType: binaryType)
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        board.writeObjects([first, second])
        let text = await SelectionClipboardCapture.readSelection(
            from: board, canContinue: { true },
            sendCopy: { board.clearContents(); board.setString(" agent ", forType: .string) },
            waitForPasteboard: {}
        )
        XCTAssertEqual(text, "agent")
        let restored = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].string(forType: .string), "original clipboard")
        XCTAssertEqual(restored[0].data(forType: binaryType), Data([0, 1, 254, 255]))
        XCTAssertEqual(restored[1].string(forType: .string), "second item")
    }

    func testUnchangedClipboardIsNeverMistakenForWeChatSelection() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents() }
        board.setString("stale clipboard", forType: .string)
        let text = await SelectionClipboardCapture.readSelection(from: board, canContinue: { true }, sendCopy: {}, waitForPasteboard: {})
        XCTAssertNil(text)
        XCTAssertEqual(board.string(forType: .string), "stale clipboard")
    }

    func testSourceChangeBeforeCopyAndOversizedBackupSkipSyntheticCopy() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents() }
        board.setString("original", forType: .string)
        let changedSource = await SelectionClipboardCapture.readSelection(
            from: board, canContinue: { false }, sendCopy: { XCTFail("Source changed") }, waitForPasteboard: {}
        )
        XCTAssertNil(changedSource)
        let largeBackup = await SelectionClipboardCapture.readSelection(
            from: board, maximumSnapshotBytes: 1, canContinue: { true }, sendCopy: { XCTFail("Cannot preserve clipboard") }, waitForPasteboard: {}
        )
        XCTAssertNil(largeBackup)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testNewerClipboardWriteIsNotOverwrittenByRestore() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.clearContents() }
        board.setString("original", forType: .string)
        var checks = 0
        let text = await SelectionClipboardCapture.readSelection(
            from: board,
            canContinue: {
                checks += 1
                if checks == 4 { board.clearContents(); board.setString("new user copy", forType: .string) }
                return true
            },
            sendCopy: { board.clearContents(); board.setString("agent", forType: .string) },
            waitForPasteboard: {}
        )
        XCTAssertEqual(text, "agent")
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testWeChatCompatibilityResultTraversesProductionFlowAndAppSwitchDiscardsIt() async {
        let gesture = SelectionMouseGestureSnapshot(
            down: .init(x: 10, y: 20, timestamp: 10, processIdentifier: 42),
            up: .init(x: 60, y: 20, timestamp: 10.2, processIdentifier: 42, clickCount: 1), generation: 1
        )
        let unavailable = snapshot()
        var presented: [String] = []
        var foreground: pid_t? = 42
        for switchApps in [false, true] {
            foreground = 42
            let outcome = await SelectionMouseSelectionFlow.resolve(
                gesture: gesture, ownProcessIdentifier: 1,
                isEnabled: { true }, isCurrentGesture: { true }, foregroundProcessIdentifier: { foreground },
                waitForSelectionToSettle: {}, readAccessibility: { _ in unavailable }, isDuplicate: { _, _ in false },
                readCompatibilitySelection: { _ in if switchApps { foreground = 99 }; return "agent" },
                onAccepted: { presented.append($0) }
            )
            if switchApps {
                XCTAssertEqual(outcome, .cancelledAfterAccessibility(unavailable))
            } else {
                XCTAssertEqual(outcome, .acceptedByCompatibilityCopy(text: "agent", snapshot: unavailable))
            }
        }
        XCTAssertEqual(presented, ["agent"])
    }

    private func snapshot(down: SelectionAXTargetKind = .unavailable, downPID: pid_t? = nil, timedOut: Bool = false) -> SelectionAXSnapshot {
        SelectionAXSnapshot(
            focusedTarget: .unavailable, focusedProcessIdentifier: nil,
            downTarget: down, upTarget: .unavailable,
            downProcessIdentifier: downPID, upProcessIdentifier: nil,
            downAncestorLimitReached: false, upAncestorLimitReached: false,
            selectedText: nil, durationMilliseconds: 1, queueWaitMilliseconds: 0, workerDurationMilliseconds: 1,
            accessibilityCallCount: 3, lastAccessibilityError: Int32(AXError.noValue.rawValue), timedOut: timedOut
        )
    }
}
