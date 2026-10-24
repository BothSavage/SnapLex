import Foundation
import NaturalLanguage
import Translation

public enum TranslationTaskMode: String {
    case translate = "翻译"
}

@MainActor
public enum NativeTranslationSupport {
    private static let supportedLanguageIdentifiers: Set<String> = [
        "ar-AE", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
        "nl", "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh", "zh-TW"
    ]

    public static func isPredominantlyChinese(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var hanCount = 0
        var alphaCount = 0
        for scalar in trimmed.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                hanCount += 1
            } else if CharacterSet.letters.contains(scalar) {
                alphaCount += 1
            }
        }
        return hanCount > 0 && hanCount * 2 >= alphaCount
    }

    public static func detectSourceLangLabel(_ text: String) -> String {
        isPredominantlyChinese(text) ? "自动检测 (中文)" : "自动检测"
    }

    public static func defaultTargetLanguage(for text: String) -> String {
        let source = sourceLanguageCode(for: text)
        return source == "zh" || source == "zh-TW" ? "English" : "简体中文"
    }

    public static func languageCode(for label: String) -> String {
        let code = AppSettings.targetLanguages.first(where: { $0.label == label })?.code ?? "zh-CN"
        return translationLanguageIdentifier(for: code)
    }

    /// Prefer identifiers from Apple's supportedLanguages list (for example `zh` and
    /// `en`, rather than the broader aliases `zh-Hans` and `en-US`).
    public static func sourceLanguageCode(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))

        if let language = recognizer.dominantLanguage?.rawValue,
           let supported = normalizedSupportedIdentifier(for: language) {
            return supported
        }

        return isPredominantlyChinese(text) ? "zh" : "en"
    }

    public static func distinctSourceLanguageCodes(in texts: [String], excluding targetCode: String) -> [String] {
        var seen = Set<String>()
        return texts.compactMap { text in
            let code = sourceLanguageCode(for: text)
            guard code != targetCode, seen.insert(code).inserted else { return nil }
            return code
        }
    }

    public static func makeConfiguration(
        source: String,
        target: String
    ) -> TranslationSession.Configuration {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        if #available(macOS 26.4, *) {
            return TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage,
                preferredStrategy: .lowLatency
            )
        }
        return TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
    }

    public static func preferredTargetCode(for text: String) -> String {
        let source = sourceLanguageCode(for: text)
        return source == "zh" || source == "zh-TW" ? "en" : "zh"
    }

    private static func translationLanguageIdentifier(for code: String) -> String {
        switch code {
        case "zh-CN", "zh-Hans": return "zh"
        case "zh-TW", "zh-Hant": return "zh-TW"
        default: return normalizedSupportedIdentifier(for: code) ?? code
        }
    }

    private static func normalizedSupportedIdentifier(for identifier: String) -> String? {
        switch identifier {
        case "zh", "zh-Hans", "zh-CN": return "zh"
        case "zh-Hant", "zh-TW": return "zh-TW"
        case "en-US", "en-GB": return "en"
        case "pt", "pt-PT": return "pt-BR"
        case "ar": return "ar-AE"
        default:
            let base = identifier.split(separator: "-").first.map(String.init) ?? identifier
            return supportedLanguageIdentifiers.contains(base) ? base : nil
        }
    }

    public static func userFacingError(for error: Error) -> String {
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            return L10n.string("系统语言包尚未安装，请允许系统下载后重试。")
        }
        if TranslationError.unsupportedLanguagePairing ~= error {
            return L10n.string("macOS 暂不支持这组源语言和目标语言。")
        }
        if TranslationError.unsupportedSourceLanguage ~= error ||
            TranslationError.unsupportedTargetLanguage ~= error {
            return L10n.string("macOS 暂不支持识别出的源语言或所选目标语言。")
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return L10n.string("无法识别原文语言，请多选一些完整句子后重试。")
        }
        if TranslationError.internalError ~= error {
            return L10n.string("系统翻译服务没有完成语言包准备；首次使用时请允许下载语言包后重试。")
        }
        return L10n.string("系统翻译暂不可用，请检查网络和系统语言包后重试。")
    }
}
