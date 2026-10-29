import Foundation
import SQLite3

struct TranslationHistoryRange: Hashable, Sendable {
    let start: Date
    let end: Date
    let search: String
}

struct TranslationHistorySummary: Sendable {
    var count = 0
    var dailyCounts: [Date: Int] = [:]
    var terms: [TranslationTermStatistic] = []
    // Independent of the retained term rows: the history UI displays the full
    // distinct count even when only its top 100 vocabulary rows are requested.
    var distinctTermCount = 0
}

struct TranslationHistoryPage: Sendable {
    let entries: [TranslationHistoryEntry]
    let hasMore: Bool
    var learningTranslation: [Int64: Bool] = [:]
}

/// Immutable entries share bounded language/token results across overlapping
/// windows, screens and ignored-word revisions. Keys never retain original text.
final class TranslationHistoryAnalysisCache: @unchecked Sendable {
    static let shared = TranslationHistoryAnalysisCache()
    private struct Key: Hashable {
        let database: String
        let id: Int64
    }
    private struct Analysis {
        let fingerprint: Int
        let learnsTranslation: Bool
        var terms: [(key: String, term: String)]?
        var cost: Int
        var access: UInt64
    }
    private let lock = NSLock()
    private var values: [Key: Analysis] = [:]
    private var clock: UInt64 = 0
    private var cost = 0
    private let maximumCost = 8 * 1_024 * 1_024
    private let maximumEntries = 4_096

    private func analysis(for entry: TranslationHistoryEntry, databaseURL: URL, includeTerms: Bool) -> Analysis {
        let key = Key(database: databaseURL.standardizedFileURL.path, id: entry.id)
        var hasher = Hasher()
        hasher.combine(entry.inputText)
        hasher.combine(entry.translatedText)
        let fingerprint = hasher.finalize()
        lock.lock()
        clock &+= 1
        if var cached = values[key], cached.fingerprint == fingerprint,
           !includeTerms || cached.terms != nil {
            cached.access = clock
            values[key] = cached
            lock.unlock()
            return cached
        }
        let existing = values[key].flatMap { $0.fingerprint == fingerprint ? $0 : nil }
        lock.unlock()
        // Expensive NLP always happens outside the lock, on the requesting
        // background worker. Concurrent requests may duplicate one cold entry.
        let learnsTranslation: Bool
        if let existing {
            learnsTranslation = existing.learnsTranslation
        } else {
            let source = NativeTranslationSupport.sourceLanguageCode(for: entry.inputText)
            learnsTranslation = source == "zh" || source == "zh-TW"
        }
        var terms: [(key: String, term: String)]? = existing?.terms
        if includeTerms && terms == nil {
            var seen = Set<String>()
            terms = TranslationHistoryStore.words(in: learnsTranslation ? entry.translatedText : entry.inputText).compactMap { term in
                let normalized = TranslationHistoryStore.normalized(term)
                guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
                return (normalized, term)
            }
        }
        let termCost = terms?.reduce(0) { $0 + $1.key.utf8.count + $1.term.utf8.count + 64 } ?? 0
        lock.lock()
        defer { lock.unlock() }
        clock &+= 1
        let result = Analysis(fingerprint: fingerprint, learnsTranslation: learnsTranslation, terms: terms, cost: termCost + 128, access: clock)
        // Retain the tiny language decision even when a single record's
        // vocabulary exceeds the entire token budget.
        var retained = result
        if retained.cost > maximumCost {
            retained.terms = nil
            retained.cost = 128
        }
        cost -= values[key]?.cost ?? 0
        values[key] = retained
        cost += retained.cost
        if values.count > maximumEntries || cost > maximumCost {
            for (oldKey, oldValue) in values.sorted(by: { $0.value.access < $1.value.access }) {
                guard values.count > maximumEntries * 3 / 4 || cost > maximumCost * 3 / 4 else { break }
                cost -= oldValue.cost
                values.removeValue(forKey: oldKey)
            }
        }
        return result
    }

    func learnsTranslation(for entry: TranslationHistoryEntry, databaseURL: URL) -> Bool {
        analysis(for: entry, databaseURL: databaseURL, includeTerms: false).learnsTranslation
    }

    func terms(for entry: TranslationHistoryEntry, databaseURL: URL) -> [(key: String, term: String)] {
        analysis(for: entry, databaseURL: databaseURL, includeTerms: true).terms ?? []
    }

    func remove(databaseURL: URL, id: Int64? = nil) {
        let path = databaseURL.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        let keys = values.keys.filter { $0.database == path && (id == nil || $0.id == id) }
        for key in keys { cost -= values.removeValue(forKey: key)?.cost ?? 0 }
    }

    static func statistics(for entries: [TranslationHistoryEntry], databaseURL: URL, ignoredWords: [String]) -> [TranslationTermStatistic] {
        let ignored = Set(ignoredWords.map(TranslationHistoryStore.normalized))
        var statistics: [String: TranslationTermStatistic] = [:]
        for entry in entries {
            accumulate(entry, terms: shared.terms(for: entry, databaseURL: databaseURL), ignored: ignored, into: &statistics)
        }
        return sorted(statistics)
    }

    static func accumulate(_ entry: TranslationHistoryEntry, terms: [(key: String, term: String)], ignored: Set<String>, into statistics: inout [String: TranslationTermStatistic]) {
        for (key, term) in terms where !ignored.contains(key) {
            let current = statistics[key]
            let isLatest = current == nil || entry.createdAt > current!.latestDate
            statistics[key] = TranslationTermStatistic(id: key, term: current?.term ?? term,
                count: (current?.count ?? 0) + 1,
                latestDate: isLatest ? entry.createdAt : current!.latestDate,
                latestTranslation: isLatest ? entry.translatedText : current!.latestTranslation)
        }
    }

    static func sorted(_ statistics: [String: TranslationTermStatistic]) -> [TranslationTermStatistic] {
        statistics.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.latestDate != rhs.latestDate { return lhs.latestDate > rhs.latestDate }
            return lhs.id < rhs.id
        }
    }
}

/// Read-only connections keep long scans and tokenization off the UI thread.
/// Each connection owns a progress handler for its detached task's lifetime.
enum TranslationHistoryQuery {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "id, input_text, translated_text, source_language, target_language, source_app, source_kind, created_at"
    private static func filter(for range: TranslationHistoryRange) -> String {
        let dates = "created_at >= ? AND created_at <= ?"
        guard !range.search.isEmpty else { return dates }
        return dates + " AND (snaplex_contains(input_text, ?) OR snaplex_contains(translated_text, ?) OR snaplex_contains(source_app, ?))"
    }

    private struct SummaryKey: Hashable {
        let database: String
        let range: TranslationHistoryRange
        let revision: UInt64
        let ignored: [String]
        let calendar: Calendar
        let includeTerms: Bool
        let termLimit: Int?
    }
    private final class SummaryCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [SummaryKey: TranslationHistorySummary] = [:]
        var revisions: [String: UInt64] = [:]

        func cached(_ key: SummaryKey) -> TranslationHistorySummary? {
            lock.lock()
            defer { lock.unlock() }
            if revisions[key.database] != key.revision {
                values = values.filter { $0.key.database != key.database }
                revisions[key.database] = key.revision
            }
            return values[key]
        }

        func insert(_ value: TranslationHistorySummary, for key: SummaryKey) {
            lock.lock()
            defer { lock.unlock() }
            // An older cancelled read cannot restore a superseded revision.
            guard revisions[key.database] == key.revision else { return }
            if values.count >= 16 { values.removeAll(keepingCapacity: true) }
            values[key] = value
            if revisions.count > 16 { revisions = [key.database: key.revision] }
        }
    }
    private static let summaryCache = SummaryCache()

    static func summary(databaseURL: URL, range: TranslationHistoryRange, ignoredWords: [String], calendar: Calendar, includeTerms: Bool = true, termLimit: Int? = nil, revision: UInt64? = nil) async throws -> TranslationHistorySummary {
        await TranslationHistoryExecutor.pendingWrites(for: databaseURL)
        try Task.checkCancellation()
        let key = revision.map { SummaryKey(database: databaseURL.standardizedFileURL.path, range: range, revision: $0, ignored: includeTerms ? ignoredWords.map(TranslationHistoryStore.normalized).sorted() : [], calendar: calendar, includeTerms: includeTerms, termLimit: termLimit) }
        if let key, let cached = summaryCache.cached(key) { return cached }
        let result = try await background {
            try withDatabase(databaseURL) { db in
                let selected = includeTerms ? columns : "created_at"
                // Count/date-only scans can use the covering date/id index.
                let sql = "SELECT \(selected) FROM translation_history WHERE \(filter(for: range)) ORDER BY created_at DESC, id DESC"
                return try withStatement(db, sql) { statement in
                    bind(range, to: statement)
                    let ignored = Set(ignoredWords.map(TranslationHistoryStore.normalized))
                    var statistics: [String: TranslationTermStatistic] = [:]
                    // Repeated text can occur in many distinct records. Keep a
                    // small per-scan content cache in addition to the ID cache.
                    var repeatedTerms: [String: [(key: String, term: String)]] = [:]
                    var result = TranslationHistorySummary()
                    while true {
                        try Task.checkCancellation()
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW else { throw queryError(db) }
                        result.count += 1
                        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, includeTerms ? 7 : 0))
                        result.dailyCounts[calendar.startOfDay(for: createdAt), default: 0] += 1
                        if includeTerms {
                            let entry = readEntry(statement)
                            let contentKey = "\(entry.inputText.utf8.count):\(entry.inputText)\(entry.translatedText)"
                            let terms: [(key: String, term: String)]
                            if let cached = repeatedTerms[contentKey] {
                                terms = cached
                            } else {
                                terms = TranslationHistoryAnalysisCache.shared.terms(for: entry, databaseURL: databaseURL)
                                if contentKey.utf8.count <= 2_000 && terms.count <= 128 {
                                    if repeatedTerms.count >= 256 { repeatedTerms.removeAll(keepingCapacity: true) }
                                    repeatedTerms[contentKey] = terms
                                }
                            }
                            try Task.checkCancellation()
                            TranslationHistoryAnalysisCache.accumulate(entry, terms: terms, ignored: ignored, into: &statistics)
                        }
                    }
                    result.distinctTermCount = statistics.count
                    let sorted = TranslationHistoryAnalysisCache.sorted(statistics)
                    result.terms = termLimit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
                    return result
                }
            }
        }
        try Task.checkCancellation()
        if let key { summaryCache.insert(result, for: key) }
        return result
    }

    static func page(databaseURL: URL, range: TranslationHistoryRange, after: TranslationHistoryEntry? = nil, limit: Int = 50) async throws -> TranslationHistoryPage {
        await TranslationHistoryExecutor.pendingWrites(for: databaseURL)
        try Task.checkCancellation()
        return try await background {
            try withDatabase(databaseURL) { db in
                // A tuple upper bound gives SQLite an actual composite-index
                // seek, rather than filtering every preceding page from range.end.
                let cursor = after == nil ? "" : " AND (created_at, id) < (?, ?)"
                let sql = "SELECT \(columns) FROM translation_history WHERE \(filter(for: range))\(cursor) ORDER BY created_at DESC, id DESC LIMIT ?"
                return try withStatement(db, sql) { statement in
                    let effectiveRange = TranslationHistoryRange(start: range.start, end: after.map { min(range.end, $0.createdAt) } ?? range.end, search: range.search)
                    bind(effectiveRange, to: statement)
                    var index: Int32 = range.search.isEmpty ? 3 : 6
                    if let after {
                        sqlite3_bind_double(statement, index, after.createdAt.timeIntervalSince1970)
                        sqlite3_bind_int64(statement, index + 1, after.id)
                        index += 2
                    }
                    let pageSize = max(1, min(limit, 10_000))
                    sqlite3_bind_int64(statement, index, Int64(pageSize + 1))
                    var entries: [TranslationHistoryEntry] = []
                    while true {
                        try Task.checkCancellation()
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW else { throw queryError(db) }
                        entries.append(readEntry(statement))
                    }
                    let retained = Array(entries.prefix(pageSize))
                    var learningTranslation: [Int64: Bool] = [:]
                    for entry in retained {
                        try Task.checkCancellation()
                        learningTranslation[entry.id] = TranslationHistoryAnalysisCache.shared.learnsTranslation(for: entry, databaseURL: databaseURL)
                    }
                    return TranslationHistoryPage(entries: retained, hasMore: entries.count > pageSize, learningTranslation: learningTranslation)
                }
            }
        }
    }

    private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "SnapLex.History", code: 1)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        // The callback executes synchronously inside sqlite3_step on this same
        // detached task. No task captures or cross-thread SQLite pointer access;
        // unregister before closing so no callback outlives its connection.
        sqlite3_progress_handler(db, 1_000, { _ in
            withUnsafeCurrentTask { $0?.isCancelled == true ? 1 : 0 }
        }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        // SQLite lower() is ASCII-only; preserve Foundation Unicode matching.
        sqlite3_create_function_v2(db, "snaplex_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, values in
            guard count == 2, let values,
                  let text = sqlite3_value_text(values[0]),
                  let search = sqlite3_value_text(values[1]) else {
                sqlite3_result_int(context, 0)
                return
            }
            let matches = String(cString: text).localizedCaseInsensitiveContains(String(cString: search))
            sqlite3_result_int(context, matches ? 1 : 0)
        }, nil, nil, nil)
        return try body(db)
    }

    private static func withStatement<T>(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw queryError(db) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private static func bind(_ range: TranslationHistoryRange, to statement: OpaquePointer) {
        sqlite3_bind_double(statement, 1, range.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, range.end.timeIntervalSince1970)
        if !range.search.isEmpty {
            for index: Int32 in 3...5 { sqlite3_bind_text(statement, index, range.search, -1, transient) }
        }
    }

    private static func readEntry(_ statement: OpaquePointer) -> TranslationHistoryEntry {
        func string(_ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }
        return TranslationHistoryEntry(id: sqlite3_column_int64(statement, 0), inputText: string(1), translatedText: string(2), sourceLanguage: string(3), targetLanguage: string(4), sourceApp: string(5), sourceKind: string(6), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)))
    }

    private static func queryError(_ db: OpaquePointer) -> Error {
        if sqlite3_errcode(db) == SQLITE_INTERRUPT { return CancellationError() }
        return NSError(domain: "SnapLex.History.SQLite", code: Int(sqlite3_errcode(db)))
    }
}
