import XCTest
import SwiftUI
@testable import SnapLex

final class AppearanceAndLanguageTests: XCTestCase {
    func testAppearanceModeSupportsSystemLightAndDark() {
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .system, system: .light), .light)
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .system, system: .dark), .dark)
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .light, system: .dark), .light)
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .dark, system: .light), .dark)
    }

    func testEverySelectableAppLanguageHasACatalog() {
        XCTAssertEqual(
            L10n.supportedLanguages,
            Set(AppLanguage.allCases.map(\.rawValue))
        )
    }

    func testAllAppLanguageCatalogsCoverTheSameKeys() {
        let defaultKeys = L10n.catalogKeys(in: L10n.defaultLanguage)
        XCTAssertFalse(defaultKeys.isEmpty)

        for language in AppLanguage.allCases {
            XCTAssertEqual(
                L10n.catalogKeys(in: language.rawValue),
                defaultKeys,
                "Missing localized strings for \(language.rawValue)"
            )
        }
    }
}
