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

    @Published public var isPinned: Bool = false
    @Published public var showOriginalText: Bool = false
    @Published public var showSystemDictDetail: Bool = false

    private var streamTask: Task<Void, Never>?

    private init() {}

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
        self.errorMessage = nil
        self.aiOutput = ""

        guard !cleaned.isEmpty else {
            self.phonetic = ""
            self.systemDefinition = ""
            return
        }

        // Auto language direction (Chinese -> English, English/Other -> 简体中文)
        self.sourceLangLabel = LLMTranslationService.detectSourceLangLabel(cleaned)
        if let overrideTargetLang = overrideTargetLang {
            self.targetLangLabel = overrideTargetLang
        } else {
            self.targetLangLabel = LLMTranslationService.defaultTargetLanguage(for: cleaned)
        }

        // Instant offline macOS system dictionary lookup (<2ms)
        if let sysResult = SystemDictionaryService.shared.lookup(cleaned) {
            self.phonetic = sysResult.phonetic
            self.systemDefinition = sysResult.formattedDefinition
            self.showSystemDictDetail = LLMTranslationService.isWordOrShortTerm(cleaned)
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
        streamTask?.cancel()
        aiOutput = ""
        errorMessage = nil
        isStreaming = true

        streamTask = Task {
            do {
                let result = try await LLMTranslationService.shared.translate(
                    text: text,
                    targetLangLabel: targetLang
                )
                if !Task.isCancelled {
                    self.aiOutput = result
                    self.isStreaming = false
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
