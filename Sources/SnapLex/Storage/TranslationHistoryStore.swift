import AppKit
import Combine
import NaturalLanguage
import SQLite3
import os

public struct TranslationHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let inputText: String
    public let translatedText: String
    public let sourceLanguage: String
    public let targetLanguage: String
    public let sourceApp: String
    public let sourceKind: String
    public let createdAt: Date
}

public struct TranslationTermStatistic: Identifiable, Sendable {
    public let id: String
    public let term: String
    public let count: Int
    public let latestDate: Date
    public let latestTranslation: String
}

/// One writer per file. The connection, migrations and mutable snapshot belong
/// exclusively to this queue; neither SQLite nor file-system work runs on MainActor.
final class TranslationHistoryExecutor: @unchecked Sendable {
    struct Snapshot: Sendable {
        var entries: [TranslationHistoryEntry] = []
        var ignoredWords: [String] = []
        var revision: UInt64 = 0
        var recordsRevision: UInt64 = 0
        var learningTranslation: [Int64: Bool] = [:]
    }

    private final class WeakExecutor {
        weak var value: TranslationHistoryExecutor?
        init(_ value: TranslationHistoryExecutor) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var registry: [String: WeakExecutor] = [:]

    static func shared(for url: URL) -> TranslationHistoryExecutor {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = url.standardizedFileURL.path
        if let existing = registry[key]?.value { return existing }
        registry = registry.filter { $0.value.value != nil }
        let executor = TranslationHistoryExecutor(url: url)
        registry[key] = WeakExecutor(executor)
        return executor
    }

    static func pendingWrites(for url: URL) async {
        let executor = registeredExecutor(for: url)
        if let executor { _ = await executor.snapshot() }
    }

    private static func registeredExecutor(for url: URL) -> TranslationHistoryExecutor? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return registry[url.standardizedFileURL.path]?.value
    }

    private let queue = DispatchQueue(label: "SnapLex.TranslationHistory.writer", qos: .utility)
    private let url: URL
    private var database: OpaquePointer?
    private var state = Snapshot()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SnapLex", category: "TranslationHistory")

    private init(url: URL) {
        self.url = url
        queue.async { self.open() }
    }

    deinit { sqlite3_close(database) }

    func enqueue(_ operation: @escaping @Sendable (TranslationHistoryExecutor) -> Void, completion: @escaping @Sendable (Snapshot) -> Void) {
        queue.async {
            operation(self)
            completion(self.state)
        }
    }

    func snapshot() async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.state) }
        }
    }

    private func open() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                logger.error("translation history open failed")
                return
            }
            sqlite3_busy_timeout(database, 2_000)
            guard execute("PRAGMA journal_mode=WAL;") else { return }
            // Additive migration also upgrades existing databases. The explicit
            // id direction avoids sorting ties and supports tuple cursor seeks.
            guard execute("""
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
                CREATE INDEX IF NOT EXISTS idx_translation_history_created_at_id
                    ON translation_history(created_at DESC, id DESC);
                DROP INDEX IF EXISTS idx_translation_history_created_at;
                CREATE TABLE IF NOT EXISTS ignored_translation_terms (term TEXT PRIMARY KEY COLLATE NOCASE);
                """) else { return }
            reload()
        } catch {
            logger.error("translation history directory setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result != SQLITE_OK {
            logger.error("translation history operation failed sqliteCode=\(result, privacy: .public)")
        }
        return result == SQLITE_OK
    }

    private func statement(_ sql: String, _ body: (OpaquePointer) -> Bool) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logger.error("translation history prepare failed")
            return false
        }
        defer { sqlite3_finalize(statement) }
        return body(statement)
    }

    func insert(_ entry: TranslationHistoryEntry) {
        let inserted = statement("""
            INSERT INTO translation_history (input_text, translated_text, source_language,
                target_language, source_app, source_kind, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);
            """) { statement in
            for (offset, value) in [entry.inputText, entry.translatedText, entry.sourceLanguage, entry.targetLanguage, entry.sourceApp, entry.sourceKind].enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
            }
            sqlite3_bind_double(statement, 7, entry.createdAt.timeIntervalSince1970)
            return sqlite3_step(statement) == SQLITE_DONE
        }
        guard inserted else { return }
        let saved = TranslationHistoryEntry(id: sqlite3_last_insert_rowid(database), inputText: entry.inputText, translatedText: entry.translatedText, sourceLanguage: entry.sourceLanguage, targetLanguage: entry.targetLanguage, sourceApp: entry.sourceApp, sourceKind: entry.sourceKind, createdAt: entry.createdAt)
        let index = state.entries.firstIndex {
            $0.createdAt < saved.createdAt || ($0.createdAt == saved.createdAt && $0.id < saved.id)
        } ?? state.entries.endIndex
        state.entries.insert(saved, at: index)
        state.entries = Array(state.entries.prefix(50))
        updateLearningSides()
        state.recordsRevision &+= 1
        state.revision &+= 1
    }

    func reload() {
        guard loadEntries() else { return }
        var ignored: [String] = []
        guard statement("SELECT term FROM ignored_translation_terms ORDER BY term COLLATE NOCASE;", { statement in
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return true }
                guard status == SQLITE_ROW else { return false }
                ignored.append(Self.string(statement, 0))
            }
        }) else { return }
        state.ignoredWords = ignored
        state.recordsRevision &+= 1
        state.revision &+= 1
    }

    private func loadEntries() -> Bool {
        var entries: [TranslationHistoryEntry] = []
        guard statement("""
            SELECT id, input_text, translated_text, source_language, target_language,
                source_app, source_kind, created_at FROM translation_history
            ORDER BY created_at DESC, id DESC LIMIT 50;
            """, { statement in
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return true }
                guard status == SQLITE_ROW else { return false }
                entries.append(TranslationHistoryEntry(id: sqlite3_column_int64(statement, 0), inputText: Self.string(statement, 1), translatedText: Self.string(statement, 2), sourceLanguage: Self.string(statement, 3), targetLanguage: Self.string(statement, 4), sourceApp: Self.string(statement, 5), sourceKind: Self.string(statement, 6), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))))
            }
        }) else { return false }
        state.entries = entries
        updateLearningSides()
        return true
    }

    private func updateLearningSides() {
        state.learningTranslation = Dictionary(uniqueKeysWithValues: state.entries.map {
            ($0.id, TranslationHistoryAnalysisCache.shared.learnsTranslation(for: $0, databaseURL: url))
        })
    }

    func addIgnoredWord(_ word: String) {
        let normalized = TranslationHistoryStore.normalized(word)
        guard !state.ignoredWords.contains(where: { TranslationHistoryStore.normalized($0) == normalized }) else { return }
        guard statement("INSERT OR IGNORE INTO ignored_translation_terms (term) VALUES (?);", { statement in
            sqlite3_bind_text(statement, 1, word, -1, transient)
            return sqlite3_step(statement) == SQLITE_DONE
        }), sqlite3_changes(database) > 0 else { return }
        state.ignoredWords.append(word)
        state.ignoredWords.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        state.revision &+= 1
    }

    func removeIgnoredWord(_ word: String) {
        let normalized = TranslationHistoryStore.normalized(word)
        guard let stored = state.ignoredWords.first(where: { TranslationHistoryStore.normalized($0) == normalized }) else { return }
        guard statement("DELETE FROM ignored_translation_terms WHERE term = ? COLLATE NOCASE;", { statement in
            sqlite3_bind_text(statement, 1, stored, -1, transient)
            return sqlite3_step(statement) == SQLITE_DONE
        }), sqlite3_changes(database) > 0 else { return }
        state.ignoredWords.removeAll { TranslationHistoryStore.normalized($0) == normalized }
        state.revision &+= 1
    }

    func deleteEntry(id: Int64) {
        guard statement("DELETE FROM translation_history WHERE id = ?;", { statement in
            sqlite3_bind_int64(statement, 1, id)
            return sqlite3_step(statement) == SQLITE_DONE
        }), sqlite3_changes(database) > 0 else { return }
        _ = loadEntries()
        state.recordsRevision &+= 1
        state.revision &+= 1
        TranslationHistoryAnalysisCache.shared.remove(databaseURL: url, id: id)
    }

    func deleteAllEntries() {
        guard execute("DELETE FROM translation_history;") else { return }
        state.entries = []
        state.learningTranslation = [:]
        state.recordsRevision &+= 1
        state.revision &+= 1
        TranslationHistoryAnalysisCache.shared.remove(databaseURL: url)
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}

@MainActor
public final class TranslationHistoryStore: ObservableObject {
    public static let shared = TranslationHistoryStore()

    @Published public private(set) var entries: [TranslationHistoryEntry] = []
    @Published public private(set) var ignoredWords: [String] = []
    @Published public private(set) var revision: UInt64 = 0
    @Published public private(set) var recordsRevision: UInt64 = 0

    let databaseURL: URL
    private let executor: TranslationHistoryExecutor
    private var learningTranslation: [Int64: Bool] = [:]
    private var acceptsMutations = true
    private let shouldRecordSelection: () -> Bool
    private let shouldRecordScreenshot: () -> Bool
    private let now: () -> Date

    private static var productionDatabaseURL: URL {
        if let testRoot = LocalTestDataPaths.rootDirectory {
            return testRoot.appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("SnapLex", isDirectory: true)
                .appendingPathComponent("translation-history.sqlite3")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLex", isDirectory: true)
            .appendingPathComponent("translation-history.sqlite3")
    }

    private convenience init() {
        self.init(databaseURL: Self.productionDatabaseURL,
                  shouldRecordSelection: { AppSettings.shared.recordSelectionTranslations },
                  shouldRecordScreenshot: { AppSettings.shared.recordScreenshotTranslations })
    }

    /// Initialization and mutations enqueue work. Await waitForPendingWrites()
    /// when subsequent code needs committed entries/IDs or the published revision.
    init(databaseURL: URL, shouldRecordSelection: @escaping () -> Bool,
         shouldRecordScreenshot: @escaping () -> Bool, now: @escaping () -> Date = { Date() }) {
        self.databaseURL = databaseURL
        self.executor = TranslationHistoryExecutor.shared(for: databaseURL)
        self.shouldRecordSelection = shouldRecordSelection
        self.shouldRecordScreenshot = shouldRecordScreenshot
        self.now = now
        submit { _ in }
    }

    private func submit(_ operation: @escaping @Sendable (TranslationHistoryExecutor) -> Void) {
        guard acceptsMutations else { return }
        executor.enqueue(operation) { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: TranslationHistoryExecutor.Snapshot) {
        guard snapshot.revision > revision else { return }
        learningTranslation = snapshot.learningTranslation
        if entries != snapshot.entries { entries = snapshot.entries }
        if ignoredWords != snapshot.ignoredWords { ignoredWords = snapshot.ignoredWords }
        if recordsRevision != snapshot.recordsRevision { recordsRevision = snapshot.recordsRevision }
        revision = snapshot.revision
    }

    /// FIFO barrier includes initialization and all previously enqueued writes,
    /// then publishes their snapshot on MainActor before returning. Never blocks it.
    public func waitForPendingWrites() async {
        apply(await executor.snapshot())
    }

    func finishPendingWritesForTermination() async {
        acceptsMutations = false
        await waitForPendingWrites()
    }

    public func recordCompletedTranslation(inputText: String, translatedText: String,
        sourceLanguage: String, targetLanguage: String, sourceApp: String, trigger: TranslationTriggerSource) {
        let sourceKind: String
        switch trigger {
        case .mouseSelect, .selection, .doubleCopy:
            guard shouldRecordSelection() else { return }
            sourceKind = "selection"
        case .screenshot:
            guard shouldRecordScreenshot() else { return }
            sourceKind = "screenshot"
        case .manual: return
        }
        let input = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !translation.isEmpty else { return }
        let entry = TranslationHistoryEntry(id: 0, inputText: input, translatedText: translation, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, sourceApp: sourceApp, sourceKind: sourceKind, createdAt: now())
        submit { $0.insert(entry) }
    }

    public func reload() { submit { $0.reload() } }

    public func addIgnoredWord(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.normalized(word).isEmpty else { return }
        submit { $0.addIgnoredWord(word) }
    }

    public func removeIgnoredWord(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.normalized(word).isEmpty else { return }
        submit { $0.removeIgnoredWord(word) }
    }

    public func deleteEntry(id: Int64) { submit { $0.deleteEntry(id: id) } }
    public func deleteAllEntries() { submit { $0.deleteAllEntries() } }

    /// Compatibility API; UI consumers use background query summaries instead.
    public func termStatistics(for entries: [TranslationHistoryEntry]) -> [TranslationTermStatistic] {
        TranslationHistoryAnalysisCache.statistics(for: entries, databaseURL: databaseURL, ignoredWords: ignoredWords)
    }

    public func learningText(for entry: TranslationHistoryEntry) -> String {
        let learnsTranslation = learningTranslation[entry.id]
            ?? TranslationHistoryAnalysisCache.shared.learnsTranslation(for: entry, databaseURL: databaseURL)
        return learnsTranslation ? entry.translatedText : entry.inputText
    }

    public func contextText(for entry: TranslationHistoryEntry) -> String {
        learningText(for: entry) == entry.inputText ? entry.translatedText : entry.inputText
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
            if word.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { words.append(word) }
            return true
        }
        return words
    }
}
