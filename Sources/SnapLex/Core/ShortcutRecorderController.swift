import AppKit
import Combine

@MainActor
public final class ShortcutRecorderController: ObservableObject {
    public static let shared = ShortcutRecorderController()

    @Published public private(set) var activeShortcut: GlobalShortcut?
    @Published public private(set) var errorMessage: String?

    private var eventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    public var isCapturing: Bool { activeShortcut != nil }

    private init() {}

    public func beginCapturing(_ shortcut: GlobalShortcut) {
        stopMonitor()
        errorMessage = nil
        activeShortcut = shortcut
        SelectionAndHotKeyManager.shared.suspendHotKeysForRecording()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
            return nil
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelCapture() }
        }
    }

    public func cancelCapture() {
        let wasCapturing = isCapturing
        activeShortcut = nil
        errorMessage = nil
        stopMonitor()
        if wasCapturing {
            SelectionAndHotKeyManager.shared.refreshHotKeys()
        }
    }

    private func handle(_ event: NSEvent) {
        guard let shortcut = activeShortcut else { return }
        if event.keyCode == 53 {
            cancelCapture()
            return
        }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        let keyLabel = Self.label(for: event)
        guard !keyLabel.isEmpty else { return }
        let isFunctionOrNavigationKey = Self.unmodifiedKeyCodes.contains(event.keyCode)
        guard !modifiers.isEmpty || isFunctionOrNavigationKey else {
            errorMessage = L10n.string("请同时按下修饰键，或使用功能键")
            return
        }

        let binding = ShortcutBinding(
            keyCode: event.keyCode,
            modifiers: modifiers.rawValue,
            keyLabel: keyLabel
        )
        guard !shortcut.isGlobal || !binding.isReservedForTextEditing else {
            errorMessage = L10n.format("%@ 用于系统文本编辑，请选择其他快捷键", binding.displayString)
            return
        }
        if let conflict = GlobalShortcut.allCases.first(where: {
            $0 != shortcut && AppSettings.shared.shortcutBinding(for: $0) == binding
        }) {
            errorMessage = L10n.format("快捷键已被 %@ 占用", L10n.string(conflict.titleKey))
            return
        }

        AppSettings.shared.setShortcutBinding(binding, for: shortcut)
        cancelCapture()
    }

    private func stopMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    private static let unmodifiedKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        115, 119, 116, 121, 123, 124, 125, 126
    ]

    private static func label(for event: NSEvent) -> String {
        let functionLabels: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let label = functionLabels[event.keyCode] { return label }
        switch event.keyCode {
        case 36: return "↩"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? ""
        }
    }
}
