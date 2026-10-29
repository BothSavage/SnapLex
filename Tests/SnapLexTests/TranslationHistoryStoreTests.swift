import XCTest
@testable import SnapLex

@MainActor
final class TranslationHistoryStoreTests: XCTestCase {
    func testHistoryPersistsInNewestFirstOrderAndSupportsDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let store = makeStore(databaseURL: databaseURL, now: { timestamp })
        await store.waitForPendingWrites()

        store.recordCompletedTranslation(
            inputText: "  first phrase  ", translatedText: " first result ",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()
        timestamp = Date(timeIntervalSince1970: 2_000)
        store.recordCompletedTranslation(
            inputText: "second phrase", translatedText: "second result",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Browser", trigger: .screenshot
        )
        await store.waitForPendingWrites()

        XCTAssertEqual(store.entries.map(\.inputText), ["second phrase", "first phrase"])
        XCTAssertEqual(store.entries.map(\.translatedText), ["second result", "first result"])
        XCTAssertEqual(store.entries[0].createdAt, timestamp)

        let reopened = makeStore(databaseURL: databaseURL)
        await reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.entries.map(\.inputText), ["second phrase", "first phrase"])
        reopened.deleteEntry(id: reopened.entries[0].id)
        await reopened.waitForPendingWrites()
        XCTAssertEqual(reopened.entries.map(\.inputText), ["first phrase"])
        reopened.deleteAllEntries()
        await reopened.waitForPendingWrites()
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    func testRecordingPreferencesGateSelectionAndScreenshotButNeverManualInput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var recordsSelection = false
        var recordsScreenshot = false
        let store = TranslationHistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3"),
            shouldRecordSelection: { recordsSelection },
            shouldRecordScreenshot: { recordsScreenshot }
        )
        await store.waitForPendingWrites()

        store.recordCompletedTranslation(
            inputText: "selection", translatedText: "选中",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .selection
        )
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "screenshot", translatedText: "截图",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .screenshot
        )
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "manual", translatedText: "手动",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .manual
        )
        await store.waitForPendingWrites()
        XCTAssertTrue(store.entries.isEmpty)

        recordsSelection = true
        recordsScreenshot = true
        store.recordCompletedTranslation(
            inputText: " selection ", translatedText: " selected ",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .doubleCopy
        )
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "screenshot", translatedText: "截图",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .screenshot
        )
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "  ", translatedText: "ignored empty input",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "empty output", translatedText: " \n ",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()

        XCTAssertEqual(Set(store.entries.map(\.inputText)), ["selection", "screenshot"])
        XCTAssertEqual(Set(store.entries.map(\.sourceKind)), ["selection", "screenshot"])
    }

    func testIgnoredTermsAreTrimmedDeduplicatedAndRemovedCaseInsensitively() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        await store.waitForPendingWrites()

        store.addIgnoredWord("  You  ")
        await store.waitForPendingWrites()
        store.addIgnoredWord("you")
        await store.waitForPendingWrites()
        store.addIgnoredWord(" ")
        await store.waitForPendingWrites()
        XCTAssertEqual(store.ignoredWords, ["You"])

        store.removeIgnoredWord(" YOU ")
        await store.waitForPendingWrites()
        XCTAssertTrue(store.ignoredWords.isEmpty)

        store.addIgnoredWord(" Café ")
        await store.waitForPendingWrites()
        store.addIgnoredWord("CAFE")
        await store.waitForPendingWrites()
        XCTAssertEqual(store.ignoredWords, ["Café"])
        store.removeIgnoredWord("cafe")
        await store.waitForPendingWrites()
        XCTAssertTrue(store.ignoredWords.isEmpty)
    }

    func testFrequencyCountsDistinctEnglishTermsPerTranslationAndLearnsEnglishSide() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"), now: { timestamp })
        await store.waitForPendingWrites()

        store.recordCompletedTranslation(
            inputText: "你好，你好，世界。", translatedText: "Hello world hello",
            sourceLanguage: "zh", targetLanguage: "en", sourceApp: "Reader", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()
        timestamp = Date(timeIntervalSince1970: 2_000)
        store.recordCompletedTranslation(
            inputText: "world, world!", translatedText: "世界",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Reader", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()

        XCTAssertEqual(store.learningText(for: store.entries[1]), "Hello world hello")
        XCTAssertEqual(store.contextText(for: store.entries[1]), "你好，你好，世界。")
        XCTAssertEqual(store.learningText(for: store.entries[0]), "world, world!")
        let frequencies = Dictionary(uniqueKeysWithValues: store.termStatistics(for: store.entries).map { ($0.term.lowercased(), $0.count) })
        XCTAssertEqual(frequencies["hello"], 1)
        XCTAssertEqual(frequencies["world"], 2)
    }

    func testIgnoredWordsAreExcludedFromFrequencyAfterNormalization() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "you and YOU can learn", translatedText: "你和你可以学习",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Reader", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()
        store.addIgnoredWord(" You ")
        await store.waitForPendingWrites()

        let frequencies = Dictionary(uniqueKeysWithValues: store.termStatistics(for: store.entries).map { ($0.term.lowercased(), $0.count) })
        XCTAssertNil(frequencies["you"])
        XCTAssertEqual(frequencies["and"], 1)
        XCTAssertEqual(frequencies["learn"], 1)
    }

    func testCachedTermStatisticsRefreshAfterIgnoredWordAndHistoryChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        await store.waitForPendingWrites()
        store.recordCompletedTranslation(
            inputText: "pitch pitch", translatedText: "投球",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Reader", trigger: .mouseSelect
        )
        await store.waitForPendingWrites()

        func frequencies() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: store.termStatistics(for: store.entries).map { ($0.term.lowercased(), $0.count) })
        }

        XCTAssertEqual(frequencies()["pitch"], 1)
        XCTAssertEqual(frequencies()["pitch"], 1)

        store.addIgnoredWord("pitch")
        await store.waitForPendingWrites()
        XCTAssertNil(frequencies()["pitch"])

        store.removeIgnoredWord("pitch")
        await store.waitForPendingWrites()
        XCTAssertEqual(frequencies()["pitch"], 1)

        store.deleteEntry(id: store.entries[0].id)
        await store.waitForPendingWrites()
        XCTAssertNil(frequencies()["pitch"])
    }

    private func makeStore(
        databaseURL: URL,
        shouldRecordSelection: @escaping () -> Bool = { true },
        shouldRecordScreenshot: @escaping () -> Bool = { true },
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 5_000) }
    ) -> TranslationHistoryStore {
        TranslationHistoryStore(
            databaseURL: databaseURL,
            shouldRecordSelection: shouldRecordSelection,
            shouldRecordScreenshot: shouldRecordScreenshot,
            now: now
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapLexTranslationHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
