import AppKit
import SwiftUI
import Combine

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controlPopover: NSPopover?
    private var languageObserver: AnyCancellable?
    private var localShortcutMonitor: Any?
    private var explicitQuitRequested = false

    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        setupStatusBarMenu()
        languageObserver = AppSettings.shared.$appLanguage
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.setupStatusBarMenu() }
            }
        setupHotKeyCallbacks()
        setupLocalShortcutMonitor()
        EscapeKeyManager.shared.start()
        SelectionAndHotKeyManager.shared.start()
        SnipasteCaptureManager.shared.prewarm()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowManager.shared.showDashboard()
        }
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !explicitQuitRequested else { return .terminateNow }
        WindowManager.shared.hideDashboard()
        return .terminateCancel
    }

    private func setupStatusBarMenu() {
        let item: NSStatusItem
        if let statusItem {
            item = statusItem
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
        }
        if let button = item.button {
            button.image = SnapLexBrandLogo.makeMenuBarImage()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggleControlPopover)
            button.toolTip = L10n.string("打开控制台")
        }
        item.menu = nil
        controlPopover = nil
    }

    @objc private func toggleControlPopover() {
        guard let button = statusItem?.button else { return }
        if let controlPopover, controlPopover.isShown {
            controlPopover.performClose(nil)
            return
        }

        if controlPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 360, height: 600)
            popover.contentViewController = NSHostingController(
                rootView: ControlPanelPopoverView(
                    onScreenshot: { [weak self] in
                        self?.closeControlPopover()
                        WindowManager.shared.triggerScreenshotFlow()
                    },
                    onRecord: { [weak self] in
                        self?.closeControlPopover()
                        ScreenRecorderManager.shared.showAssistant()
                    },
                    onPinClipboard: { [weak self] in
                        self?.closeControlPopover()
                        WindowManager.shared.triggerPinFlow()
                    },
                    onOpenDashboard: { [weak self] section in
                        self?.closeControlPopover()
                        WindowManager.shared.showDashboard(section: section)
                    },
                    onQuit: { [weak self] in
                        self?.closeControlPopover()
                        self?.quitApp()
                    }
                )
            )
            controlPopover = popover
        }

        controlPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closeControlPopover() {
        controlPopover?.performClose(nil)
    }

    private func setupLocalShortcutMonitor() {
        guard localShortcutMonitor == nil else { return }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  !ShortcutRecorderController.shared.isCapturing,
                  let shortcut = GlobalShortcut.allCases.first(where: { !$0.isGlobal && self.matches(event, shortcut: $0) }) else {
                return event
            }
            switch shortcut {
            case .openSettings:
                self.openSettings()
            case .quitApp:
                WindowManager.shared.hideDashboard()
            default:
                break
            }
            return nil
        }
    }

    private func matches(_ event: NSEvent, shortcut: GlobalShortcut) -> Bool {
        let binding = AppSettings.shared.shortcutBinding(for: shortcut)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let relevantFlags = flags.intersection([.command, .option, .control, .shift])
        return event.keyCode == binding.keyCode && relevantFlags.rawValue == binding.modifiers
    }

    private func setupHotKeyCallbacks() {
        let mgr = SelectionAndHotKeyManager.shared

        // Mouse drag selection or Double Cmd+C -> Show Pill Bar
        mgr.onShowSelectionPopup = { payload in
            TranslatorViewModel.shared.preparePillSelection(
                text: payload.text,
                sourceApp: payload.sourceApp,
                trigger: payload.trigger
            )
            WindowManager.shared.showPillBar(nearMouse: true)
        }

        // Option + A -> Directly open Translation Card
        mgr.onTriggerDirectTranslateCard = { payload in
            TranslatorViewModel.shared.startTranslation(
                text: payload.text,
                mode: .translate,
                sourceApp: payload.sourceApp,
                trigger: payload.trigger
            )
            WindowManager.shared.showTranslationCard(nearMouse: true)
        }

        mgr.onTriggerScreenshot = {
            WindowManager.shared.triggerScreenshotFlow()
        }

        mgr.onTriggerPinToScreen = {
            WindowManager.shared.triggerPinFlow()
        }

        mgr.onTriggerRestoreLastPin = {
            SnipastePinManager.shared.restoreLastClosedPin()
        }

        mgr.onTriggerUnlockClickThrough = {
            SnipastePinManager.shared.unlockAllClickThroughPins()
        }

        mgr.onTriggerScreenRecorder = {
            ScreenRecorderManager.shared.showAssistant()
        }

        mgr.onTriggerStopRecording = {
            ScreenRecorderManager.shared.stopRecordingAndPromptSave()
        }

        mgr.onTriggerManualPanel = {
            WindowManager.shared.showTranslationCard(nearMouse: true, focusInput: true)
        }

        mgr.onOutsideMouseDown = { pt in
            WindowManager.shared.handleOutsideClick(at: pt)
        }
    }

    @objc private func previewPillBar() {
        TranslatorViewModel.shared.preparePillSelection(
            text: L10n.string("SnapLex 极简划词控制栏"),
            sourceApp: "SnapLex",
            trigger: .mouseSelect
        )
        WindowManager.shared.showPillBar(nearMouse: true)
    }

    @objc private func triggerSelectionTranslate() {
        Task { @MainActor in
            guard let payload = await SelectionAndHotKeyManager.shared.grabCurrentSelection() else { return }
            TranslatorViewModel.shared.startTranslation(
                text: payload.text,
                mode: .translate,
                sourceApp: payload.sourceApp,
                trigger: payload.trigger
            )
            WindowManager.shared.showTranslationCard(nearMouse: true)
        }
    }

    @objc private func triggerScreenshotTranslate() {
        WindowManager.shared.triggerScreenshotFlow()
    }

    @objc private func openScreenRecorder() {
        ScreenRecorderManager.shared.showAssistant()
    }

    @objc private func triggerPinClipboard() {
        WindowManager.shared.triggerPinFlow()
    }

    @objc private func restoreLastClosedPin() {
        SnipastePinManager.shared.restoreLastClosedPin()
    }

    @objc private func toggleAllPinsVisibility() {
        SnipastePinManager.shared.toggleHideAllPins()
    }

    @objc private func closeAllPins() {
        SnipastePinManager.shared.closeAllPins()
    }

    @objc private func openFloatingCard() {
        WindowManager.shared.showTranslationCard(nearMouse: false, focusInput: true)
    }

    @objc private func openSettings() {
        WindowManager.shared.showSettingsWindow()
    }

    @objc private func openTranslationHistory() {
        WindowManager.shared.showTranslationHistoryWindow()
    }

    @objc private func openScreenshotHistory() {
        WindowManager.shared.showScreenshotHistoryWindow()
    }

    @objc private func quitApp() {
        explicitQuitRequested = true
        NSApp.terminate(nil)
    }
}
