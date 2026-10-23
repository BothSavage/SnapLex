import Foundation

public enum TranslationTaskMode: String {
    case translate = "翻译"
}

public final class LLMTranslationService {
    public static let shared = LLMTranslationService()

    private init() {}

    /// Detects if text contains predominantly Chinese characters
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
        return hanCount > 0 && (hanCount * 2 >= alphaCount)
    }

    public static func detectSourceLangLabel(_ text: String) -> String {
        if isPredominantlyChinese(text) {
            return "自动检测 (中文)"
        }
        return "自动检测"
    }

    public static func defaultTargetLanguage(for text: String) -> String {
        return isPredominantlyChinese(text) ? "English" : "简体中文"
    }

    public static func languageCode(for label: String) -> String {
        switch label {
        case "English": return "en"
        case "简体中文": return "zh-CN"
        case "繁體中文": return "zh-TW"
        case "日本語": return "ja"
        case "한국어": return "ko"
        case "Français": return "fr"
        case "Deutsch": return "de"
        default: return "zh-CN"
        }
    }

    public static func isWordOrShortTerm(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 42 else { return false }
        if trimmed.contains("\n") { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.count <= 3
    }

    // MARK: - Built-in Instant Neural Translation (Google GTX)

    public func translate(
        text: String,
        targetLangLabel: String
    ) async throws -> String {
        let targetCode = Self.languageCode(for: targetLangLabel)
        return try await translateViaZeroConfigGTX(text: text, targetCode: targetCode)
    }

    private func translateViaZeroConfigGTX(text: String, targetCode: String) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dt", value: "bd"),
            URLQueryItem(name: "q", value: text)
        ]

        guard let url = comps.url else { return "" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return ""
        }

        var translatedSentences = ""
        if let sentences = root.first as? [[Any]] {
            for item in sentences {
                if let seg = item.first as? String {
                    translatedSentences += seg
                }
            }
        }

        if Self.isWordOrShortTerm(text),
           root.count > 1,
           let dictBlocks = root[1] as? [[Any]] {
            var dictLines: [String] = []
            for block in dictBlocks {
                if block.count >= 2,
                   let pos = block[0] as? String,
                   let terms = block[1] as? [String] {
                    dictLines.append("• [\(pos)] \(terms.prefix(5).joined(separator: "；"))")
                }
            }
            if !dictLines.isEmpty {
                translatedSentences += "\n\n" + dictLines.joined(separator: "\n")
            }
        }

        return translatedSentences.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
