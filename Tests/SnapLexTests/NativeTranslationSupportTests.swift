import XCTest
import Translation
@testable import SnapLex

@MainActor
final class NativeTranslationSupportTests: XCTestCase {
    func testSourceDetectionAndDefaultTargets() {
        XCTAssertEqual(
            NativeTranslationSupport.sourceLanguageCode(for: "你好，这是一个简体中文翻译测试。"),
            "zh"
        )
        XCTAssertEqual(
            NativeTranslationSupport.sourceLanguageCode(for: "這是一個繁體中文測試。"),
            "zh-TW"
        )
        XCTAssertEqual(
            NativeTranslationSupport.sourceLanguageCode(for: "This is an English translation test."),
            "en"
        )
        XCTAssertEqual(
            NativeTranslationSupport.sourceLanguageCode(for: "こんにちは日本語の翻訳テストです。"),
            "ja"
        )

        XCTAssertEqual(NativeTranslationSupport.defaultTargetLanguage(for: "你好，这是一个中文测试。"), "English")
        XCTAssertEqual(NativeTranslationSupport.defaultTargetLanguage(for: "This is an English test."), "简体中文")
    }

    func testMixedOCRTextFindsEveryDistinctSourceLanguageExceptTheTarget() {
        let sources = NativeTranslationSupport.distinctSourceLanguageCodes(
            in: [
                "你好，这是中文。",
                "This is English.",
                "こんにちは、日本語です。",
                "再见。"
            ],
            excluding: "en"
        )

        XCTAssertEqual(sources, ["zh", "ja"])
    }

    func testTargetIdentifiersUseTranslationSupportedForms() {
        XCTAssertEqual(NativeTranslationSupport.languageCode(for: "English"), "en")
        XCTAssertEqual(NativeTranslationSupport.languageCode(for: "简体中文"), "zh")
        XCTAssertEqual(NativeTranslationSupport.languageCode(for: "繁體中文"), "zh-TW")
        XCTAssertEqual(NativeTranslationSupport.languageCode(for: "日本語"), "ja")
    }

    func testConfigurationUsesAnExplicitPair() {
        let configuration = NativeTranslationSupport.makeConfiguration(source: "zh", target: "en")

        XCTAssertEqual(configuration.source, Locale.Language(identifier: "zh"))
        XCTAssertEqual(configuration.target, Locale.Language(identifier: "en"))
        if #available(macOS 26.4, *) {
            XCTAssertEqual(configuration.preferredStrategy, .lowLatency)
        }
    }

    func testNativeTranslationSupportsChineseEnglishPairInBothDirections() async throws {
        let availability = LanguageAvailability()
        let chinese = Locale.Language(identifier: "zh")
        let english = Locale.Language(identifier: "en")

        let chineseToEnglish = await availability.status(from: chinese, to: english)
        let englishToChinese = await availability.status(from: english, to: chinese)

        guard chineseToEnglish != .unsupported, englishToChinese != .unsupported else {
            throw XCTSkip("This macOS host does not expose the Apple Translation Chinese-English pair.")
        }

        XCTAssertNotEqual(chineseToEnglish, .unsupported)
        XCTAssertNotEqual(englishToChinese, .unsupported)
    }

    func testInstalledNativeTranslationRunsInBothDirections() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Direct installed-language TranslationSession is available on macOS 26 and later.")
        }

        let availability = LanguageAvailability()
        let chinese = Locale.Language(identifier: "zh")
        let english = Locale.Language(identifier: "en")
        let chineseToEnglish = await availability.status(from: chinese, to: english)
        let englishToChinese = await availability.status(from: english, to: chinese)
        guard chineseToEnglish == .installed, englishToChinese == .installed else {
            throw XCTSkip("Install both Chinese-English system language pairs to run the native translation smoke test.")
        }

        let toEnglish = TranslationSession(installedSource: chinese, target: english)
        let englishResult = try await toEnglish.translate("你好，这是一个系统翻译测试。")
        XCTAssertFalse(englishResult.targetText.isEmpty)
        XCTAssertNotEqual(englishResult.targetText, englishResult.sourceText)

        let toChinese = TranslationSession(installedSource: english, target: chinese)
        let chineseResult = try await toChinese.translate("This is a system translation test.")
        XCTAssertFalse(chineseResult.targetText.isEmpty)
        XCTAssertNotEqual(chineseResult.targetText, chineseResult.sourceText)
    }
}
