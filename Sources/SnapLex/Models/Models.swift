import Foundation
import AppKit

public enum TranslationTriggerSource: String, Codable {
    case mouseSelect = "鼠标划词"
    case selection = "快捷键划词"
    case doubleCopy = "双击⌘C"
    case screenshot = "截图OCR"
    case manual = "手动输入"
}

public enum FloatingPanelMode: Equatable {
    case pillBar      // Image 1: 划词悬浮胶囊条 (AI 搜索 | 翻译 | 总结 | 复制 | 朗读 | ...)
    case translateCard // Image 2: 翻译悬浮卡片 (这里是我的翻译 + 语言切换 + 译文 + 工具栏 + 继续提问)
}

public struct VocabItem: Identifiable, Codable, Equatable {
    public var id: Int64
    public var term: String
    public var phonetic: String
    public var aiTranslation: String
    public var systemDefinition: String
    public var contextSentence: String
    public var sourceApp: String
    public var screenshotFilename: String?
    public var lookupCount: Int
    public var masteryLevel: Int // 0: 新词, 1: 熟悉中, 2: 已掌握
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64 = 0,
        term: String,
        phonetic: String = "",
        aiTranslation: String = "",
        systemDefinition: String = "",
        contextSentence: String = "",
        sourceApp: String = "",
        screenshotFilename: String? = nil,
        lookupCount: Int = 1,
        masteryLevel: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.phonetic = phonetic
        self.aiTranslation = aiTranslation
        self.systemDefinition = systemDefinition
        self.contextSentence = contextSentence
        self.sourceApp = sourceApp
        self.screenshotFilename = screenshotFilename
        self.lookupCount = lookupCount
        self.masteryLevel = masteryLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct APIProviderPreset: Identifiable {
    public let id = UUID()
    public let name: String
    public let baseURL: String
    public let defaultModel: String
}

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public static let presets: [APIProviderPreset] = [
        APIProviderPreset(name: "DeepSeek 官方", baseURL: "https://api.deepseek.com/v1", defaultModel: "deepseek-chat"),
        APIProviderPreset(name: "硅基流动 (SiliconFlow)", baseURL: "https://api.siliconflow.cn/v1", defaultModel: "Qwen/Qwen2.5-72B-Instruct"),
        APIProviderPreset(name: "OpenAI 兼容 / 中转", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
        APIProviderPreset(name: "本地代理 (free-app-proxy / vLLM)", baseURL: "http://127.0.0.1:8099/v1", defaultModel: "gpt-5.4")
    ]

    public static let targetLanguages: [(label: String, code: String)] = [
        ("English", "en"),
        ("简体中文", "zh-CN"),
        ("繁體中文", "zh-TW"),
        ("日本語", "ja"),
        ("한국어", "ko"),
        ("Français", "fr"),
        ("Deutsch", "de")
    ]

    @Published public var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: "SnapLex.apiBaseURL") }
    }
    @Published public var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "SnapLex.apiKey") }
    }
    @Published public var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: "SnapLex.modelName") }
    }
    @Published public var enableMouseHoverBar: Bool {
        didSet { UserDefaults.standard.set(enableMouseHoverBar, forKey: "SnapLex.enableMouseHoverBar") }
    }
    @Published public var enableDoubleCmdC: Bool {
        didSet { UserDefaults.standard.set(enableDoubleCmdC, forKey: "SnapLex.enableDoubleCmdC") }
    }
    @Published public var autoSaveSingleWord: Bool {
        didSet { UserDefaults.standard.set(autoSaveSingleWord, forKey: "SnapLex.autoSaveSingleWord") }
    }
    @Published public var markdownExportDir: String {
        didSet { UserDefaults.standard.set(markdownExportDir, forKey: "SnapLex.markdownExportDir") }
    }
    @Published public var domainContextHint: String {
        didSet { UserDefaults.standard.set(domainContextHint, forKey: "SnapLex.domainContextHint") }
    }

    private init() {
        let defaultDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SnapLex-Vocab").path ?? (NSHomeDirectory() + "/Documents/SnapLex-Vocab")

        self.apiBaseURL = UserDefaults.standard.string(forKey: "SnapLex.apiBaseURL") ?? "https://api.deepseek.com/v1"
        self.apiKey = UserDefaults.standard.string(forKey: "SnapLex.apiKey") ?? ""
        self.modelName = UserDefaults.standard.string(forKey: "SnapLex.modelName") ?? "deepseek-chat"

        if UserDefaults.standard.object(forKey: "SnapLex.enableMouseHoverBar") == nil {
            self.enableMouseHoverBar = true
        } else {
            self.enableMouseHoverBar = UserDefaults.standard.bool(forKey: "SnapLex.enableMouseHoverBar")
        }
        if UserDefaults.standard.object(forKey: "SnapLex.enableDoubleCmdC") == nil {
            self.enableDoubleCmdC = true
        } else {
            self.enableDoubleCmdC = UserDefaults.standard.bool(forKey: "SnapLex.enableDoubleCmdC")
        }
        if UserDefaults.standard.object(forKey: "SnapLex.autoSaveSingleWord") == nil {
            self.autoSaveSingleWord = false
        } else {
            self.autoSaveSingleWord = UserDefaults.standard.bool(forKey: "SnapLex.autoSaveSingleWord")
        }
        self.markdownExportDir = UserDefaults.standard.string(forKey: "SnapLex.markdownExportDir") ?? defaultDocs
        self.domainContextHint = UserDefaults.standard.string(forKey: "SnapLex.domainContextHint") ?? "计算机科学、AI/大模型推理、CUDA/GPU体系结构、软件工程与通用英语"
    }
}
