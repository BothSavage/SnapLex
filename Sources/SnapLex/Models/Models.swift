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
    case pillBar
    case translateCard
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
    public var masteryLevel: Int
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

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public static let targetLanguages: [(label: String, code: String)] = [
        ("English", "en"),
        ("简体中文", "zh-CN"),
        ("繁體中文", "zh-TW"),
        ("日本語", "ja"),
        ("한국어", "ko"),
        ("Français", "fr"),
        ("Deutsch", "de")
    ]

    @Published public var enableMouseHoverBar: Bool {
        didSet { UserDefaults.standard.set(enableMouseHoverBar, forKey: "SnapLex.enableMouseHoverBar") }
    }
    @Published public var enableDoubleCmdC: Bool {
        didSet { UserDefaults.standard.set(enableDoubleCmdC, forKey: "SnapLex.enableDoubleCmdC") }
    }
    @Published public var markdownExportDir: String {
        didSet { UserDefaults.standard.set(markdownExportDir, forKey: "SnapLex.markdownExportDir") }
    }

    private init() {
        let defaultDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SnapLex-Vocab").path ?? (NSHomeDirectory() + "/Documents/SnapLex-Vocab")

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
        self.markdownExportDir = UserDefaults.standard.string(forKey: "SnapLex.markdownExportDir") ?? defaultDocs
    }
}
