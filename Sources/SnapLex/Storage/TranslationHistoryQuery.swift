import Foundation
import SQLite3

struct TranslationHistoryRange: Hashable {
    let start: Date
    let end: Date
    let search: String
}

struct TranslationHistorySummary {
    var count = 0
    var dailyCounts: [Date: Int] = [:]
    var terms: [TranslationTermStatistic] = []
}

struct TranslationHistoryPage {
    let entries: [TranslationHistoryEntry]
    let hasMore: Bool
}

/// Read-only connections keep long scans and tokenization off the UI thread.
/// Each query uses its own connection, so cancelled or stale reads cannot block writes.
enum TranslationHistoryQuery {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "id, input_text, translated_text, source_language, target_language, source_app, source_kind, created_at"
    private static let filter = "created_at >= ? AND created_at <= ? AND (? = '' OR snaplex_contains(input_text, ?) OR snaplex_contains(translated_text, ?) OR snaplex_contains(source_app, ?))"

    static func summary(databaseURL: URL, range: TranslationHistoryRange, ignoredWords: [String], calendar: Calendar, includeTerms: Bool = true) async throws -> TranslationHistorySummary {
        try await background {
            try withDatabase(databaseURL) { db in
                let selected = includeTerms ? columns : "created_at"
                let sql = "SELECT \(selected) FROM translation_history WHERE \(filter) ORDER BY created_at DESC, id DESC"
                return try withStatement(db, sql) { statement in
                    bind(range, to: statement)
                    let ignored = Set(ignoredWords.map(TranslationHistoryStore.normalized))
                    var stats: [String: (term: String, count: Int, latest: Date, translation: String)] = [:]
                    var languageCache: [String: String] = [:]
                    var result = TranslationHistorySummary()
                    while true {
                        try Task.checkCancellation()
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW else { throw queryError(db) }
                        result.count += 1
                        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, includeTerms ? 7 : 0))
                        result.dailyCounts[calendar.startOfDay(for: createdAt), default: 0] += 1
                        guard includeTerms else { continue }
                        let entry = readEntry(statement)
                        let source: String
                        if let cached = languageCache[entry.inputText] {
                            source = cached
                        } else {
                            source = NativeTranslationSupport.sourceLanguageCode(for: entry.inputText)
                            if entry.inputText.utf8.count <= 2_000 {
                                if languageCache.count >= 1_024 { languageCache.removeAll(keepingCapacity: true) }
                                languageCache[entry.inputText] = source
                            }
                        }
                        let text = source == "zh" || source == "zh-TW" ? entry.translatedText : entry.inputText
                        var seen = Set<String>()
                        for term in TranslationHistoryStore.words(in: text) {
                            let key = TranslationHistoryStore.normalized(term)
                            guard !key.isEmpty, !ignored.contains(key), seen.insert(key).inserted else { continue }
                            if var current = stats[key] {
                                current.count += 1
                                if entry.createdAt > current.latest {
                                    current.latest = entry.createdAt
                                    current.translation = entry.translatedText
                                }
                                stats[key] = current
                            } else {
                                stats[key] = (term, 1, entry.createdAt, entry.translatedText)
                            }
                        }
                    }
                    result.terms = stats.map { key, value in
                        TranslationTermStatistic(id: key, term: value.term, count: value.count, latestDate: value.latest, latestTranslation: value.translation)
                    }.sorted { lhs, rhs in
                        lhs.count == rhs.count ? lhs.latestDate > rhs.latestDate : lhs.count > rhs.count
                    }
                    return result
                }
            }
        }
    }

    static func page(databaseURL: URL, range: TranslationHistoryRange, after: TranslationHistoryEntry? = nil, limit: Int = 50) async throws -> TranslationHistoryPage {
        try await background {
            try withDatabase(databaseURL) { db in
                let cursor = after == nil ? "" : " AND (created_at < ? OR (created_at = ? AND id < ?))"
                let sql = "SELECT \(columns) FROM translation_history WHERE \(filter)\(cursor) ORDER BY created_at DESC, id DESC LIMIT ?"
                return try withStatement(db, sql) { statement in
                    bind(range, to: statement)
                    var index: Int32 = 7
                    if let after {
                        sqlite3_bind_double(statement, index, after.createdAt.timeIntervalSince1970)
                        sqlite3_bind_double(statement, index + 1, after.createdAt.timeIntervalSince1970)
                        sqlite3_bind_int64(statement, index + 2, after.id)
                        index += 3
                    }
                    sqlite3_bind_int64(statement, index, Int64(max(1, limit) + 1))
                    var entries: [TranslationHistoryEntry] = []
                    while true {
                        try Task.checkCancellation()
                        let status = sqlite3_step(statement)
                        if status == SQLITE_DONE { break }
                        guard status == SQLITE_ROW else { throw queryError(db) }
                        entries.append(readEntry(statement))
                    }
                    return TranslationHistoryPage(entries: Array(entries.prefix(max(1, limit))), hasMore: entries.count > max(1, limit))
                }
            }
        }
    }

    private static func background<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "SnapLex.History", code: 1)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        // SQLite's built-in lower() only handles ASCII by default. Use
        // Foundation's Unicode-aware matching for the supported UI languages.
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
        for index: Int32 in 3...6 { sqlite3_bind_text(statement, index, range.search, -1, transient) }
    }

    private static func readEntry(_ statement: OpaquePointer) -> TranslationHistoryEntry {
        func string(_ index: Int32) -> String {
            guard let value = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: value)
        }
        return TranslationHistoryEntry(id: sqlite3_column_int64(statement, 0), inputText: string(1), translatedText: string(2), sourceLanguage: string(3), targetLanguage: string(4), sourceApp: string(5), sourceKind: string(6), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)))
    }

    private static func queryError(_ db: OpaquePointer) -> Error {
        NSError(domain: "SnapLex.History.SQLite", code: Int(sqlite3_errcode(db)))
    }
}
