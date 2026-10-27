import Foundation
import AppKit

public enum TranslationTriggerSource: String, Codable {
    case mouseSelect = "鼠标划词"
    case selection = "快捷键划词"
    // Retain the legacy value for decoding existing data; no trigger emits it.
    case doubleCopy = "双击⌘C"
    case screenshot = "截图OCR"
    case manual = "手动输入"
}

public enum FloatingPanelMode: Equatable {
    case pillBar
    case translateCard
}

public enum SnapLexAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public enum TranslationEngine: String, CaseIterable, Identifiable {
    case google
    case apple

    public var id: String { rawValue }
}

public enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"

    public var id: String { rawValue }
}

public struct ShortcutBinding: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    /// Global shortcuts must not consume normal typing, cursor movement or the
    /// standard editing commands used by the app's own selection-copy fallback.
    public var isReservedForTextEditing: Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection([.command, .option, .control, .shift])
        let nonTextKeyCodes: Set<UInt16> = [
            // Function, navigation, and editing keys do not produce text.
            36, 48, 51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126,
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
            105, 107, 113, 106, 64, 79, 80, 90
        ]

        // Option-only combinations with printable keys insert characters on
        // macOS (for example ⌥A inserts å). A global hotkey must never consume
        // ordinary text entry, even when the user records a custom shortcut.
        if flags.contains(.option), !flags.contains(.command) {
            return !nonTextKeyCodes.contains(keyCode)
        }

        if flags.subtracting(.shift).isEmpty {
            return !nonTextKeyCodes.contains(keyCode)
        }
        if flags.contains(.control), !flags.contains(.command), !nonTextKeyCodes.contains(keyCode) {
            // Cocoa text controls and terminals use Control+A/E/F/B/N/P, etc.
            // as editing commands; do not let global shortcuts consume them.
            return true
        }
        if flags == .command || flags == [.command, .shift] {
            // Select all, undo/redo, cut, copy, paste, delete and text navigation.
            return [0, 6, 7, 8, 9, 16, 51, 117, 123, 124, 125, 126].contains(keyCode)
        }
        return false
    }
}

public enum GlobalShortcut: String, CaseIterable, Identifiable {
    case selectionTranslate
    case screenshotF1
    case screenshotOptionS
    case openTranslationCard
    case pinF3
    case pinOptionP
    case restorePin
    case unlockClickThrough
    case screenRecorder
    case stopRecording
    case openSettings
    case quitApp

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .selectionTranslate: return "划词直接翻译"
        case .screenshotF1, .screenshotOptionS: return "区域截图 · 标注 · 滚动长截图 · OCR"
        case .openTranslationCard: return "打开 / 隐藏翻译卡片"
        case .pinF3, .pinOptionP: return "屏幕贴图 (将选区或剪贴板钉在桌面)"
        case .restorePin: return "恢复上一个关闭的贴图"
        case .unlockClickThrough: return "解锁所有桌面贴图"
        case .screenRecorder: return "屏幕录制 (区域 / 窗口 / 全屏导出 MP4 · GIF)"
        case .stopRecording: return "停止录屏"
        case .openSettings: return "打开偏好设置"
        case .quitApp: return "隐藏主页面"
        }
    }

    public var eventID: UInt32? {
        switch self {
        case .selectionTranslate: return 1
        case .screenshotOptionS: return 2
        case .openTranslationCard: return 3
        case .screenshotF1: return 4
        case .pinF3: return 5
        case .pinOptionP: return 6
        case .restorePin: return 7
        case .unlockClickThrough: return 8
        case .screenRecorder: return 9
        case .stopRecording: return 10
        case .openSettings, .quitApp: return nil
        }
    }

    public var defaultBinding: ShortcutBinding {
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let command = NSEvent.ModifierFlags.command.rawValue
        let controlCommand = command | NSEvent.ModifierFlags.control.rawValue
        switch self {
        case .selectionTranslate: return .init(keyCode: 0, modifiers: controlCommand, keyLabel: "A")
        case .screenshotF1: return .init(keyCode: 122, modifiers: 0, keyLabel: "F1")
        case .screenshotOptionS: return .init(keyCode: 1, modifiers: controlCommand, keyLabel: "S")
        case .openTranslationCard: return .init(keyCode: 2, modifiers: controlCommand, keyLabel: "D")
        case .pinF3: return .init(keyCode: 99, modifiers: 0, keyLabel: "F3")
        case .pinOptionP: return .init(keyCode: 35, modifiers: controlCommand, keyLabel: "P")
        case .restorePin: return .init(keyCode: 99, modifiers: shift, keyLabel: "F3")
        case .unlockClickThrough: return .init(keyCode: 7, modifiers: controlCommand, keyLabel: "X")
        case .screenRecorder: return .init(keyCode: 15, modifiers: controlCommand, keyLabel: "R")
        case .stopRecording: return .init(keyCode: 109, modifiers: 0, keyLabel: "F10")
        case .openSettings: return .init(keyCode: 43, modifiers: command, keyLabel: ",")
        case .quitApp: return .init(keyCode: 12, modifiers: command, keyLabel: "Q")
        }
    }

    public var isGlobal: Bool {
        self != .openSettings && self != .quitApp
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
        didSet { defaults.set(enableMouseHoverBar, forKey: "SnapLex.enableMouseHoverBar") }
    }
    @Published public var appearanceMode: SnapLexAppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "SnapLex.appearanceMode")
        }
    }
    @Published public var translationEngine: TranslationEngine {
        didSet {
            defaults.set(translationEngine.rawValue, forKey: "SnapLex.translationEngine")
        }
    }
    @Published public var appLanguage: AppLanguage {
        didSet { defaults.set(appLanguage.rawValue, forKey: "SnapLex.appLanguage") }
    }
    @Published public var shortcutBindings: [String: ShortcutBinding] {
        didSet {
            if let encoded = try? JSONEncoder().encode(shortcutBindings) {
                defaults.set(encoded, forKey: "SnapLex.shortcutBindings")
            }
        }
    }
    @Published public var recordSelectionTranslations: Bool {
        didSet { defaults.set(recordSelectionTranslations, forKey: "SnapLex.recordSelectionTranslations") }
    }
    @Published public var recordScreenshotTranslations: Bool {
        didSet { defaults.set(recordScreenshotTranslations, forKey: "SnapLex.recordScreenshotTranslations") }
    }
    @Published private var storedScreenshotHistoryLimit: Int
    public var screenshotHistoryLimit: Int {
        get { storedScreenshotHistoryLimit }
        set {
            let limit = min(1000, max(1, newValue))
            guard limit != storedScreenshotHistoryLimit else { return }
            storedScreenshotHistoryLimit = limit
            defaults.set(limit, forKey: "SnapLex.screenshotHistoryLimit")
            screenshotRetentionChanged()
        }
    }

    private let defaults: UserDefaults
    private let screenshotRetentionChanged: @MainActor () -> Void

    private convenience init() {
        self.init(defaults: .standard)
    }

    init(
        defaults: UserDefaults,
        screenshotRetentionChanged: @escaping @MainActor () -> Void = {
            ScreenshotHistoryStore.shared.applyRetentionLimit()
        }
    ) {
        self.defaults = defaults
        self.screenshotRetentionChanged = screenshotRetentionChanged
        if defaults.object(forKey: "SnapLex.enableMouseHoverBar") == nil {
            self.enableMouseHoverBar = true
        } else {
            self.enableMouseHoverBar = defaults.bool(forKey: "SnapLex.enableMouseHoverBar")
        }
        self.appearanceMode = SnapLexAppearanceMode(
            rawValue: defaults.string(forKey: "SnapLex.appearanceMode") ?? "system"
        ) ?? .system
        self.translationEngine = TranslationEngine(
            rawValue: defaults.string(forKey: "SnapLex.translationEngine") ?? "google"
        ) ?? .google
        self.appLanguage = AppLanguage(
            rawValue: defaults.string(forKey: "SnapLex.appLanguage") ?? "zh-Hans"
        ) ?? .chinese

        let defaultBindings = Dictionary(
            uniqueKeysWithValues: GlobalShortcut.allCases.map { ($0.rawValue, $0.defaultBinding) }
        )
        if let data = defaults.data(forKey: "SnapLex.shortcutBindings"),
           let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            let merged = defaultBindings.merging(saved) { _, saved in saved }
            var repaired = merged
            for shortcut in GlobalShortcut.allCases where shortcut.isGlobal {
                if repaired[shortcut.rawValue]?.isReservedForTextEditing == true {
                    repaired[shortcut.rawValue] = shortcut.defaultBinding
                }
            }
            self.shortcutBindings = repaired
            if repaired != merged, let encoded = try? JSONEncoder().encode(repaired) {
                defaults.set(encoded, forKey: "SnapLex.shortcutBindings")
            }
        } else {
            self.shortcutBindings = defaultBindings
        }
        self.recordSelectionTranslations = defaults.object(forKey: "SnapLex.recordSelectionTranslations") == nil
            ? true
            : defaults.bool(forKey: "SnapLex.recordSelectionTranslations")
        self.recordScreenshotTranslations = defaults.object(forKey: "SnapLex.recordScreenshotTranslations") == nil
            ? true
            : defaults.bool(forKey: "SnapLex.recordScreenshotTranslations")
        self.storedScreenshotHistoryLimit = defaults.object(forKey: "SnapLex.screenshotHistoryLimit") == nil
            ? 100
            : min(1000, max(1, defaults.integer(forKey: "SnapLex.screenshotHistoryLimit")))
    }

    public func shortcutBinding(for shortcut: GlobalShortcut) -> ShortcutBinding {
        shortcutBindings[shortcut.rawValue] ?? shortcut.defaultBinding
    }

    public func setShortcutBinding(_ binding: ShortcutBinding, for shortcut: GlobalShortcut) {
        guard !shortcut.isGlobal || !binding.isReservedForTextEditing else { return }
        shortcutBindings[shortcut.rawValue] = binding
        SelectionAndHotKeyManager.shared.refreshHotKeys()
    }

    public func resetShortcutBindings() {
        shortcutBindings = Dictionary(
            uniqueKeysWithValues: GlobalShortcut.allCases.map { ($0.rawValue, $0.defaultBinding) }
        )
        SelectionAndHotKeyManager.shared.refreshHotKeys()
    }
}
