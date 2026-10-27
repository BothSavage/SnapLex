import Foundation

enum SelectionAXTargetKind: Equatable, Sendable {
    case editable
    case secure
    case nonEditable
    case unavailable
}

enum MouseSelectionSuppressionReason: String, Equatable, Sendable {
    case notSelectionGesture
    case settingDisabled
    case touchesSnapLexWindow
    case foregroundChanged
    case snapLexIsFrontmost
    case timedOutOrWrongProcess
    case editableOrUnknownEndpoint
    case emptyOrInvalidText
    case duplicate
}

enum MouseSelectionEvaluation: Equatable, Sendable {
    case accepted(String)
    case suppressed(MouseSelectionSuppressionReason)
}

enum MouseSelectionGestureEvaluation: Equatable, Sendable {
    case eligible
    case suppressed(MouseSelectionSuppressionReason)
}

enum SelectionAXAncestorRead<Node> {
    case parent(role: String?, selectedText: String?, valueIsSettable: Bool?, node: Node)
    case root(role: String?, selectedText: String?, valueIsSettable: Bool?)
    case failed(error: Int32)
    case timedOut
}

struct SelectionAXAncestorInspection: Equatable, Sendable {
    let target: SelectionAXTargetKind
    let selectedText: String?
    let reachedAXRoot: Bool
    let ancestorLimitReached: Bool
    let timedOut: Bool
    let lastError: Int32?
}

enum SelectionTriggerPolicy {
    /// Internal evidence marker used after an AX text-entry role explicitly
    /// reports that its value cannot be changed. The original role alone is
    /// ambiguous because read-only NSTextView elements are also AXTextArea.
    private static let readOnlyTextEntryAXRole = "AXReadOnlyTextEntry"

    static let editableAXRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXSecureTextField", "AXTextEntryArea"
    ]
    static let nonEditableAXRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXGroup",
        "AXStaticText", "AXWebArea", "AXDocument", "AXHeading", "AXLink",
        "AXButton", "AXImage", "AXList", "AXRow", "AXCell", "AXTable",
        "AXOutline", "AXColumn", "AXTextGroup", "AXParagraph", "AXToolbar",
        "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXSlider",
        "AXProgressIndicator", "AXTabGroup", "AXTab", "AXScrollArea",
        "AXSplitGroup", "AXBrowser", "AXMenu", "AXMenuItem",
        readOnlyTextEntryAXRole
    ]

    static func isSelectionGesture(
        distance: CGFloat,
        duration: TimeInterval,
        clickCount: Int
    ) -> Bool {
        let isDragSelect = distance >= 10 && duration >= 0.05 && duration <= 12.0
        let isMultiClickSelect = clickCount == 2 || clickCount == 3
        return isDragSelect || isMultiClickSelect
    }

    static func shouldShowMouseSelection(
        focusedTarget: SelectionAXTargetKind,
        downTarget: SelectionAXTargetKind,
        upTarget: SelectionAXTargetKind,
        isEnabled: Bool = true,
        foregroundAppUnchanged: Bool = true,
        selectionPointsBelongToSnapLex: Bool = false
    ) -> Bool {
        guard isEnabled, foregroundAppUnchanged, !selectionPointsBelongToSnapLex else { return false }
        guard downTarget != .secure, upTarget != .secure else { return false }

        // A real selection inside an ordinary editor is translatable too.
        // Require both hit tests to identify the editor so stale focused text
        // cannot authorize a gesture made elsewhere on the page.
        if downTarget == .editable || upTarget == .editable {
            return downTarget == .editable && upTarget == .editable
        }

        // A stale text-field focus must not suppress a selection made in the
        // page body; the hit-tested endpoints are a stronger signal.
        if downTarget == .nonEditable, upTarget == .nonEditable {
            return true
        }
        return focusedTarget == .nonEditable
    }

    static func canUseAXSnapshot(
        timedOut: Bool,
        downProcessIdentifier: pid_t?,
        upProcessIdentifier: pid_t?,
        sourceProcessIdentifier: pid_t
    ) -> Bool {
        !timedOut
            && downProcessIdentifier == sourceProcessIdentifier
            && upProcessIdentifier == sourceProcessIdentifier
    }

    /// Mouse selection may use a focused non-editable AX selection as a
    /// fallback when a hit-test endpoint is unavailable. Any endpoint that
    /// was resolved must still belong to the captured source app, and an
    /// unavailable endpoint must never contradict that ownership.
    static func canUseMouseAXSnapshot(
        _ snapshot: SelectionAXSnapshot,
        sourceProcessIdentifier: pid_t
    ) -> Bool {
        guard !snapshot.timedOut else { return false }

        let downBelongsToSource = snapshot.downTarget != .unavailable
            && snapshot.downProcessIdentifier == sourceProcessIdentifier
        let upBelongsToSource = snapshot.upTarget != .unavailable
            && snapshot.upProcessIdentifier == sourceProcessIdentifier
        let focusedBelongsToSource = snapshot.focusedTarget != .unavailable
            && snapshot.focusedProcessIdentifier == sourceProcessIdentifier

        if let downPID = snapshot.downProcessIdentifier, downPID != sourceProcessIdentifier { return false }
        if let upPID = snapshot.upProcessIdentifier, upPID != sourceProcessIdentifier { return false }
        if snapshot.downTarget != .unavailable && snapshot.downProcessIdentifier != sourceProcessIdentifier { return false }
        if snapshot.upTarget != .unavailable && snapshot.upProcessIdentifier != sourceProcessIdentifier { return false }

        return downBelongsToSource || upBelongsToSource || focusedBelongsToSource
    }

    static func evaluateMouseSelection(
        gesture: SelectionMouseGestureSnapshot,
        ownProcessIdentifier: pid_t,
        isEnabled: Bool
    ) -> MouseSelectionGestureEvaluation {
        guard isSelectionGesture(
            distance: CGFloat(gesture.distance),
            duration: gesture.duration,
            clickCount: gesture.up.clickCount
        ) else {
            return .suppressed(.notSelectionGesture)
        }
        guard isEnabled else { return .suppressed(.settingDisabled) }
        guard !gesture.touchesSnapLexWindow else {
            return .suppressed(.touchesSnapLexWindow)
        }
        guard let upProcessIdentifier = gesture.up.processIdentifier else {
            return .suppressed(.foregroundChanged)
        }
        guard upProcessIdentifier != ownProcessIdentifier else {
            return .suppressed(.snapLexIsFrontmost)
        }
        guard mouseGestureHasSafeExternalSource(
            mouseDownProcessIdentifier: gesture.down.processIdentifier,
            mouseUpProcessIdentifier: gesture.up.processIdentifier,
            ownProcessIdentifier: ownProcessIdentifier,
            mouseDownIsInsideSnapLexWindow: gesture.down.isInsideSnapLexWindow
        ) else {
            return .suppressed(.foregroundChanged)
        }
        return .eligible
    }

    static func evaluateMouseSelection(
        snapshot: SelectionAXSnapshot,
        sourceProcessIdentifier: pid_t,
        foregroundProcessIdentifier: pid_t?,
        ownProcessIdentifier: pid_t,
        isEnabled: Bool,
        isDuplicate: Bool
    ) -> MouseSelectionEvaluation {
        guard isEnabled else { return .suppressed(.settingDisabled) }
        guard foregroundProcessIdentifier == sourceProcessIdentifier else {
            return .suppressed(.foregroundChanged)
        }
        guard sourceProcessIdentifier != ownProcessIdentifier else {
            return .suppressed(.snapLexIsFrontmost)
        }
        guard canUseMouseAXSnapshot(snapshot, sourceProcessIdentifier: sourceProcessIdentifier) else {
            return .suppressed(.timedOutOrWrongProcess)
        }
        guard shouldShowMouseSelection(
            focusedTarget: snapshot.focusedTarget,
            downTarget: snapshot.downTarget,
            upTarget: snapshot.upTarget,
            isEnabled: true,
            foregroundAppUnchanged: true
        ) else {
            return .suppressed(.editableOrUnknownEndpoint)
        }
        guard let selected = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              isValidSelectedText(selected) else {
            return .suppressed(.emptyOrInvalidText)
        }
        guard !isDuplicate else { return .suppressed(.duplicate) }
        return .accepted(selected)
    }

    static func inspectAXAncestorChain<Node>(
        startingAt start: Node,
        maximumDepth: Int,
        read: (Node) -> SelectionAXAncestorRead<Node>
    ) -> SelectionAXAncestorInspection {
        guard maximumDepth > 0 else {
            return SelectionAXAncestorInspection(
                target: .unavailable,
                selectedText: nil,
                reachedAXRoot: false,
                ancestorLimitReached: true,
                timedOut: false,
                lastError: nil
            )
        }

        var current = start
        var roles: [String] = []
        var selectedText: String?

        func append(role: String?, text: String?, valueIsSettable: Bool?) -> Bool {
            if role == "AXSecureTextField" {
                roles.append("AXSecureTextField")
                selectedText = nil
                return true
            }
            if let role {
                if editableAXRoles.contains(role),
                   role != "AXSecureTextField",
                   valueIsSettable == false {
                    roles.append(readOnlyTextEntryAXRole)
                } else {
                    roles.append(role)
                }
            }
            if let text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               selectedText == nil {
                selectedText = text
            }
            return editableAXRoles.contains(role ?? "") && valueIsSettable != false
        }

        for _ in 0..<maximumDepth {
            switch read(current) {
            case let .parent(role, text, valueIsSettable, parent):
                if append(role: role, text: text, valueIsSettable: valueIsSettable) {
                    return SelectionAXAncestorInspection(
                        target: role == "AXSecureTextField" ? .secure : .editable,
                        selectedText: role == "AXSecureTextField" ? nil : selectedText,
                        reachedAXRoot: false,
                        ancestorLimitReached: false,
                        timedOut: false,
                        lastError: nil
                    )
                }
                current = parent
            case let .root(role, text, valueIsSettable):
                if append(role: role, text: text, valueIsSettable: valueIsSettable) {
                    return SelectionAXAncestorInspection(
                        target: role == "AXSecureTextField" ? .secure : .editable,
                        selectedText: role == "AXSecureTextField" ? nil : selectedText,
                        reachedAXRoot: true,
                        ancestorLimitReached: false,
                        timedOut: false,
                        lastError: nil
                    )
                }
                return SelectionAXAncestorInspection(
                    target: classifyAXRoleChain(roles, reachedAXRoot: true),
                    selectedText: selectedText,
                    reachedAXRoot: true,
                    ancestorLimitReached: false,
                    timedOut: false,
                    lastError: nil
                )
            case let .failed(error):
                return SelectionAXAncestorInspection(
                    target: .unavailable,
                    selectedText: nil,
                    reachedAXRoot: false,
                    ancestorLimitReached: false,
                    timedOut: false,
                    lastError: error
                )
            case .timedOut:
                return SelectionAXAncestorInspection(
                    target: .unavailable,
                    selectedText: nil,
                    reachedAXRoot: false,
                    ancestorLimitReached: false,
                    timedOut: true,
                    lastError: nil
                )
            }
        }

        return SelectionAXAncestorInspection(
            target: .unavailable,
            selectedText: nil,
            reachedAXRoot: false,
            ancestorLimitReached: true,
            timedOut: false,
            lastError: nil
        )
    }

    static func mouseGestureHasSafeExternalSource(
        mouseDownProcessIdentifier: pid_t?,
        mouseUpProcessIdentifier: pid_t?,
        ownProcessIdentifier: pid_t,
        mouseDownIsInsideSnapLexWindow: Bool = false
    ) -> Bool {
        guard let mouseDownProcessIdentifier,
              let mouseUpProcessIdentifier else { return false }
        guard mouseUpProcessIdentifier != ownProcessIdentifier else { return false }
        if mouseDownProcessIdentifier == ownProcessIdentifier {
            // macOS may report SnapLex as frontmost for the down event when
            // the gesture starts by activating another app. The event's
            // screen point must be outside every SnapLex window; AX hit-tests
            // below still have to resolve both endpoints to the external app.
            return !mouseDownIsInsideSnapLexWindow
        }
        return mouseDownProcessIdentifier == mouseUpProcessIdentifier
    }

    static func shouldAllowDoubleCopy(focusedTarget: SelectionAXTargetKind) -> Bool {
        focusedTarget == .nonEditable
    }

    /// A clipboard copy can advance the change count once, or twice when the
    /// source app clears and then writes the pasteboard between polls. A larger
    /// jump is ambiguous, so it starts a fresh candidate instead of triggering.
    static func isPlausibleTextClipboardCopyChange(
        changeCountDelta: Int,
        pasteboardContainsString: Bool
    ) -> Bool {
        pasteboardContainsString && (1...2).contains(changeCountDelta)
    }

    static func shouldAllowSyntheticCopy(
        focusedTarget: SelectionAXTargetKind,
        downTarget: SelectionAXTargetKind,
        upTarget: SelectionAXTargetKind,
        hasAXSelection: Bool = false,
        hasAccessibilityPermission: Bool = true,
        isEnabled: Bool = true
    ) -> Bool {
        guard isEnabled, hasAccessibilityPermission, !hasAXSelection else { return false }
        guard focusedTarget == .nonEditable else { return false }
        guard downTarget != .editable, upTarget != .editable else { return false }
        // A stale focused web search field must not authorize synthetic Cmd+C
        // over another region. Both hit-tested endpoints must be proven safe.
        return downTarget == .nonEditable && upTarget == .nonEditable
    }

    static func shouldShowDoubleCopy(
        focusedTarget: SelectionAXTargetKind,
        isEnabled: Bool,
        isSecondClipboardChangeWithinWindow: Bool,
        clipboardSnapshotIsStable: Bool,
        foregroundAppUnchanged: Bool,
        isDuplicateSelection: Bool
    ) -> Bool {
        isEnabled
            && isSecondClipboardChangeWithinWindow
            && clipboardSnapshotIsStable
            && foregroundAppUnchanged
            && !isDuplicateSelection
            && focusedTarget == .nonEditable
    }

    static func classifyAXRoleChain(
        _ roles: [String],
        hasEditableAncestor: Bool = false,
        reachedAXRoot: Bool
    ) -> SelectionAXTargetKind {
        if roles.contains("AXSecureTextField") { return .secure }
        if hasEditableAncestor || roles.contains(where: editableAXRoles.contains) {
            return .editable
        }
        let containsKnownNonEditableRole = roles.contains(where: nonEditableAXRoles.contains)
        return reachedAXRoot && containsKnownNonEditableRole ? .nonEditable : .unavailable
    }

    static func normalizedTextEntryRole(role: String?, subrole: String?) -> String? {
        // AppKit and browser providers may expose password fields as an
        // AXTextField whose AXSubrole is AXSecureTextField.
        role == "AXSecureTextField" || subrole == "AXSecureTextField" ? "AXSecureTextField" : role
    }

    static func isValidSelectedText(_ text: String, maximumCharacters: Int = 4_000) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumCharacters
    }

    static func preferredSelectedText(
        upText: String?,
        downText: String?,
        focusedText: String?,
        focusedTarget: SelectionAXTargetKind
    ) -> String? {
        for candidate in [upText, downText] {
            guard let candidate,
                  isValidSelectedText(candidate) else { continue }
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard focusedTarget == .nonEditable,
              let focusedText,
              isValidSelectedText(focusedText) else { return nil }
        return focusedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isDuplicate(
        text: String,
        processIdentifier: pid_t,
        lastText: String,
        lastProcessIdentifier: pid_t?,
        now: TimeInterval,
        lastTime: TimeInterval,
        window: TimeInterval = 0.8
    ) -> Bool {
        text == lastText
            && processIdentifier == lastProcessIdentifier
            && now >= lastTime
            && now - lastTime < window
    }
}

struct DoubleCopyCandidateState: Equatable {
    private(set) var timestamp: TimeInterval?
    private(set) var processIdentifier: pid_t?

    /// Returns true only when a second plausible copy is observed from the
    /// same app inside the configured interval. A first/expired/cross-app copy
    /// replaces the candidate and cannot trigger a popup.
    mutating func observeCopy(
        timestamp: TimeInterval,
        processIdentifier: pid_t,
        window: TimeInterval = 0.60
    ) -> Bool {
        if let previousTimestamp = self.timestamp,
           self.processIdentifier == processIdentifier,
           timestamp >= previousTimestamp,
           timestamp - previousTimestamp <= window {
            reset()
            return true
        }

        self.timestamp = timestamp
        self.processIdentifier = processIdentifier
        return false
    }

    mutating func reset() {
        timestamp = nil
        processIdentifier = nil
    }
}
