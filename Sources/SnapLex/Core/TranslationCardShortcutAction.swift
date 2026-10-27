import Foundation

enum TranslationCardShortcutAction: Equatable {
    case show
    case hide

    static func action(isVisible: Bool) -> Self {
        isVisible ? .hide : .show
    }
}
