import XCTest
@testable import SnapLex
import Foundation

@MainActor
final class TranslatorViewModelTests: XCTestCase {
    func testChangingTargetOnAnEmptyCardDoesNotStartATranslationRequest() {
        let viewModel = makeViewModel()

        viewModel.changeTargetLanguage(to: "简体中文")

        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.translatedOutput.isEmpty)
        XCTAssertNil(viewModel.translationConfiguration)
    }

    func testSelectingTheSameSourceAndTargetReturnsTheOriginalText() {
        let viewModel = makeViewModel()

        viewModel.startTranslation(text: "Hello from SnapLex", overrideTargetLang: "English")

        XCTAssertEqual(viewModel.translatedOutput, "Hello from SnapLex")
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testGoogleSelectionTranslationRecordsExactlyOnceAfterSuccess() async throws {
        var records: [(String, String, String, String, String, TranslationTriggerSource)] = []
        let viewModel = makeViewModel(
            googleTranslator: { text, _ in
                XCTAssertEqual(text, "pitch")
                return GoogleTranslationResult(translation: "投球", dictionaryEntries: ["noun: throw"])
            },
            historyRecorder: { records.append(($0, $1, $2, $3, $4, $5)) }
        )

        viewModel.startTranslation(
            text: "pitch",
            sourceApp: "Safari",
            trigger: .selection,
            overrideTargetLang: "简体中文"
        )
        try await waitUntil { !viewModel.isTranslating }

        XCTAssertEqual(viewModel.translatedOutput, "投球")
        XCTAssertEqual(viewModel.googleDictionaryEntries, ["noun: throw"])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.0, "pitch")
        XCTAssertEqual(records.first?.1, "投球")
        XCTAssertEqual(records.first?.4, "Safari")
        XCTAssertEqual(records.first?.5, .selection)
    }

    func testPillTranslateActionUsesPreparedSelectionAndPreservesItsSource() async throws {
        let viewModel = makeViewModel(
            googleTranslator: { text, _ in
                XCTAssertEqual(text, "selected word")
                return GoogleTranslationResult(translation: "选中的单词")
            }
        )

        viewModel.preparePillSelection(
            text: "  selected word  ",
            sourceApp: "Chrome",
            trigger: .mouseSelect,
            diagnosticID: "selection-request-1"
        )
        let diagnosticID = viewModel.startPillSelectionTranslation()
        try await waitUntil { !viewModel.isTranslating }

        XCTAssertEqual(diagnosticID, "selection-request-1")
        XCTAssertEqual(viewModel.activeSelectionDiagnosticID, "selection-request-1")
        XCTAssertEqual(viewModel.inputText, "selected word")
        XCTAssertEqual(viewModel.translatedOutput, "选中的单词")
        XCTAssertEqual(viewModel.sourceApp, "Chrome")
        XCTAssertEqual(viewModel.triggerSource, .mouseSelect)
    }

    func testGoogleFailureSwitchesToNativeFallbackAndCompletesHistoryOnce() async throws {
        var records: [(String, String, String, String, String, TranslationTriggerSource)] = []
        let viewModel = makeViewModel(
            googleTranslator: { _, _ in throw URLError(.notConnectedToInternet) },
            historyRecorder: { records.append(($0, $1, $2, $3, $4, $5)) }
        )

        viewModel.startTranslation(
            text: "good morning",
            sourceApp: "Safari",
            trigger: .mouseSelect,
            overrideTargetLang: "简体中文"
        )
        try await waitUntil { viewModel.translationConfiguration != nil }

        XCTAssertTrue(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
        await viewModel.translatePending(
            prepareNativeTranslation: {},
            usingNativeTranslator: { _ in "早上好" }
        )

        XCTAssertEqual(viewModel.translatedOutput, "早上好")
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.0, "good morning")
        XCTAssertEqual(records.first?.1, "早上好")
        XCTAssertEqual(records.first?.5, .mouseSelect)
    }

    func testNativeTranslationFailureStopsSpinnerAndSurfacesAnError() async throws {
        let viewModel = makeViewModel(translationEngine: .apple)
        viewModel.startTranslation(text: "hello", overrideTargetLang: "简体中文")

        await viewModel.translatePending(
            prepareNativeTranslation: {},
            usingNativeTranslator: { _ in throw URLError(.cannotDecodeContentData) }
        )

        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertFalse(viewModel.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(viewModel.translatedOutput.isEmpty)
    }

    func testLateGoogleResponseCannotReplaceNewerTranslation() async throws {
        let firstRequestStarted = expectation(description: "first request entered translator")
        var firstResponse: CheckedContinuation<GoogleTranslationResult, Error>?
        var records: [(String, String, String, String, String, TranslationTriggerSource)] = []
        let viewModel = makeViewModel(
            googleTranslator: { text, _ in
                if text == "first request" {
                    firstRequestStarted.fulfill()
                    return try await withCheckedThrowingContinuation { continuation in
                        firstResponse = continuation
                    }
                }
                return GoogleTranslationResult(translation: "new result")
            },
            historyRecorder: { records.append(($0, $1, $2, $3, $4, $5)) }
        )

        viewModel.startTranslation(text: "first request", overrideTargetLang: "简体中文")
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        viewModel.startTranslation(text: "second request", overrideTargetLang: "简体中文")
        try await waitUntil { !viewModel.isTranslating }

        XCTAssertNotNil(firstResponse)
        firstResponse?.resume(returning: GoogleTranslationResult(translation: "stale result"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(viewModel.translatedOutput, "new result")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.0, "second request")
    }

    func testPreparingAnotherSelectionDiscardsLateResponseAndHistory() async throws {
        let started = expectation(description: "old translation started")
        var response: CheckedContinuation<GoogleTranslationResult, Error>?
        var recordedCount = 0
        let viewModel = makeViewModel(
            googleTranslator: { _, _ in
                started.fulfill()
                return try await withCheckedThrowingContinuation { response = $0 }
            },
            historyRecorder: { _, _, _, _, _, _ in recordedCount += 1 }
        )
        viewModel.startTranslation(text: "old selection", overrideTargetLang: "简体中文")
        await fulfillment(of: [started], timeout: 1)
        viewModel.preparePillSelection(text: "new selection", sourceApp: "New App", trigger: .mouseSelect)
        response?.resume(returning: GoogleTranslationResult(translation: "old response"))
        // Enqueue a main-actor job after the resumed translation job.
        await Task { @MainActor in }.value
        XCTAssertEqual(viewModel.inputText, "new selection")
        XCTAssertEqual(viewModel.sourceApp, "New App")
        XCTAssertTrue(viewModel.translatedOutput.isEmpty)
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertEqual(recordedCount, 0)
    }

    func testCompletedNativeRequestCannotRunAgainOnViewRefresh() async {
        var translatedCount = 0
        var recordedCount = 0
        let viewModel = makeViewModel(translationEngine: .apple, historyRecorder: { _, _, _, _, _, _ in recordedCount += 1 })
        viewModel.startTranslation(text: "hello", overrideTargetLang: "简体中文")
        for _ in 0..<2 {
            await viewModel.translatePending(prepareNativeTranslation: {}, usingNativeTranslator: { _ in
                translatedCount += 1
                return "你好"
            })
        }
        XCTAssertEqual(translatedCount, 1)
        XCTAssertEqual(recordedCount, 1)
    }

    func testIdentityTranslationClearsEarlierNativeConfiguration() {
        let viewModel = makeViewModel(translationEngine: .apple)
        viewModel.startTranslation(text: "hello", overrideTargetLang: "简体中文")
        XCTAssertNotNil(viewModel.translationConfiguration)
        viewModel.startTranslation(text: "hello", overrideTargetLang: "English")
        XCTAssertNil(viewModel.translationConfiguration)
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertEqual(viewModel.translatedOutput, "hello")
    }

    private func makeViewModel(
        translationEngine: TranslationEngine = .google,
        googleTranslator: (@MainActor (String, String) async throws -> GoogleTranslationResult)? = nil,
        historyRecorder: (@MainActor (String, String, String, String, String, TranslationTriggerSource) -> Void)? = nil
    ) -> TranslatorViewModel {
        TranslatorViewModel(
            googleTranslator: googleTranslator,
            translationEngineProvider: { translationEngine },
            historyRecorder: historyRecorder ?? { _, _, _, _, _, _ in }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "condition did not become true before timeout")
    }
}
