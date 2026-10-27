import Foundation
import SQLite3
import XCTest
@testable import SnapLex

@MainActor
final class TranslationHistoryQueryTests: XCTestCase {
    func testPagesAndStatisticsCoverEveryRecordWithIdenticalTimestamps() async throws {
        let (directory, url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(url, count: 123)
        store.reload()
        XCTAssertEqual(store.entries.count, 50, "Startup should only retain the most recent records")

        let range = TranslationHistoryRange(start: Date(timeIntervalSince1970: 999), end: Date(timeIntervalSince1970: 1001), search: "")
        var all: [TranslationHistoryEntry] = []
        var cursor: TranslationHistoryEntry?
        repeat {
            let page = try await TranslationHistoryQuery.page(databaseURL: url, range: range, after: cursor)
            all.append(contentsOf: page.entries)
            cursor = page.hasMore ? page.entries.last : nil
        } while cursor != nil
        XCTAssertEqual(all.count, 123)
        XCTAssertEqual(Set(all.map(\.id)).count, 123)
        XCTAssertEqual(all.map(\.id), all.map(\.id).sorted(by: >))

        let summary = try await TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: [], calendar: .current)
        XCTAssertEqual(summary.count, 123)
        XCTAssertEqual(summary.dailyCounts.values.reduce(0, +), 123)
        XCTAssertEqual(summary.terms.first(where: { $0.id == "hello" })?.count, 123)
        XCTAssertEqual(summary.terms.first(where: { $0.id == "world" })?.count, 123)
        XCTAssertEqual(summary.terms.count, store.termStatistics(for: all).count)

        let ignored = try await TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: ["HELLO"], calendar: .current)
        XCTAssertNil(ignored.terms.first(where: { $0.id == "hello" }))
        XCTAssertEqual(ignored.terms.first(where: { $0.id == "world" })?.count, 123)
    }

    func testSearchDateBoundsDeletionAndCacheInvalidation() async throws {
        let (directory, url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(url, count: 75)
        store.reload()
        let range = TranslationHistoryRange(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 1000), search: "HELLO")
        let searched = try await TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: [], calendar: .current)
        XCTAssertEqual(searched.count, 75)
        let missing = try await TranslationHistoryQuery.page(databaseURL: url, range: .init(start: range.start, end: range.end, search: "not present"))
        XCTAssertTrue(missing.entries.isEmpty)
        let outside = try await TranslationHistoryQuery.summary(databaseURL: url, range: .init(start: Date(timeIntervalSince1970: 1001), end: Date(timeIntervalSince1970: 2000), search: ""), ignoredWords: [], calendar: .current)
        XCTAssertEqual(outside.count, 0)

        let model = TranslationHistoryQueryModel()
        let now = Date(timeIntervalSince1970: 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        await model.load(store: store, period: .today, search: "", now: now, calendar: calendar)
        XCTAssertEqual(model.summary.count, 75)
        XCTAssertEqual(model.entries.count, 50)
        await model.loadMore(store: store)
        XCTAssertEqual(model.entries.count, 75)
        XCTAssertFalse(model.hasMore)
        let revision = store.revision
        store.deleteEntry(id: model.entries[0].id)
        XCTAssertGreaterThan(store.revision, revision)
        await model.load(store: store, period: .today, search: "", now: now, calendar: calendar)
        XCTAssertEqual(model.summary.count, 74)
        store.addIgnoredWord("hello")
        await model.load(store: store, period: .today, search: "", now: now, calendar: calendar)
        XCTAssertNil(model.summary.terms.first(where: { $0.id == "hello" }))
        store.deleteAllEntries()
        await model.load(store: store, period: .today, search: "", now: now, calendar: calendar)
        XCTAssertEqual(model.summary.count, 0)
    }

    func testLargeHistoryOnlyLoadsFirstPageWhileCountingAllRecords() async throws {
        let (directory, url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try seed(url, count: 10_000)
        store.reload()
        let range = TranslationHistoryRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2000), search: "")
        let pageStart = Date()
        let page = try await TranslationHistoryQuery.page(databaseURL: url, range: range)
        let pageTime = Date().timeIntervalSince(pageStart)
        let summaryStart = Date()
        let summary = try await TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: [], calendar: .current)
        let summaryTime = Date().timeIntervalSince(summaryStart)
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(page.entries.count, 50)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(summary.count, 10_000)
        XCTAssertEqual(summary.terms.first(where: { $0.id == "hello" })?.count, 10_000)
        print("History benchmark (10,000 records): first page \(pageTime)s, full summary \(summaryTime)s")
    }

    func testUnicodeSearchMatchesTextTranslationAndApplicationWithoutCaseSensitivity() async throws {
        let (directory, url, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.recordCompletedTranslation(inputText: "ÉCOLE", translatedText: "学校", sourceLanguage: "fr", targetLanguage: "zh", sourceApp: "Éditeur", trigger: .selection)
        let start = Date(timeIntervalSince1970: 0)
        let end = Date().addingTimeInterval(1)
        for search in ["école", "学校", "éditeur"] {
            let range = TranslationHistoryRange(start: start, end: end, search: search)
            let page = try await TranslationHistoryQuery.page(databaseURL: url, range: range)
            let summary = try await TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: [], calendar: .current)
            XCTAssertEqual(page.entries.count, 1, "search: \(search)")
            XCTAssertEqual(summary.count, 1, "search: \(search)")
        }
    }

    private func makeStore() throws -> (URL, URL, TranslationHistoryStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapLexHistoryQuery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.sqlite3")
        let store = TranslationHistoryStore(databaseURL: url, shouldRecordSelection: { true }, shouldRecordScreenshot: { true })
        return (directory, url, store)
    }

    private func seed(_ url: URL, count: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw NSError(domain: "test", code: 1) }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        let sql = "INSERT INTO translation_history(input_text, translated_text, source_language, target_language, source_app, source_kind, created_at) VALUES ('hello world hello', '你好世界', 'en', 'zh', 'Editor', 'selection', 1000)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        for _ in 0..<count {
            guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "test", code: 2) }
            sqlite3_reset(statement)
        }
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
    }
}
