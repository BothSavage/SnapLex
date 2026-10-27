import AppKit
import SwiftUI
import Combine

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var controlPopover: NSPopover?
    private var languageObserver: AnyCancellable?
    private var appearanceObserver: AnyCancellable?
    private var localShortcutMonitor: Any?
    private var explicitQuitRequested = false
    private var instanceLock: SingleInstanceLock?
    private var activationObserver: NSObjectProtocol?
    private static let activationNotification = Notification.Name("io.github.snaplex.activate-existing-instance")

    public static func main() {
        let delegate = AppDelegate()
        // Register before electing the owner so simultaneous launches cannot
        // send their activation request before the owner is listening.
        delegate.activationObserver = DistributedNotificationCenter.default().addObserver(
            forName: activationNotification, object: nil, queue: .main
        ) { [weak delegate] _ in
            Task { @MainActor in
                guard delegate?.instanceLock != nil else { return }
                WindowManager.shared.showDashboard()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        do {
            switch try SingleInstanceLock.acquire(at: SingleInstanceLock.applicationLockURL) {
            case .acquired(let lock):
                delegate.instanceLock = lock
            case .alreadyRunning(let owner):
                if let observer = delegate.activationObserver {
                    DistributedNotificationCenter.default().removeObserver(observer)
                }
                DistributedNotificationCenter.default().postNotificationName(
                    activationNotification, object: nil, userInfo: nil, deliverImmediately: true
                )
                if let owner {
                    NSRunningApplication(processIdentifier: owner)?.activate(options: [.activateAllWindows])
                }
                return
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.string("SnapLex 无法启动")
            alert.informativeText = L10n.string("无法取得应用运行锁，请检查用户目录的访问权限后重试。")
            alert.runModal()
            return
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        if let activationObserver {
            DistributedNotificationCenter.default().removeObserver(activationObserver)
        }
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
        appearanceObserver = AppSettings.shared.$appearanceMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor in
                    self?.controlPopover?.appearance = SnapLexTheme.appKitAppearance(for: mode)
                }
            }
        setupHotKeyCallbacks()
        setupLocalShortcutMonitor()
        EscapeKeyManager.shared.start()
        SelectionAndHotKeyManager.shared.start()
        CaptureManager.shared.prewarm()
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

    func allowTerminationForUpdate() {
        explicitQuitRequested = true
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
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = L10n.string("打开控制台")
        }
        item.menu = nil
        controlPopover = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closeControlPopover()
            let menu = NSMenu()
            let dashboard = NSMenuItem(title: L10n.string("打开控制台"), action: #selector(openDashboardFromMenu), keyEquivalent: "")
            let restart = NSMenuItem(title: L10n.string("重启 SnapLex"), action: #selector(restartApp), keyEquivalent: "")
            let quit = NSMenuItem(title: L10n.string("退出 SnapLex"), action: #selector(quitApp), keyEquivalent: "")
            for item in [dashboard, restart, quit] { item.target = self; menu.addItem(item) }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            return
        }
        toggleControlPopover()
    }

    @objc private func openDashboardFromMenu() {
        WindowManager.shared.showDashboard(section: .home)
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
            popover.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
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
                    },
                    onRestart: { [weak self] in
                        self?.closeControlPopover()
                        self?.restartApp()
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
            if ProcessInfo.processInfo.environment["SNAPLEX_SELECTION_TRACE"] == "1" {
                NSLog("SnapLex selection trace: app presenter received request=%@ trigger=%@ characters=%ld",
                      payload.diagnosticID,
                      payload.trigger.rawValue,
                      payload.text.count)
            }
            TranslatorViewModel.shared.preparePillSelection(
                text: payload.text,
                sourceApp: payload.sourceApp,
                trigger: payload.trigger,
                diagnosticID: payload.diagnosticID
            )
            WindowManager.shared.showPillBar(nearMouse: true, diagnosticID: payload.diagnosticID)
        }

        // Control + Command + A -> Directly open Translation Card
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
            PinManager.shared.restoreLastClosedPin()
        }

        mgr.onTriggerUnlockClickThrough = {
            PinManager.shared.unlockAllClickThroughPins()
        }

        mgr.onTriggerScreenRecorder = {
            ScreenRecorderManager.shared.showAssistant()
        }

        mgr.onTriggerStopRecording = {
            ScreenRecorderManager.shared.stopRecordingAndPromptSave()
        }

        mgr.onTriggerManualPanel = {
            WindowManager.shared.toggleTranslationCard(nearMouse: true, focusInput: true)
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
            guard let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  sourcePID != NSRunningApplication.current.processIdentifier else { return }
            guard let payload = await SelectionAndHotKeyManager.shared.grabCurrentSelection() else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
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
        PinManager.shared.restoreLastClosedPin()
    }

    @objc private func toggleAllPinsVisibility() {
        PinManager.shared.toggleHideAllPins()
    }

    @objc private func closeAllPins() {
        PinManager.shared.closeAllPins()
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

    @objc private func restartApp() {
        // Wait for the old process to exit and release its single-instance lock
        // before asking Launch Services to start the same bundle again.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$2\"", "snaplex-restart", String(getpid()), Bundle.main.bundleURL.path]
        do {
            try helper.run()
            quitApp()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        explicitQuitRequested = true
        NSApp.terminate(nil)
    }
}
