import AppKit
import Combine
import NaturalLanguage
import SQLite3
import os

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
    private struct TermStatisticsCacheKey: Hashable {
        let entryIDs: [Int64]
    }

    public static let shared = TranslationHistoryStore()

    @Published public private(set) var entries: [TranslationHistoryEntry] = []
    @Published public private(set) var ignoredWords: [String] = []
    @Published public private(set) var revision: UInt64 = 0

    private var database: OpaquePointer?
    let databaseURL: URL
    private var termStatisticsCache: [TermStatisticsCacheKey: [TranslationTermStatistic]] = [:]
    private var sourceLanguageCache: [String: String] = [:]
    private let shouldRecordSelection: () -> Bool
    private let shouldRecordScreenshot: () -> Bool
    private let now: () -> Date
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let historyLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "TranslationHistory"
    )

    private static var productionDatabaseURL: URL {
        if let testRoot = LocalTestDataPaths.rootDirectory {
            return testRoot
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("SnapLex", isDirectory: true)
                .appendingPathComponent("translation-history.sqlite3")
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLex", isDirectory: true)
        return directory.appendingPathComponent("translation-history.sqlite3")
    }

    private convenience init() {
        self.init(
            databaseURL: Self.productionDatabaseURL,
            shouldRecordSelection: { AppSettings.shared.recordSelectionTranslations },
            shouldRecordScreenshot: { AppSettings.shared.recordScreenshotTranslations },
            now: { Date() }
        )
    }

    /// Isolated storage and policy injection for deterministic tests. Production
    /// always uses the app-support database through the private convenience init.
    init(
        databaseURL: URL,
        shouldRecordSelection: @escaping () -> Bool,
        shouldRecordScreenshot: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() }
    ) {
        self.databaseURL = databaseURL
        self.shouldRecordSelection = shouldRecordSelection
        self.shouldRecordScreenshot = shouldRecordScreenshot
        self.now = now
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        sqlite3_open(databaseURL.path, &database)
        // Readers may scan a large range while new translations are recorded.
        // WAL lets those background reads coexist with the short write path.
        if sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil) != SQLITE_OK {
            historyLogger.error("translation history WAL setup failed sqliteCode=\(sqlite3_errcode(self.database), privacy: .public)")
        }
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
            guard shouldRecordSelection() else { return }
            sourceKind = "selection"
        case .screenshot:
            guard shouldRecordScreenshot() else { return }
            sourceKind = "screenshot"
        case .manual:
            return
        }

        let cleanInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranslation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanInput.isEmpty, !cleanTranslation.isEmpty else { return }
        let createdAt = now()
        let startedAt = DispatchTime.now().uptimeNanoseconds

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
        sqlite3_bind_double(statement, 7, createdAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            historyLogger.error("translation history insert failed sqliteCode=\(sqlite3_errcode(self.database), privacy: .public)")
            return
        }

        let entry = TranslationHistoryEntry(
            id: sqlite3_last_insert_rowid(database),
            inputText: cleanInput,
            translatedText: cleanTranslation,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sourceApp: sourceApp,
            sourceKind: sourceKind,
            createdAt: createdAt
        )
        let insertionIndex = entries.firstIndex { existing in
            existing.createdAt < entry.createdAt
                || (existing.createdAt == entry.createdAt && existing.id < entry.id)
        } ?? entries.endIndex
        entries.insert(entry, at: insertionIndex)
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        termStatisticsCache.removeAll(keepingCapacity: true)
        revision &+= 1
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        historyLogger.debug("translation history inserted id=\(entry.id, privacy: .public) source=\(sourceKind, privacy: .public) totalEntries=\(self.entries.count, privacy: .public) milliseconds=\(elapsedMilliseconds, privacy: .public)")
    }

    public func reload() {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard let database else { return }
        termStatisticsCache.removeAll(keepingCapacity: true)
        var loadedEntries: [TranslationHistoryEntry] = []
        let sql = """
        SELECT id, input_text, translated_text, source_language, target_language,
               source_app, source_kind, created_at
        FROM translation_history
        ORDER BY created_at DESC, id DESC LIMIT 50;
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
        revision &+= 1
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        historyLogger.info("translation history reloaded entries=\(loadedEntries.count, privacy: .public) ignoredTerms=\(loadedIgnored.count, privacy: .public) milliseconds=\(elapsedMilliseconds, privacy: .public)")
    }

    public func addIgnoredWord(_ word: String) {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWord = Self.normalized(cleanWord)
        guard !normalizedWord.isEmpty,
              !ignoredWords.contains(where: { Self.normalized($0) == normalizedWord }) else { return }
        var statement: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO ignored_translation_terms (term) VALUES (?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, cleanWord, -1, transient)
        let result = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE, sqlite3_changes(database) > 0 else { return }
        ignoredWords.append(cleanWord)
        ignoredWords.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        termStatisticsCache.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    public func removeIgnoredWord(_ word: String) {
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWord = Self.normalized(cleanWord)
        guard !normalizedWord.isEmpty,
              let storedWord = ignoredWords.first(where: { Self.normalized($0) == normalizedWord }) else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM ignored_translation_terms WHERE term = ? COLLATE NOCASE;", -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, storedWord, -1, transient)
        let result = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE, sqlite3_changes(database) > 0 else { return }
        ignoredWords.removeAll { Self.normalized($0) == normalizedWord }
        termStatisticsCache.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    public func deleteEntry(id: Int64) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM translation_history WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, id)
        let result = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE, sqlite3_changes(database) > 0 else { return }
        reload()
    }

    public func deleteAllEntries() {
        guard sqlite3_exec(database, "DELETE FROM translation_history;", nil, nil, nil) == SQLITE_OK else {
            historyLogger.error("translation history clear failed sqliteCode=\(sqlite3_errcode(self.database), privacy: .public)")
            return
        }
        entries = []
        termStatisticsCache.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    public func termStatistics(for entries: [TranslationHistoryEntry]) -> [TranslationTermStatistic] {
        let cacheKey = TermStatisticsCacheKey(entryIDs: entries.map(\.id))
        if let cached = termStatisticsCache[cacheKey] {
            historyLogger.debug("translation term statistics cache=hit entries=\(entries.count, privacy: .public) terms=\(cached.count, privacy: .public)")
            return cached
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
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

        var computed: [TranslationTermStatistic] = []
        computed.reserveCapacity(stats.count)
        for (key, value) in stats {
            computed.append(TranslationTermStatistic(
                id: key,
                term: value.term,
                count: value.count,
                latestDate: value.latest,
                latestTranslation: value.translation
            ))
        }
        computed.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.latestDate > rhs.latestDate : lhs.count > rhs.count
        }
        if termStatisticsCache.count >= 8 {
            termStatisticsCache.removeAll(keepingCapacity: true)
        }
        termStatisticsCache[cacheKey] = computed
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        historyLogger.debug("translation term statistics cache=miss entries=\(entries.count, privacy: .public) terms=\(computed.count, privacy: .public) milliseconds=\(elapsedMilliseconds, privacy: .public)")
        return computed
    }

    /// Use the non-Chinese side as the vocabulary being learned. For example,
    /// Chinese → English records contribute English words to word-frequency
    /// statistics, while keeping the Chinese original available as context.
    public func learningText(for entry: TranslationHistoryEntry) -> String {
        let input = entry.inputText
        let sourceLanguage: String
        if let cached = sourceLanguageCache[input] {
            sourceLanguage = cached
        } else {
            sourceLanguage = NativeTranslationSupport.sourceLanguageCode(for: input)
            // Bound both the number and size of retained inputs.
            if input.utf8.count <= 2_000 {
                if sourceLanguageCache.count >= 1_024 { sourceLanguageCache.removeAll(keepingCapacity: true) }
                sourceLanguageCache[input] = sourceLanguage
            }
        }
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

    nonisolated static func normalized(_ term: String) -> String {
        term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func words(in text: String) -> [String] {
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
