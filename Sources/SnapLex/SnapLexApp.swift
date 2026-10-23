import AppKit
import SwiftUI

@main
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarMenu()
        setupHotKeyCallbacks()
        SelectionAndHotKeyManager.shared.start()
        SnipasteCaptureManager.shared.prewarm()

        // Show initial demo matching the user's screenshot
        TranslatorViewModel.shared.startTranslation(
            text: "改一个变量 → 编译部署 → 跑 Benchmark 测 TTFT/RTF → 校验输出精度有没有崩（Exact/Soft Match） → 有效就保留 Git 分支，无效就回滚，写实验日志（从 v001 一直写到 v054）",
            mode: .translate,
            sourceApp: "SnapLex",
            trigger: .manual
        )
        WindowManager.shared.showTranslationCard(nearMouse: false)
    }

    private func setupStatusBarMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: "SnapLex")
            button.title = " SnapLex"
        }

        let menu = NSMenu()

        let pillDemoItem = NSMenuItem(title: "预览划词悬浮条 (图1效果)", action: #selector(previewPillBar), keyEquivalent: "")
        menu.addItem(pillDemoItem)

        let selectionItem = NSMenuItem(title: "划词直接翻译 (⌥ + A)", action: #selector(triggerSelectionTranslate), keyEquivalent: "a")
        selectionItem.keyEquivalentModifierMask = [.option]
        menu.addItem(selectionItem)

        let panelItem = NSMenuItem(title: "打开翻译卡片 (⌥ + D)", action: #selector(openFloatingCard), keyEquivalent: "d")
        panelItem.keyEquivalentModifierMask = [.option]
        menu.addItem(panelItem)

        menu.addItem(.separator())

        let screenshotItem = NSMenuItem(title: "Snipaste 截图 · 标注 · 取色 · 翻译 (F1 / ⌥+S)", action: #selector(triggerScreenshotTranslate), keyEquivalent: "s")
        screenshotItem.keyEquivalentModifierMask = [.option]
        menu.addItem(screenshotItem)

        let recorderItem = NSMenuItem(title: "🎥 录屏助手 · 导出 GIF / MP4 (⌥ + R)", action: #selector(openScreenRecorder), keyEquivalent: "r")
        recorderItem.keyEquivalentModifierMask = [.option]
        menu.addItem(recorderItem)

        let pinClipboardItem = NSMenuItem(title: "Snipaste 剪贴板贴图 Pin to Screen (F3 / ⌥+P)", action: #selector(triggerPinClipboard), keyEquivalent: "p")
        pinClipboardItem.keyEquivalentModifierMask = [.option]
        menu.addItem(pinClipboardItem)

        let restorePinItem = NSMenuItem(title: "恢复上一个关闭的贴图 (⇧ + F3)", action: #selector(restoreLastClosedPin), keyEquivalent: "")
        menu.addItem(restorePinItem)

        let togglePinsItem = NSMenuItem(title: "隐藏 / 显示所有桌面贴图", action: #selector(toggleAllPinsVisibility), keyEquivalent: "")
        menu.addItem(togglePinsItem)

        let unlockGhostItem = NSMenuItem(title: "解除所有贴图的「鼠标穿透」锁定", action: #selector(unlockClickThroughPins), keyEquivalent: "")
        menu.addItem(unlockGhostItem)

        let closeAllPinsItem = NSMenuItem(title: "清空所有桌面贴图", action: #selector(closeAllPins), keyEquivalent: "")
        menu.addItem(closeAllPinsItem)

        menu.addItem(.separator())

        let vocabItem = NSMenuItem(title: "打开语境生词本...", action: #selector(openVocabularyBook), keyEquivalent: "b")
        vocabItem.keyEquivalentModifierMask = [.command]
        menu.addItem(vocabItem)

        let openMdItem = NSMenuItem(title: "在 Finder 中查看 Vocabulary.md", action: #selector(revealMarkdownFile), keyEquivalent: "")
        menu.addItem(openMdItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置 (划词权限 / API / 双写路径)...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 SnapLex", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    private func setupHotKeyCallbacks() {
        let mgr = SelectionAndHotKeyManager.shared

        // Mouse drag selection or Double Cmd+C -> Show Image 1 Pill Bar!
        mgr.onShowSelectionPopup = { payload in
            TranslatorViewModel.shared.preparePillSelection(
                text: payload.text,
                sourceApp: payload.sourceApp,
                trigger: payload.trigger
            )
            WindowManager.shared.showPillBar(nearMouse: true)
        }

        // Option + A -> Directly open Image 2 Translation Card!
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
            WindowManager.shared.showTranslationCard(nearMouse: true)
        }

        mgr.onOutsideMouseDown = { pt in
            WindowManager.shared.handleOutsideClick(at: pt)
        }
    }

    @objc private func previewPillBar() {
        TranslatorViewModel.shared.preparePillSelection(
            text: "本地合成的试听音轨",
            sourceApp: "SnapLex",
            trigger: .mouseSelect
        )
        WindowManager.shared.showPillBar(nearMouse: true)
    }

    @objc private func triggerSelectionTranslate() {
        Task { @MainActor in
            if let payload = await SelectionAndHotKeyManager.shared.grabCurrentSelection() {
                TranslatorViewModel.shared.startTranslation(
                    text: payload.text,
                    mode: .translate,
                    sourceApp: payload.sourceApp,
                    trigger: payload.trigger
                )
            }
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

    @objc private func unlockClickThroughPins() {
        SnipastePinManager.shared.unlockAllClickThroughPins()
    }

    @objc private func closeAllPins() {
        SnipastePinManager.shared.closeAllPins()
    }

    @objc private func openFloatingCard() {
        WindowManager.shared.showTranslationCard(nearMouse: false)
    }

    @objc private func openVocabularyBook() {
        WindowManager.shared.showVocabularyWindow()
    }

    @objc private func revealMarkdownFile() {
        let store = VocabularyStore.shared
        store.syncMarkdownFile()
        NSWorkspace.shared.selectFile(store.markdownFilePath, inFileViewerRootedAtPath: AppSettings.shared.markdownExportDir)
    }

    @objc private func openSettings() {
        WindowManager.shared.showSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
