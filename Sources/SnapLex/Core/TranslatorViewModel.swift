import Foundation
import AppKit
import Combine
import Translation
import os

@MainActor
public final class TranslatorViewModel: ObservableObject {
    public static let shared = TranslatorViewModel()

    @Published public var inputText: String = ""
    @Published public var sourceApp: String = "macOS"
    @Published public var triggerSource: TranslationTriggerSource = .manual
    @Published public var capturedImage: NSImage? = nil

    @Published public var taskMode: TranslationTaskMode = .translate
    @Published public var sourceLangLabel: String = "自动检测"
    @Published public var targetLangLabel: String = "English"

    @Published public var phonetic: String = ""
    @Published public var systemDefinition: String = ""
    @Published public var translatedOutput: String = ""
    @Published public var googleDictionaryEntries: [String] = []
    @Published public var isTranslating: Bool = false
    @Published public var errorMessage: String? = nil

    @Published public var isPinned: Bool = false
    @Published public var showOriginalText: Bool = false
    @Published public var showSystemDictDetail: Bool = false
    @Published public var translationConfiguration: TranslationSession.Configuration?

    private let googleTranslationService: GoogleTranslationService
    private let googleTranslator: @MainActor (String, String) async throws -> GoogleTranslationResult
    private let translationEngineProvider: @MainActor () -> TranslationEngine
    private let historyRecorder: @MainActor (String, String, String, String, String, TranslationTriggerSource) -> Void
    private let translationLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "Translation"
    )
    private var translationRequestID = UUID()
    private var preparedSelectionDiagnosticID: String?
    private(set) var activeSelectionDiagnosticID: String?
    private var googleTranslationTask: Task<Void, Never>?
    private var usingAppleFallback = false

    init(
        googleTranslationService: GoogleTranslationService = .shared,
        googleTranslator: (@MainActor (String, String) async throws -> GoogleTranslationResult)? = nil,
        translationEngineProvider: (@MainActor () -> TranslationEngine)? = nil,
        historyRecorder: (@MainActor (String, String, String, String, String, TranslationTriggerSource) -> Void)? = nil
    ) {
        self.googleTranslationService = googleTranslationService
        self.googleTranslator = googleTranslator ?? { text, targetLanguage in
            try await googleTranslationService.translateDetailed(text: text, targetLanguage: targetLanguage)
        }
        self.translationEngineProvider = translationEngineProvider ?? { AppSettings.shared.translationEngine }
        self.historyRecorder = historyRecorder ?? { inputText, translatedText, sourceLanguage, targetLanguage, sourceApp, trigger in
            TranslationHistoryStore.shared.recordCompletedTranslation(
                inputText: inputText,
                translatedText: translatedText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sourceApp: sourceApp,
                trigger: trigger
            )
        }
    }

    /// Prepares selection when popping up the Selection Pill Bar
    public func preparePillSelection(
        text: String,
        sourceApp: String,
        trigger: TranslationTriggerSource,
        diagnosticID: String? = nil
    ) {
        // Preparing another selection also supersedes a translation that may
        // still be awaiting the network or Apple's model download.
        cancelPendingTranslation()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputText = cleaned
        self.sourceApp = sourceApp
        self.triggerSource = trigger
        self.capturedImage = nil
        preparedSelectionDiagnosticID = diagnosticID
        translationLogger.info("selection prepared request=\(diagnosticID ?? "-", privacy: .public) characters=\(cleaned.count, privacy: .public) source=\(sourceApp, privacy: .public) trigger=\(trigger.rawValue, privacy: .public)")
    }

    /// Starts translation from the selection pill and carries its mouse-selection
    /// request ID through card presentation and translation completion logs.
    @discardableResult
    public func startPillSelectionTranslation(mode: TranslationTaskMode = .translate) -> String? {
        let diagnosticID = preparedSelectionDiagnosticID
        preparedSelectionDiagnosticID = nil
        translationLogger.info("selection pill translate action request=\(diagnosticID ?? "-", privacy: .public) characters=\(self.inputText.count, privacy: .public)")
        startTranslation(mode: mode, selectionDiagnosticID: diagnosticID)
        return diagnosticID
    }

    /// Starts instant translation in the Floating Translation Card
    public func startTranslation(
        text: String? = nil,
        mode: TranslationTaskMode = .translate,
        sourceApp: String? = nil,
        trigger: TranslationTriggerSource? = nil,
        image: NSImage? = nil,
        overrideTargetLang: String? = nil,
        selectionDiagnosticID: String? = nil
    ) {
        let raw = text ?? self.inputText
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputText = cleaned
        if let sourceApp = sourceApp { self.sourceApp = sourceApp }
        if let trigger = trigger { self.triggerSource = trigger }
        if let image = image { self.capturedImage = image }
        activeSelectionDiagnosticID = selectionDiagnosticID

        self.taskMode = mode
        googleTranslationTask?.cancel()
        googleTranslationTask = nil
        translationRequestID = UUID()
        self.errorMessage = nil
        self.translatedOutput = ""
        self.googleDictionaryEntries = []

        guard !cleaned.isEmpty else {
            self.phonetic = ""
            self.systemDefinition = ""
            self.isTranslating = false
            self.translationConfiguration = nil
            return
        }

        // Auto language direction (Chinese -> English, English/Other -> 简体中文)
        self.sourceLangLabel = NativeTranslationSupport.detectSourceLangLabel(cleaned)
        if let overrideTargetLang = overrideTargetLang {
            self.targetLangLabel = overrideTargetLang
        } else {
            self.targetLangLabel = NativeTranslationSupport.defaultTargetLanguage(for: cleaned)
        }

        // Instant offline macOS system dictionary lookup (<2ms)
        if let sysResult = SystemDictionaryService.shared.lookup(cleaned) {
            self.phonetic = sysResult.phonetic
            self.systemDefinition = sysResult.formattedDefinition
            self.showSystemDictDetail = cleaned.count <= 42 && !cleaned.contains("\n")
        } else {
            self.phonetic = ""
            self.systemDefinition = ""
            self.showSystemDictDetail = false
        }

        runTranslation(
            for: cleaned,
            targetLang: self.targetLangLabel,
            selectionDiagnosticID: selectionDiagnosticID
        )
    }

    public func changeTargetLanguage(to newTarget: String) {
        guard newTarget != targetLangLabel else { return }
        targetLangLabel = newTarget
        runTranslation(for: inputText, targetLang: newTarget, selectionDiagnosticID: activeSelectionDiagnosticID)
    }

    public func rerunCurrentInput() {
        runTranslation(for: inputText, targetLang: targetLangLabel, selectionDiagnosticID: activeSelectionDiagnosticID)
    }

    public func cancelPendingTranslation() {
        translationRequestID = UUID()
        googleTranslationTask?.cancel()
        googleTranslationTask = nil
        usingAppleFallback = false
        translationConfiguration = nil
        isTranslating = false
    }

    private func runTranslation(for text: String, targetLang: String, selectionDiagnosticID: String? = nil) {
        googleTranslationTask?.cancel()
        googleTranslationTask = nil
        usingAppleFallback = false
        translatedOutput = ""
        googleDictionaryEntries = []
        errorMessage = nil
        translationRequestID = UUID()
        let requestID = translationRequestID.uuidString

        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            translationConfiguration = nil
            isTranslating = false
            translationLogger.debug("translation skipped request=\(requestID, privacy: .public) reason=empty-input")
            return
        }

        let source = NativeTranslationSupport.sourceLanguageCode(for: cleanedText)
        let target = NativeTranslationSupport.languageCode(for: targetLang)
        guard source != target else {
            translationConfiguration = nil
            translatedOutput = cleanedText
            isTranslating = false
            recordCompletedTranslation(inputText: cleanedText, translatedText: cleanedText)
            translationLogger.info("translation completed request=\(requestID, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) engine=identity characters=\(cleanedText.count, privacy: .public)")
            return
        }

        isTranslating = true
        let engine = translationEngineProvider()
        translationLogger.info("translation started request=\(requestID, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) engine=\(engine.rawValue, privacy: .public) source=\(source, privacy: .public) target=\(target, privacy: .public) characters=\(cleanedText.count, privacy: .public) trigger=\(self.triggerSource.rawValue, privacy: .public)")
        switch engine {
        case .google:
            translationConfiguration = nil
            googleTranslationTask = Task { [weak self] in
                guard let self else { return }
                let startedAt = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try await googleTranslator(cleanedText, targetLang)
                    guard requestID == self.translationRequestID.uuidString else {
                        self.translationLogger.debug("translation result discarded request=\(requestID, privacy: .public) reason=stale-google-response")
                        return
                    }
                    self.translatedOutput = result.translation
                    self.googleDictionaryEntries = result.dictionaryEntries
                    self.isTranslating = false
                    self.errorMessage = nil
                    self.recordCompletedTranslation(inputText: cleanedText, translatedText: result.translation)
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
                    self.translationLogger.info("translation completed request=\(requestID, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) engine=google milliseconds=\(milliseconds, privacy: .public) characters=\(result.translation.count, privacy: .public) dictionaryEntries=\(result.dictionaryEntries.count, privacy: .public)")
                } catch is CancellationError {
                    self.translationLogger.debug("translation cancelled request=\(requestID, privacy: .public) engine=google")
                    guard requestID == self.translationRequestID.uuidString else { return }
                    self.isTranslating = false
                } catch {
                    guard !Task.isCancelled else { return }
                    guard requestID == self.translationRequestID.uuidString else {
                        self.translationLogger.debug("translation failure discarded request=\(requestID, privacy: .public) reason=stale-google-error")
                        return
                    }
                    // The public Google Translate endpoint is frequently rate-limited
                    // (HTTP 429) or unreachable on some networks. Keep the selected
                    // engine as the user's preference, but finish this request with
                    // macOS Translation instead of leaving the selection untranslated.
                    self.usingAppleFallback = true
                    self.translationLogger.error("translation fallback request=\(requestID, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) from=google to=apple errorType=\(String(reflecting: type(of: error)), privacy: .public)")
                    self.translationConfiguration = NativeTranslationSupport.makeConfiguration(
                        source: NativeTranslationSupport.sourceLanguageCode(for: cleanedText),
                        target: NativeTranslationSupport.languageCode(for: targetLang)
                    )
                }
            }
        case .apple:
            let sourceLanguage = Locale.Language(identifier: source)
            let targetLanguage = Locale.Language(identifier: target)
            if var configuration = translationConfiguration,
               configuration.source == sourceLanguage,
               configuration.target == targetLanguage {
                configuration.invalidate()
                translationConfiguration = configuration
            } else {
                translationConfiguration = NativeTranslationSupport.makeConfiguration(source: source, target: target)
            }
        }
    }

    public func translatePending(using session: TranslationSession) async {
        await translatePending(
            prepareNativeTranslation: { try await session.prepareTranslation() },
            usingNativeTranslator: { text in try await session.translate(text).targetText }
        )
    }

    func translatePending(
        prepareNativeTranslation prepare: @MainActor () async throws -> Void,
        usingNativeTranslator translate: @MainActor (String) async throws -> String
    ) async {
        guard isTranslating, translationEngineProvider() == .apple || usingAppleFallback else { return }
        let requestID = translationRequestID
        let requestIDLabel = requestID.uuidString
        let selectionDiagnosticID = activeSelectionDiagnosticID
        let text = inputText
        guard !text.isEmpty else {
            isTranslating = false
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        translationLogger.info("native translation started request=\(requestIDLabel, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) characters=\(text.count, privacy: .public) fallback=\(self.usingAppleFallback, privacy: .public)")
        do {
            try await prepare()
            guard requestID == translationRequestID else {
                translationLogger.debug("native translation preparation discarded request=\(requestIDLabel, privacy: .public) reason=stale-request")
                return
            }
            let translatedText = try await translate(text)
            guard requestID == translationRequestID else {
                translationLogger.debug("native translation result discarded request=\(requestIDLabel, privacy: .public) reason=stale-request")
                return
            }
            translatedOutput = translatedText
            isTranslating = false
            errorMessage = nil
            recordCompletedTranslation(inputText: text, translatedText: translatedText)
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            translationLogger.info("native translation completed request=\(requestIDLabel, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) milliseconds=\(milliseconds, privacy: .public) characters=\(translatedText.count, privacy: .public)")
        } catch is CancellationError {
            translationLogger.debug("native translation cancelled request=\(requestIDLabel, privacy: .public)")
            guard requestID == translationRequestID else { return }
            isTranslating = false
        } catch {
            guard requestID == translationRequestID else { return }
            isTranslating = false
            errorMessage = NativeTranslationSupport.userFacingError(for: error)
            translationLogger.error("native translation failed request=\(requestIDLabel, privacy: .public) selectionRequest=\(selectionDiagnosticID ?? "-", privacy: .public) errorType=\(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    private func recordCompletedTranslation(inputText: String, translatedText: String) {
        historyRecorder(
            inputText,
            translatedText,
            sourceLangLabel,
            targetLangLabel,
            sourceApp,
            triggerSource
        )
    }
}
