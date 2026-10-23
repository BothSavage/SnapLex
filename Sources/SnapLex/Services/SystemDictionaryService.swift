import Foundation
import CoreServices
import AVFoundation

public struct SystemDictResult {
    public let term: String
    public let phonetic: String
    public let formattedDefinition: String
}

public final class SystemDictionaryService {
    public static let shared = SystemDictionaryService()
    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    /// Instant (<2ms) offline lookup using macOS CoreServices DictionaryServices
    public func lookup(_ rawText: String) -> SystemDictResult? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }

        let nsString = trimmed as NSString
        let range = CFRangeMake(0, nsString.length)
        guard let rawDef = DCSCopyTextDefinition(nil, nsString, range)?.takeRetainedValue() as String? else {
            return nil
        }

        let phonetic = extractPhonetic(from: rawDef)
        let cleaned = formatRawDefinition(rawDef)
        return SystemDictResult(term: trimmed, phonetic: phonetic, formattedDefinition: cleaned)
    }

    /// Speak text using macOS native AVSpeechSynthesizer
    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        let hasChinese = trimmed.range(of: "\\p{Han}", options: .regularExpression) != nil
        utterance.voice = AVSpeechSynthesisVoice(language: hasChinese ? "zh-CN" : "en-US")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    private func extractPhonetic(from raw: String) -> String {
        // macOS dictionary usually formats phonetics as | ˈwɔːp | or /.../
        let patterns = [
            "\\|[^|]{1,40}\\|",
            "/[^/\n]{2,40}/",
            "\\[[^\\]\n]{2,40}\\]"
        ]
        for pattern in patterns {
            if let range = raw.range(of: pattern, options: .regularExpression) {
                return String(raw[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func formatRawDefinition(_ raw: String) -> String {
        var text = raw
        // Insert line breaks before numbered senses or bullet markers for readability
        let replacements: [(String, String)] = [
            ("• ", "\n• "),
            (" ▶ ", "\n▶ "),
            ("ORIGIN ", "\n\n【词源】"),
            ("PHRASES ", "\n\n【短语】"),
            ("DERIVATIVES ", "\n\n【派生】")
        ]
        for (target, replacement) in replacements {
            text = text.replacingOccurrences(of: target, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
