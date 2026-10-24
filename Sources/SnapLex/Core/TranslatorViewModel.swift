import Foundation
import AppKit
import Combine
import Translation

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
    private var translationRequestID = UUID()
    private var googleTranslationTask: Task<Void, Never>?
    private var usingAppleFallback = false

    init(googleTranslationService: GoogleTranslationService = .shared) {
        self.googleTranslationService = googleTranslationService
    }

    /// Prepares selection when popping up the Selection Pill Bar
    public func preparePillSelection(
        text: String,
        sourceApp: String,
        trigger: TranslationTriggerSource
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputText = cleaned
        self.sourceApp = sourceApp
        self.triggerSource = trigger
        self.capturedImage = nil
    }

    /// Starts instant translation in the Floating Translation Card
    public func startTranslation(
        text: String? = nil,
        mode: TranslationTaskMode = .translate,
        sourceApp: String? = nil,
        trigger: TranslationTriggerSource? = nil,
        image: NSImage? = nil,
        overrideTargetLang: String? = nil
    ) {
        let raw = text ?? self.inputText
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inputText = cleaned
        if let sourceApp = sourceApp { self.sourceApp = sourceApp }
        if let trigger = trigger { self.triggerSource = trigger }
        if let image = image { self.capturedImage = image }

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

        runTranslation(for: cleaned, targetLang: self.targetLangLabel)
    }

    public func changeTargetLanguage(to newTarget: String) {
        guard newTarget != targetLangLabel else { return }
        targetLangLabel = newTarget
        runTranslation(for: inputText, targetLang: newTarget)
    }

    public func rerunCurrentInput() {
        runTranslation(for: inputText, targetLang: targetLangLabel)
    }

    private func runTranslation(for text: String, targetLang: String) {
        googleTranslationTask?.cancel()
        googleTranslationTask = nil
        usingAppleFallback = false
        translatedOutput = ""
        googleDictionaryEntries = []
        errorMessage = nil
        translationRequestID = UUID()

        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            translationConfiguration = nil
            isTranslating = false
            return
        }

        let source = NativeTranslationSupport.sourceLanguageCode(for: cleanedText)
        let target = NativeTranslationSupport.languageCode(for: targetLang)
        guard source != target else {
            translatedOutput = cleanedText
            isTranslating = false
            recordCompletedTranslation(inputText: cleanedText, translatedText: cleanedText)
            return
        }

        isTranslating = true
        switch AppSettings.shared.translationEngine {
        case .google:
            translationConfiguration = nil
            let requestID = translationRequestID
            googleTranslationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await googleTranslationService.translateDetailed(
                        text: cleanedText,
                        targetLanguage: targetLang
                    )
                    guard requestID == self.translationRequestID else { return }
                    self.translatedOutput = result.translation
                    self.googleDictionaryEntries = result.dictionaryEntries
                    self.isTranslating = false
                    self.errorMessage = nil
                    self.recordCompletedTranslation(inputText: cleanedText, translatedText: result.translation)
                } catch is CancellationError {
                    guard requestID == self.translationRequestID else { return }
                    self.isTranslating = false
                } catch {
                    guard requestID == self.translationRequestID else { return }
                    // The public Google Translate endpoint is frequently rate-limited
                    // (HTTP 429) or unreachable on some networks. Keep the selected
                    // engine as the user's preference, but finish this request with
                    // macOS Translation instead of leaving the selection untranslated.
                    self.usingAppleFallback = true
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
        guard AppSettings.shared.translationEngine == .apple || usingAppleFallback else { return }
        let requestID = translationRequestID
        let text = inputText
        guard !text.isEmpty else {
            isTranslating = false
            return
        }

        do {
            try await session.prepareTranslation()
            guard requestID == translationRequestID else { return }
            let response = try await session.translate(text)
            guard requestID == translationRequestID else { return }
            translatedOutput = response.targetText
            isTranslating = false
            errorMessage = nil
            recordCompletedTranslation(inputText: text, translatedText: response.targetText)
        } catch is CancellationError {
            guard requestID == translationRequestID else { return }
            isTranslating = false
        } catch {
            guard requestID == translationRequestID else { return }
            isTranslating = false
            errorMessage = NativeTranslationSupport.userFacingError(for: error)
        }
    }

    private func recordCompletedTranslation(inputText: String, translatedText: String) {
        TranslationHistoryStore.shared.recordCompletedTranslation(
            inputText: inputText,
            translatedText: translatedText,
            sourceLanguage: sourceLangLabel,
            targetLanguage: targetLangLabel,
            sourceApp: sourceApp,
            trigger: triggerSource
        )
    }
}
