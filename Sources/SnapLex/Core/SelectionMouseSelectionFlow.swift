import Foundation

enum SelectionMouseFlowOutcome: Equatable, Sendable {
    case suppressedBeforeAccessibility(MouseSelectionSuppressionReason)
    case cancelledBeforeAccessibility
    case cancelledAfterAccessibility(SelectionAXSnapshot)
    case suppressedAfterAccessibility(MouseSelectionSuppressionReason, SelectionAXSnapshot)
    case accepted(SelectionAXSnapshot)
    case acceptedByCompatibilityCopy(text: String, snapshot: SelectionAXSnapshot)
}

/// Owns the async stage ordering used by the global mouse-selection monitor.
/// All system effects are injected so timeouts, app switches, and stale AX
/// responses can be tested without installing event monitors or touching TCC.
@MainActor
enum SelectionMouseSelectionFlow {
    static func resolve(
        gesture: SelectionMouseGestureSnapshot,
        ownProcessIdentifier: pid_t,
        isEnabled: @MainActor () -> Bool,
        isCurrentGesture: @MainActor () -> Bool,
        foregroundProcessIdentifier: @MainActor () -> pid_t?,
        waitForSelectionToSettle: @MainActor () async -> Void,
        readAccessibility: @MainActor (SelectionMouseGestureSnapshot) async -> SelectionAXSnapshot,
        isDuplicate: @MainActor (String, TimeInterval) -> Bool,
        readCompatibilitySelection: @MainActor (SelectionAXSnapshot) async -> String? = { _ in nil },
        onAccepted: @MainActor (String) -> Void
    ) async -> SelectionMouseFlowOutcome {
        let preflight = SelectionTriggerPolicy.evaluateMouseSelection(
            gesture: gesture,
            ownProcessIdentifier: ownProcessIdentifier,
            isEnabled: isEnabled()
        )
        switch preflight {
        case .eligible:
            break
        case let .suppressed(reason):
            return .suppressedBeforeAccessibility(reason)
        }

        guard let sourceProcessIdentifier = gesture.up.processIdentifier,
              isCurrentGesture(),
              foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledBeforeAccessibility
        }

        await waitForSelectionToSettle()

        guard isCurrentGesture(),
              foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledBeforeAccessibility
        }
        guard isEnabled() else {
            return .suppressedBeforeAccessibility(.settingDisabled)
        }

        let snapshot = await readAccessibility(gesture)

        guard isCurrentGesture(),
              foregroundProcessIdentifier() == sourceProcessIdentifier else {
            return .cancelledAfterAccessibility(snapshot)
        }
        guard isEnabled() else {
            return .suppressedAfterAccessibility(.settingDisabled, snapshot)
        }

        let candidateText = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = candidateText.map { isDuplicate($0, gesture.up.timestamp) } ?? false
        let evaluation = SelectionTriggerPolicy.evaluateMouseSelection(
            snapshot: snapshot,
            sourceProcessIdentifier: sourceProcessIdentifier,
            foregroundProcessIdentifier: foregroundProcessIdentifier(),
            ownProcessIdentifier: ownProcessIdentifier,
            isEnabled: isEnabled(),
            isDuplicate: duplicate
        )

        switch evaluation {
        case let .accepted(text):
            onAccepted(text)
            return .accepted(snapshot)
        case let .suppressed(reason):
            if reason == .timedOutOrWrongProcess || reason == .emptyOrInvalidText,
               let copiedText = await readCompatibilitySelection(snapshot) {
                guard isCurrentGesture(), foregroundProcessIdentifier() == sourceProcessIdentifier else {
                    return .cancelledAfterAccessibility(snapshot)
                }
                guard isEnabled() else { return .suppressedAfterAccessibility(.settingDisabled, snapshot) }
                let text = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard SelectionTriggerPolicy.isValidSelectedText(text) else {
                    return .suppressedAfterAccessibility(.emptyOrInvalidText, snapshot)
                }
                guard !isDuplicate(text, gesture.up.timestamp) else {
                    return .suppressedAfterAccessibility(.duplicate, snapshot)
                }
                onAccepted(text)
                return .acceptedByCompatibilityCopy(text: text, snapshot: snapshot)
            }
            return .suppressedAfterAccessibility(reason, snapshot)
        }
    }
}
