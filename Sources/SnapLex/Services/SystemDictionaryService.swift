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
        let cleaned = Self.formatRawDefinition(rawDef)
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

    static func formatRawDefinition(_ raw: String) -> String {
        var text = raw
        // Keep dictionary senses as separate rows even when DictionaryServices returns
        // the whole article as one paragraph.
        let replacements: [(String, String)] = [
            ("• ", "\n• "),
            ("▪ ", "\n▪ "),
            (" ▶ ", "\n▶ "),
            ("ORIGIN ", "\n\n\(L10n.string("词源"))\n"),
            ("PHRASES ", "\n\n\(L10n.string("短语"))\n"),
            ("DERIVATIVES ", "\n\n\(L10n.string("派生"))\n")
        ]
        for (target, replacement) in replacements {
            text = text.replacingOccurrences(of: target, with: replacement)
        }
        for marker in ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳"] {
            text = text.replacingOccurrences(of: marker, with: "\n\(marker)")
        }
        for marker in ["1.", "2.", "3.", "4.", "5.", "6.", "7.", "8.", "9."] {
            text = text.replacingOccurrences(of: " \(marker) ", with: "\n\(marker) ")
        }
        text = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
