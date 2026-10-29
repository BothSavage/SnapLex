import Foundation

enum SelectionDirectCaptureSource: Equatable, Sendable {
    case accessibility
    case syntheticCopy
}

enum SelectionDirectCaptureSuppression: String, Equatable, Sendable {
    case snapLexIsFrontmost
    case foregroundChanged
    case timedOutOrWrongProcess
    case editableOrUnknownEndpoint
    case permissionUnavailable
    case unsafeSyntheticCopy
    case copyDidNotProduceText
    case emptyOrInvalidText
}

enum SelectionDirectCaptureOutcome: Equatable, Sendable {
    case accepted(text: String, source: SelectionDirectCaptureSource, snapshot: SelectionAXSnapshot)
    case suppressed(SelectionDirectCaptureSuppression, SelectionAXSnapshot?)
    case cancelledBeforeAccessibility
    case cancelledAfterAccessibility(SelectionAXSnapshot)
    case cancelledBeforeSyntheticCopy(SelectionAXSnapshot)
    case cancelledAfterSyntheticCopy(SelectionAXSnapshot)
}

/// Guards the direct-translate path around every asynchronous boundary so a
/// shortcut cannot copy from or present content belonging to a newly focused app.
@MainActor
enum SelectionDirectCaptureFlow {
    static func resolve(
        sourceProcessIdentifier: pid_t,
        ownProcessIdentifier: pid_t,
        hasAccessibilityPermission: @MainActor () -> Bool,
        foregroundProcessIdentifier: @MainActor () -> pid_t?,
        readAccessibility: @MainActor () async -> SelectionAXSnapshot,
        synthesizeCopy: @MainActor () async -> String?,
        isCurrentRequest: @MainActor () -> Bool = { true }
    ) async -> SelectionDirectCaptureOutcome {
        guard sourceProcessIdentifier != ownProcessIdentifier else {
            return .suppressed(.snapLexIsFrontmost, nil)
        }
        guard !Task.isCancelled, isCurrentRequest(), foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledBeforeAccessibility
        }

        let snapshot = await readAccessibility()
        guard !Task.isCancelled, isCurrentRequest(), foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledAfterAccessibility(snapshot)
        }

        guard SelectionTriggerPolicy.canUseAXSnapshot(
            timedOut: snapshot.timedOut,
            downProcessIdentifier: snapshot.downProcessIdentifier,
            upProcessIdentifier: snapshot.upProcessIdentifier,
            sourceProcessIdentifier: sourceProcessIdentifier
        ) else {
            return .suppressed(.timedOutOrWrongProcess, snapshot)
        }
        guard snapshot.downTarget != .secure,
              snapshot.upTarget != .secure else {
            return .suppressed(.editableOrUnknownEndpoint, snapshot)
        }

        if let selected = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           SelectionTriggerPolicy.isValidSelectedText(selected) {
            if snapshot.downTarget == .editable || snapshot.upTarget == .editable {
                guard snapshot.downTarget == .editable, snapshot.upTarget == .editable else {
                    return .suppressed(.editableOrUnknownEndpoint, snapshot)
                }
            }
            return .accepted(text: selected, source: .accessibility, snapshot: snapshot)
        }

        guard snapshot.downTarget != .editable, snapshot.upTarget != .editable else {
            return .suppressed(.editableOrUnknownEndpoint, snapshot)
        }

        guard hasAccessibilityPermission() else {
            return .suppressed(.permissionUnavailable, snapshot)
        }
        guard SelectionTriggerPolicy.shouldAllowSyntheticCopy(
            focusedTarget: snapshot.focusedTarget,
            downTarget: snapshot.downTarget,
            upTarget: snapshot.upTarget,
            hasAXSelection: snapshot.selectedText != nil,
            hasAccessibilityPermission: true
        ) else {
            return .suppressed(.unsafeSyntheticCopy, snapshot)
        }
        guard !Task.isCancelled, isCurrentRequest(), foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledBeforeSyntheticCopy(snapshot)
        }

        guard let copied = await synthesizeCopy() else {
            return .suppressed(.copyDidNotProduceText, snapshot)
        }
        guard !Task.isCancelled, isCurrentRequest(), foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledAfterSyntheticCopy(snapshot)
        }
        let normalizedCopy = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SelectionTriggerPolicy.isValidSelectedText(normalizedCopy) else {
            return .suppressed(.emptyOrInvalidText, snapshot)
        }
        return .accepted(text: normalizedCopy, source: .syntheticCopy, snapshot: snapshot)
    }
}
