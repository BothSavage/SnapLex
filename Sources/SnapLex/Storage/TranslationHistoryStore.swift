import AppKit
import Combine
import NaturalLanguage
import SQLite3

public struct TranslationHistoryEntry: Identifiable, Equatable {
    public let id: Int64
    public let inputText: String
    public let translatedText: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let sourceApp: String
    public let sourceKind: String
    public let createdAt: Date
}

public struct TranslationTermStatistic: Identifiable {
    public let id: String
    public let term: String
    public let count: Int
    public let latestDate: Date
    public let latestTranslation: String
}

@MainActor
public final class TranslationHistoryStore: ObservableObject {
    public static let shared = TranslationHistoryStore()

    @Published public private(set) var entries: [TranslationHistoryEntry] = []
    @Published public private(set) var ignoredWords: [String] = []

    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var databaseURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLex", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("translation-history.sqlite3")
    }

    private init() {
        sqlite3_open(databaseURL.path, &database)
        createTables()
        reload()
    }

    deinit {
        sqlite3_close(database)
    }

    public func recordCompletedTranslation(
        inputText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String,
        sourceApp: String,
        trigger: TranslationTriggerSource
    ) {
        let sourceKind: String
        switch trigger {
        case .mouseSelect, .selection, .doubleCopy:
            guard AppSettings.shared.recordSelectionTranslations else { return }
            sourceKind = "selection"
        case .screenshot:
            guard AppSettings.shared.recordScreenshotTranslations else { return }
            sourceKind = "screenshot"
        case .manual:
            return
        }

        let cleanInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInput.isEmpty, !cleanTranslation.isEmpty else { return }

        let sql = """
        INSERT INTO translation_history (
            input_text, translated_text, source_language, target_language,
            source_app, source_kind, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, cleanInput, -1, transient)
        sqlite3_bind_text(statement, 2, cleanTranslation, -1, transient)
        sqlite3_bind_text(statement, 3, sourceLanguage, -1, transient)
        sqlite3_bind_text(statement, 4, targetLanguage, -1, transient)
        sqlite3_bind_text(statement, 5, sourceApp, -1, transient)
        sqlite3_bind_text(statement, 6, sourceKind, -1, transient)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        reload()
    }

    public func reload() {
        guard let database else { return }
        var loadedEntries: [TranslationHistoryEntry] = []
        let sql = """
        SELECT id, input_text, translated_text, source_language, target_language,
               source_app, source_kind, created_at
        FROM translation_history
        ORDER BY created_at DESC, id DESC;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                loadedEntries.append(
                    TranslationHistoryEntry(
                        id: sqlite3_column_int64(statement, 0),
                        inputText: columnString(statement, 1),
                        translatedText: columnString(statement, 2),
                        sourceLanguage: columnString(statement, 3),
                        targetLanguage: columnString(statement, 4),
                        sourceApp: columnString(statement, 5),
                        sourceKind: columnString(statement, 6),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        entries = loadedEntries

        var loadedIgnored: [String] = []
        if sqlite3_prepare_v2(database, "SELECT term FROM ignored_translation_terms ORDER BY term COLLATE NOCASE;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                loadedIgnored.append(columnString(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        ignoredWords = loadedIgnored
    }

    public func addIgnoredWord(_ word: String) {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWord.isEmpty else { return }
        var statement: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO ignored_translation_terms (term) VALUES (?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, cleanWord, -1, transient)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        reload()
    }

    public func removeIgnoredWord(_ word: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM ignored_translation_terms WHERE term = ? COLLATE NOCASE;", -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, word, -1, transient)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        reload()
    }

    public func deleteEntry(id: Int64) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM translation_history WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
        reload()
    }

    public func deleteAllEntries() {
        sqlite3_exec(database, "DELETE FROM translation_history;", nil, nil, nil)
        reload()
    }

    public func termStatistics(for entries: [TranslationHistoryEntry]) -> [TranslationTermStatistic] {
        let ignored = Set(ignoredWords.map(Self.normalized))
        var stats: [String: (term: String, count: Int, latest: Date, translation: String)] = [:]

        for entry in entries {
            var termsForEntry = Set<String>()
            for term in Self.words(in: learningText(for: entry)) {
                let key = Self.normalized(term)
                guard !key.isEmpty, !ignored.contains(key) else { continue }
                termsForEntry.insert(key)
                if stats[key] == nil {
                    stats[key] = (term, 0, entry.createdAt, entry.translatedText)
                }
            }
            for key in termsForEntry {
                guard var current = stats[key] else { continue }
                current.count += 1
                if entry.createdAt > current.latest {
                    current.latest = entry.createdAt
                    current.translation = entry.translatedText
                }
                stats[key] = current
            }
        }

        return stats.map { key, value in
            TranslationTermStatistic(
                id: key,
                term: value.term,
                count: value.count,
                latestDate: value.latest,
                latestTranslation: value.translation
            )
        }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.latestDate > rhs.latestDate : lhs.count > rhs.count
        }
    }

    /// Use the non-Chinese side as the vocabulary being learned. For example,
    /// Chinese → English records contribute English words to word-frequency
    /// statistics, while keeping the Chinese original available as context.
    public func learningText(for entry: TranslationHistoryEntry) -> String {
        let sourceLanguage = NativeTranslationSupport.sourceLanguageCode(for: entry.inputText)
        return sourceLanguage == "zh" || sourceLanguage == "zh-TW"
            ? entry.translatedText
            : entry.inputText
    }

    public func contextText(for entry: TranslationHistoryEntry) -> String {
        let learnedText = learningText(for: entry)
        return learnedText == entry.inputText ? entry.translatedText : entry.inputText
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS translation_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            input_text TEXT NOT NULL,
            translated_text TEXT NOT NULL,
            source_language TEXT NOT NULL DEFAULT '',
            target_language TEXT NOT NULL DEFAULT '',
            source_app TEXT NOT NULL DEFAULT '',
            source_kind TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_translation_history_created_at ON translation_history(created_at DESC);
        CREATE TABLE IF NOT EXISTS ignored_translation_terms (
            term TEXT PRIMARY KEY COLLATE NOCASE
        );
        """
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private static func normalized(_ term: String) -> String {
        term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                words.append(word)
            }
            return true
        }
        return words
    }
}
