import XCTest
@testable import SnapLex

final class LocalizationCatalogTests: XCTestCase {
    func testCatalogDefaultsToSimplifiedChineseAndTranslatesCommonActions() {
        XCTAssertEqual(L10n.defaultLanguage, "zh-Hans")
        XCTAssertEqual(L10n.localizedString("翻译", language: "en"), "Translate")
        XCTAssertEqual(L10n.localizedString("翻译", language: "zh-Hans"), "翻译")
    }

    func testMissingTranslationsFallBackToTheChineseSourceText() {
        XCTAssertEqual(L10n.localizedString("未配置的中文提示", language: "en"), "未配置的中文提示")
    }
}
