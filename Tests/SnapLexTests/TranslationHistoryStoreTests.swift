import XCTest
@testable import SnapLex

@MainActor
final class TranslationHistoryStoreTests: XCTestCase {
    func testHistoryPersistsInNewestFirstOrderAndSupportsDeletion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let store = makeStore(databaseURL: databaseURL, now: { timestamp })

        store.recordCompletedTranslation(
            inputText: "  first phrase  ", translatedText: " first result ",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .mouseSelect
        )
        timestamp = Date(timeIntervalSince1970: 2_000)
        store.recordCompletedTranslation(
            inputText: "second phrase", translatedText: "second result",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Browser", trigger: .screenshot
        )

        XCTAssertEqual(store.entries.map(\.inputText), ["second phrase", "first phrase"])
        XCTAssertEqual(store.entries.map(\.translatedText), ["second result", "first result"])
        XCTAssertEqual(store.entries[0].createdAt, timestamp)

        let reopened = makeStore(databaseURL: databaseURL)
        XCTAssertEqual(reopened.entries.map(\.inputText), ["second phrase", "first phrase"])
        reopened.deleteEntry(id: reopened.entries[0].id)
        XCTAssertEqual(reopened.entries.map(\.inputText), ["first phrase"])
        reopened.deleteAllEntries()
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    func testRecordingPreferencesGateSelectionAndScreenshotButNeverManualInput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var recordsSelection = false
        var recordsScreenshot = false
        let store = TranslationHistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3"),
            shouldRecordSelection: { recordsSelection },
            shouldRecordScreenshot: { recordsScreenshot }
        )

        store.recordCompletedTranslation(
            inputText: "selection", translatedText: "选中",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .selection
        )
        store.recordCompletedTranslation(
            inputText: "screenshot", translatedText: "截图",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .screenshot
        )
        store.recordCompletedTranslation(
            inputText: "manual", translatedText: "手动",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .manual
        )
        XCTAssertTrue(store.entries.isEmpty)

        recordsSelection = true
        recordsScreenshot = true
        store.recordCompletedTranslation(
            inputText: " selection ", translatedText: " selected ",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .doubleCopy
        )
        store.recordCompletedTranslation(
            inputText: "screenshot", translatedText: "截图",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .screenshot
        )
        store.recordCompletedTranslation(
            inputText: "  ", translatedText: "ignored empty input",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .mouseSelect
        )
        store.recordCompletedTranslation(
            inputText: "empty output", translatedText: " \n ",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Editor", trigger: .mouseSelect
        )

        XCTAssertEqual(Set(store.entries.map(\.inputText)), ["selection", "screenshot"])
        XCTAssertEqual(Set(store.entries.map(\.sourceKind)), ["selection", "screenshot"])
    }

    func testIgnoredTermsAreTrimmedDeduplicatedAndRemovedCaseInsensitively() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))

        store.addIgnoredWord("  You  ")
        store.addIgnoredWord("you")
        store.addIgnoredWord(" ")
        XCTAssertEqual(store.ignoredWords, ["You"])

        store.removeIgnoredWord(" YOU ")
        XCTAssertTrue(store.ignoredWords.isEmpty)

        store.addIgnoredWord(" Café ")
        store.addIgnoredWord("CAFE")
        XCTAssertEqual(store.ignoredWords, ["Café"])
        store.removeIgnoredWord("cafe")
        XCTAssertTrue(store.ignoredWords.isEmpty)
    }

    func testFrequencyCountsDistinctEnglishTermsPerTranslationAndLearnsEnglishSide() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"), now: { timestamp })

        store.recordCompletedTranslation(
            inputText: "你好，你好，世界。", translatedText: "Hello world hello",
            sourceLanguage: "zh", targetLanguage: "en", sourceApp: "Reader", trigger: .mouseSelect
        )
        timestamp = Date(timeIntervalSince1970: 2_000)
        store.recordCompletedTranslation(
            inputText: "world, world!", translatedText: "世界",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Reader", trigger: .mouseSelect
        )

        XCTAssertEqual(store.learningText(for: store.entries[1]), "Hello world hello")
        XCTAssertEqual(store.contextText(for: store.entries[1]), "你好，你好，世界。")
        XCTAssertEqual(store.learningText(for: store.entries[0]), "world, world!")
        let frequencies = Dictionary(uniqueKeysWithValues: store.termStatistics(for: store.entries).map { ($0.term.lowercased(), $0.count) })
        XCTAssertEqual(frequencies["hello"], 1)
        XCTAssertEqual(frequencies["world"], 2)
    }

    func testIgnoredWordsAreExcludedFromFrequencyAfterNormalization() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        store.recordCompletedTranslation(
            inputText: "you and YOU can learn", translatedText: "你和你可以学习",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Reader", trigger: .mouseSelect
        )
        store.addIgnoredWord(" You ")

        let frequencies = Dictionary(uniqueKeysWithValues: store.termStatistics(for: store.entries).map { ($0.term.lowercased(), $0.count) })
        XCTAssertNil(frequencies["you"])
        XCTAssertEqual(frequencies["and"], 1)
        XCTAssertEqual(frequencies["learn"], 1)
    }

    func testCachedTermStatisticsRefreshAfterIgnoredWordAndHistoryChanges() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        store.recordCompletedTranslation(
            inputText: "pitch pitch", translatedText: "投球",
            sourceLanguage: "en", targetLanguage: "zh", sourceApp: "Reader", trigger: .mouseSelect
        )

        func frequencies() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: store.termStatistics(for: store.entries).map { ($0.term.lowercased(), $0.count) })
        }

        XCTAssertEqual(frequencies()["pitch"], 1)
        XCTAssertEqual(frequencies()["pitch"], 1)

        store.addIgnoredWord("pitch")
        XCTAssertNil(frequencies()["pitch"])

        store.removeIgnoredWord("pitch")
        XCTAssertEqual(frequencies()["pitch"], 1)

        store.deleteEntry(id: store.entries[0].id)
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
