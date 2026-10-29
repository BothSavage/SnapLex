import Foundation
import CoreServices
import AVFoundation

public struct SystemDictResult: Sendable {
    public let term: String
    public let phonetic: String
    public let formattedDefinition: String
}

public final class SystemDictionaryService: @unchecked Sendable {
    public static let shared = SystemDictionaryService()
    @MainActor private lazy var synthesizer = AVSpeechSynthesizer()
    private let lookupQueue = DispatchQueue(label: "io.github.snaplex.dictionary", qos: .userInitiated)
    private struct CacheEntry {
        let result: SystemDictResult?
        let cost: Int
    }
    // Positive and negative results share strict count/byte bounds. Access is
    // confined to lookupQueue; dictionary IPC and formatting never run on main.
    private var cache: [String: CacheEntry] = [:]
    private var recency: [String] = []
    private var cacheBytes = 0

    private init() {}

    /// Compatibility API for synchronous callers. Interactive translation uses
    /// lookupAsync so cold DictionaryServices startup cannot delay the card.
    public func lookup(_ rawText: String) -> SystemDictResult? {
        lookupQueue.sync { cachedLookup(rawText) }
    }

    public func lookupAsync(_ rawText: String) async -> SystemDictResult? {
        let gate = SelectionMouseGestureGenerationGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lookupQueue.async {
                    guard gate.isCurrent(0) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: self.cachedLookup(rawText))
                }
            }
        } onCancel: {
            gate.update(to: 1)
        }
    }

    private func cachedLookup(_ rawText: String) -> SystemDictResult? {
        let term = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 80 else { return nil }
        let key = L10n.language + "\0" + term
        if let entry = cache[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return entry.result
        }
        let result = uncachedLookup(term)
        let cost = key.utf8.count + (result?.formattedDefinition.utf8.count ?? 0)
            + (result?.phonetic.utf8.count ?? 0)
        let maximumBytes = 512 * 1024
        if cost <= maximumBytes {
            while recency.count >= 128 || cacheBytes + cost > maximumBytes {
                let oldest = recency.removeFirst()
                cacheBytes -= cache.removeValue(forKey: oldest)?.cost ?? 0
            }
            cache[key] = CacheEntry(result: result, cost: cost)
            recency.append(key)
            cacheBytes += cost
        }
        return result
    }

    private func uncachedLookup(_ rawText: String) -> SystemDictResult? {
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
    @MainActor public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let englishVoice = AVSpeechSynthesisVoice(language: "en-US") else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = englishVoice
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
