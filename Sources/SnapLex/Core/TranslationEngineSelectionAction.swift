import Foundation

@MainActor
enum TranslationEngineSelectionAction {
    @discardableResult
    static func select(
        _ engine: TranslationEngine,
        currentEngine: TranslationEngine,
        updateSetting: () -> Void,
        rerunCurrentInput: () -> Void
    ) -> Bool {
        guard engine != currentEngine else { return false }
        updateSetting()
        rerunCurrentInput()
        return true
    }
}
