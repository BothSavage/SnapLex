import Foundation
import AppKit
import Combine

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
    @Published public var aiOutput: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var errorMessage: String? = nil

    // Follow-up ("继续提问") state
    @Published public var followUpQuestion: String = ""
    @Published public var followUpAnswer: String = ""
    @Published public var isStreamingFollowUp: Bool = false

    @Published public var matchedVocabItem: VocabItem? = nil
    @Published public var isPinned: Bool = false
    @Published public var showOriginalText: Bool = false
    @Published public var showSystemDictDetail: Bool = false

    private var streamTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?

    private init() {}

    /// Prepares selection when popping up the Image 1 Pill Bar (before expanding into full card)
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
        self.matchedVocabItem = VocabularyStore.shared.findExisting(term: cleaned)
    }

    /// Starts full translation / explanation / summary in the Image 2 Card
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
        self.errorMessage = nil
        self.aiOutput = ""
        self.followUpAnswer = ""

        guard !cleaned.isEmpty else {
            self.phonetic = ""
            self.systemDefinition = ""
            self.matchedVocabItem = nil
            return
        }

        // Auto language direction (Chinese -> English, English/Other -> 简体中文)
        self.sourceLangLabel = LLMTranslationService.detectSourceLangLabel(cleaned)
        if let overrideTargetLang = overrideTargetLang {
            self.targetLangLabel = overrideTargetLang
        } else {
            self.targetLangLabel = LLMTranslationService.defaultTargetLanguage(for: cleaned)
        }

        // 1. Check if already in Vocabulary Book & increment lookup count
        if let updated = VocabularyStore.shared.incrementLookupIfExists(term: cleaned) {
            self.matchedVocabItem = updated
        } else {
            self.matchedVocabItem = VocabularyStore.shared.findExisting(term: cleaned)
        }

        // 2. Instant offline macOS system dictionary lookup (<2ms)
        if let sysResult = SystemDictionaryService.shared.lookup(cleaned) {
            self.phonetic = sysResult.phonetic
            self.systemDefinition = sysResult.formattedDefinition
            // Auto expand dictionary card if looking up a single word
            self.showSystemDictDetail = LLMTranslationService.isWordOrShortTerm(cleaned)
        } else {
            self.phonetic = ""
            self.systemDefinition = ""
            self.showSystemDictDetail = false
        }

        // 3. Stream translation
        runTranslationStream(for: cleaned, mode: mode, targetLang: self.targetLangLabel)
    }

    public func changeTargetLanguage(to newTarget: String) {
        guard newTarget != targetLangLabel else { return }
        targetLangLabel = newTarget
        runTranslationStream(for: inputText, mode: taskMode, targetLang: newTarget)
    }

    public func rerunCurrentInput() {
        runTranslationStream(for: inputText, mode: taskMode, targetLang: targetLangLabel)
    }

    public func submitFollowUp() {
        let q = followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        followUpTask?.cancel()
        followUpAnswer = ""
        isStreamingFollowUp = true
        let currentQ = q
        followUpQuestion = ""

        let settings = AppSettings.shared
        let orig = inputText
        let trans = aiOutput

        followUpTask = Task {
            do {
                try await LLMTranslationService.shared.streamFollowUp(
                    originalText: orig,
                    currentTranslation: trans,
                    question: currentQ,
                    baseURL: settings.apiBaseURL,
                    apiKey: settings.apiKey,
                    model: settings.modelName
                ) { [weak self] delta in
                    Task { @MainActor in
                        self?.followUpAnswer += delta
                    }
                }
                self.isStreamingFollowUp = false
            } catch {
                self.isStreamingFollowUp = false
                self.followUpAnswer = "⚠️ 追问请求失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    public func saveCurrentToVocab(customTerm: String? = nil) -> VocabItem? {
        let targetTerm = (customTerm ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetTerm.isEmpty else { return nil }

        let dictLookup = SystemDictionaryService.shared.lookup(targetTerm)
        let resolvedPhonetic = (customTerm == nil && !phonetic.isEmpty) ? phonetic : (dictLookup?.phonetic ?? "")
        let resolvedSysDef = (customTerm == nil && !systemDefinition.isEmpty) ? systemDefinition : (dictLookup?.formattedDefinition ?? "")

        let item = VocabularyStore.shared.saveOrUpdate(
            term: targetTerm,
            phonetic: resolvedPhonetic,
            aiTranslation: aiOutput,
            systemDefinition: resolvedSysDef,
            contextSentence: inputText,
            sourceApp: sourceApp,
            screenshotImage: capturedImage
        )
        if customTerm == nil {
            self.matchedVocabItem = item
        }
        return item
    }

    private func runTranslationStream(for text: String, mode: TranslationTaskMode, targetLang: String) {
        streamTask?.cancel()
        aiOutput = ""
        errorMessage = nil
        isStreaming = true

        let settings = AppSettings.shared
        let baseURL = settings.apiBaseURL
        let apiKey = settings.apiKey
        let model = settings.modelName
        let domainHint = settings.domainContextHint
        let appName = self.sourceApp

        streamTask = Task {
            do {
                try await LLMTranslationService.shared.streamTranslate(
                    text: text,
                    mode: mode,
                    sourceApp: appName,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    model: model,
                    targetLangLabel: targetLang,
                    domainHint: domainHint
                ) { [weak self] delta in
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.aiOutput += delta
                    }
                }
                if !Task.isCancelled {
                    self.isStreaming = false
                    if AppSettings.shared.autoSaveSingleWord && LLMTranslationService.isWordOrShortTerm(text) {
                        self.saveCurrentToVocab()
                    }
                }
            } catch is CancellationError {
                self.isStreaming = false
            } catch {
                self.isStreaming = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
