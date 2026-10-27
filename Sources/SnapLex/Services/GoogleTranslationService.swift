import Foundation

public struct GoogleTranslationResult: Equatable, Sendable {
    public let translation: String
    public let dictionaryEntries: [String]

    public init(translation: String, dictionaryEntries: [String] = []) {
        self.translation = translation
        self.dictionaryEntries = dictionaryEntries
    }

    public var combinedText: String {
        guard !dictionaryEntries.isEmpty else { return translation }
        return translation + "\n\n" + dictionaryEntries.map { "• " + $0 }.joined(separator: "\n")
    }
}

public enum GoogleTranslationError: LocalizedError {
    case invalidResponse
    case emptyTranslation
    case serverRejected(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.string("Google 翻译返回了无法识别的结果。")
        case .emptyTranslation:
            return L10n.string("Google 翻译没有返回译文。")
        case .serverRejected(let status):
            return L10n.format("Google 翻译请求失败（HTTP %d）。", status)
        }
    }
}

public final class GoogleTranslationService {
    public static let shared = GoogleTranslationService(session: .shared)

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    public func translate(text: String, targetLanguage: String, includeDictionary: Bool = true) async throws -> String {
        let result = try await translateDetailed(text: text, targetLanguage: targetLanguage)
        return includeDictionary ? result.combinedText : result.translation
    }

    public func translateDetailed(text: String, targetLanguage: String) async throws -> GoogleTranslationResult {
        guard var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            throw GoogleTranslationError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: Self.googleLanguageCode(for: targetLanguage)),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dt", value: "bd"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components.url else { throw GoogleTranslationError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw GoogleTranslationError.serverRejected(response.statusCode)
        }
        return try Self.parseDetailedResponse(data: data, originalText: text)
    }

    public func translate(texts: [String], targetLanguage: String) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        var results = Array(repeating: "", count: texts.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var nextIndex = 0
            let initialCount = min(4, texts.count)
            while nextIndex < initialCount {
                let index = nextIndex
                let text = texts[index]
                group.addTask {
                    (index, try await self.translate(text: text, targetLanguage: targetLanguage, includeDictionary: false))
                }
                nextIndex += 1
            }

            while let (index, translated) = try await group.next() {
                results[index] = translated
                guard nextIndex < texts.count else { continue }
                let next = nextIndex
                let text = texts[next]
                group.addTask {
                    (next, try await self.translate(text: text, targetLanguage: targetLanguage, includeDictionary: false))
                }
                nextIndex += 1
            }
        }
        return results
    }

    static func googleLanguageCode(for label: String) -> String {
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

    static func parseResponse(data: Data, originalText: String, includeDictionary: Bool = true) throws -> String {
        let result = try parseDetailedResponse(data: data, originalText: originalText)
        guard includeDictionary else { return result.translation }
        return result.combinedText
    }

    static func parseDetailedResponse(data: Data, originalText: String) throws -> GoogleTranslationResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [[Any]] else {
            throw GoogleTranslationError.invalidResponse
        }

        let output = sentences.compactMap { $0.first as? String }.joined()
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GoogleTranslationError.emptyTranslation
        }

        var dictionaryEntries: [String] = []
        let isShortTerm = originalText.trimmingCharacters(in: .whitespacesAndNewlines).count <= 42
            && !originalText.contains("\n")
        if isShortTerm, root.count > 1, let blocks = root[1] as? [[Any]] {
            dictionaryEntries = blocks.compactMap { block -> String? in
                guard block.count >= 2,
                      let partOfSpeech = block[0] as? String,
                      let terms = block[1] as? [String],
                      !terms.isEmpty else { return nil }
                return "[\(partOfSpeech)] \(terms.prefix(5).joined(separator: "；"))"
            }
        }
        return GoogleTranslationResult(
            translation: output.trimmingCharacters(in: .whitespacesAndNewlines),
            dictionaryEntries: dictionaryEntries
        )
    }
}
