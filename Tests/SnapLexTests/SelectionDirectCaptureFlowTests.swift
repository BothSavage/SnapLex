import XCTest
@testable import SnapLex

@MainActor
final class SelectionDirectCaptureFlowTests: XCTestCase {
    func testAXSelectionReturnsWithoutSyntheticCopy() async {
        let snapshot = makeSnapshot(text: "selected word")
        var copyCount = 0

        let outcome = await resolve(
            snapshot: snapshot,
            synthesizeCopy: { copyCount += 1; return "wrong" }
        )

        XCTAssertEqual(outcome, .accepted(text: "selected word", source: .accessibility, snapshot: snapshot))
        XCTAssertEqual(copyCount, 0)
    }

    func testForegroundSwitchDuringAXReadCancelsBeforeSyntheticCopy() async {
        var foregroundPID: pid_t? = 42
        var copyCount = 0

        let outcome = await resolve(
            snapshot: makeSnapshot(text: nil),
            foregroundProcessIdentifier: { foregroundPID },
            readAccessibility: {
                foregroundPID = 77
                return self.makeSnapshot(text: nil)
            },
            synthesizeCopy: { copyCount += 1; return "other app text" }
        )

        guard case .cancelledAfterAccessibility = outcome else {
            return XCTFail("Changing apps during AX must cancel the direct translation")
        }
        XCTAssertEqual(copyCount, 0, "Do not post Cmd+C to the newly focused app")
    }

    func testForegroundSwitchDuringSyntheticCopyDiscardsCopiedResult() async {
        var foregroundPID: pid_t? = 42
        var copyCount = 0

        let outcome = await resolve(
            snapshot: makeSnapshot(text: nil),
            foregroundProcessIdentifier: { foregroundPID },
            synthesizeCopy: {
                copyCount += 1
                foregroundPID = 77
                return "possibly stale text"
            }
        )

        guard case .cancelledAfterSyntheticCopy = outcome else {
            return XCTFail("Changing apps during copy must not open the translation card")
        }
        XCTAssertEqual(copyCount, 1)
    }

    func testSafeAXFallbackCopiesOnlyWhileSourceAppRemainsFrontmost() async {
        let snapshot = makeSnapshot(text: nil)
        var copyCount = 0

        let outcome = await resolve(
            snapshot: snapshot,
            synthesizeCopy: { copyCount += 1; return " copied word \n" }
        )

        XCTAssertEqual(outcome, .accepted(text: "copied word", source: .syntheticCopy, snapshot: snapshot))
        XCTAssertEqual(copyCount, 1)
    }

    func testSnapLexFrontmostAppSkipsAccessibilityAndCopy() async {
        var axReadCount = 0
        var copyCount = 0

        let outcome = await SelectionDirectCaptureFlow.resolve(
            sourceProcessIdentifier: 1,
            ownProcessIdentifier: 1,
            hasAccessibilityPermission: { true },
            foregroundProcessIdentifier: { 1 },
            readAccessibility: { axReadCount += 1; return makeSnapshot(text: "should not read") },
            synthesizeCopy: { copyCount += 1; return "should not copy" }
        )

        XCTAssertEqual(outcome, .suppressed(.snapLexIsFrontmost, nil))
        XCTAssertEqual(axReadCount, 0)
        XCTAssertEqual(copyCount, 0)
    }

    func testMissingPermissionAndEditableEndpointsNeverSynthesizeCopy() async {
        let noPermission = await resolve(
            snapshot: makeSnapshot(text: nil),
            hasAccessibilityPermission: false,
            synthesizeCopy: { XCTFail("No permission must suppress synthetic copy"); return nil }
        )
        guard case let .suppressed(permissionReason, _) = noPermission else {
            return XCTFail("Expected permission suppression")
        }
        XCTAssertEqual(permissionReason, .permissionUnavailable)

        let editable = await resolve(
            snapshot: makeSnapshot(text: nil, downTarget: .editable),
            synthesizeCopy: { XCTFail("Editable endpoint must suppress synthetic copy"); return nil }
        )
        guard case let .suppressed(editableReason, _) = editable else {
            return XCTFail("Expected editable endpoint suppression")
        }
        XCTAssertEqual(editableReason, .editableOrUnknownEndpoint)
    }

    func testWrongProcessAXSnapshotAndInvalidCopiedTextFailClosed() async {
        let wrongProcess = makeSnapshot(text: "unsafe", upPID: 77)
        let wrongProcessOutcome = await resolve(snapshot: wrongProcess)
        guard case let .suppressed(wrongProcessReason, _) = wrongProcessOutcome else {
            return XCTFail("Expected wrong process suppression")
        }
        XCTAssertEqual(wrongProcessReason, .timedOutOrWrongProcess)

        for copied in [" \n ", String(repeating: "x", count: 4_001)] {
            let invalidOutcome = await resolve(
                snapshot: makeSnapshot(text: nil),
                synthesizeCopy: { copied }
            )
            guard case let .suppressed(reason, _) = invalidOutcome else {
                return XCTFail("Invalid copied text must be rejected")
            }
            XCTAssertEqual(reason, .emptyOrInvalidText)
        }
    }

    private func resolve(
        snapshot: SelectionAXSnapshot,
        hasAccessibilityPermission: Bool = true,
        foregroundProcessIdentifier: @escaping @MainActor () -> pid_t? = { 42 },
        readAccessibility: (@MainActor () async -> SelectionAXSnapshot)? = nil,
        synthesizeCopy: @escaping @MainActor () async -> String? = { nil }
    ) async -> SelectionDirectCaptureOutcome {
        let readAX = readAccessibility ?? { snapshot }
        return await SelectionDirectCaptureFlow.resolve(
            sourceProcessIdentifier: 42,
            ownProcessIdentifier: 1,
            hasAccessibilityPermission: { hasAccessibilityPermission },
            foregroundProcessIdentifier: foregroundProcessIdentifier,
            readAccessibility: readAX,
            synthesizeCopy: synthesizeCopy
        )
    }

    private func makeSnapshot(
        text: String?,
        downTarget: SelectionAXTargetKind = .nonEditable,
        upTarget: SelectionAXTargetKind = .nonEditable,
        downPID: pid_t = 42,
        upPID: pid_t = 42
    ) -> SelectionAXSnapshot {
        SelectionAXSnapshot(
            focusedTarget: .nonEditable,
            focusedProcessIdentifier: 42,
            downTarget: downTarget,
            upTarget: upTarget,
            downProcessIdentifier: downPID,
            upProcessIdentifier: upPID,
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
