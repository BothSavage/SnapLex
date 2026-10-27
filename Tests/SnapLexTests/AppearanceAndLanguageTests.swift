import XCTest
import SwiftUI
import AppKit
@testable import SnapLex

final class AppearanceAndLanguageTests: XCTestCase {
    func testAppearanceModeSupportsSystemLightAndDark() {
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .system, system: .light), .light)
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .system, system: .dark), .dark)
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .light, system: .dark), .light)
        XCTAssertEqual(SnapLexTheme.resolvedColorScheme(for: .dark, system: .light), .dark)
    }

    @MainActor
    func testAppKitAppearanceMatchesForcedPopoverColorScheme() throws {
        XCTAssertNil(SnapLexTheme.appKitAppearance(for: .system))
        XCTAssertEqual(
            SnapLexTheme.resolvedColorScheme(for: try XCTUnwrap(SnapLexTheme.appKitAppearance(for: .light))),
            .light
        )
        XCTAssertEqual(
            SnapLexTheme.resolvedColorScheme(for: try XCTUnwrap(SnapLexTheme.appKitAppearance(for: .dark))),
            .dark
        )
    }

    @MainActor
    func testPopoverAppearanceKeepsNativeAndSwiftUIColorSchemesInSync() throws {
        let popover = NSPopover()
        for (mode, expected) in [(SnapLexAppearanceMode.light, ColorScheme.light), (.dark, .dark)] {
            popover.appearance = SnapLexTheme.appKitAppearance(for: mode)
            XCTAssertEqual(
                SnapLexTheme.resolvedColorScheme(for: try XCTUnwrap(popover.appearance)),
                expected
            )
        }
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
