import AppKit
import SwiftUI

public final class BorderlessKeyablePanel: NSPanel {
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    override public func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
public final class WindowManager: NSObject, NSWindowDelegate {
    public static let shared = WindowManager()

    private var pillPanel: BorderlessKeyablePanel?
    private var cardPanel: BorderlessKeyablePanel?
    private var vocabWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var lastAnchorPoint: NSPoint = .zero

    private override init() {
        super.init()
        setupSnipasteCallbacks()
    }

    private func setupSnipasteCallbacks() {
        // When user clicks "💬 截图翻译" on the Snipaste Pro Capture Toolbar
        SnipasteCaptureManager.shared.onOCRTranslateImage = { [weak self] image, screenRect in
            guard let self = self else { return }
            self.lastAnchorPoint = CGPoint(x: screenRect.midX, y: screenRect.minY)
            Task { @MainActor in
                let text = await VisionOCRService.shared.recognizeText(in: image)
                let finalText = text.isEmpty ? "（未在截图中识别到文字，可点击「贴图 F3」将此区域钉在屏幕上）" : text
                TranslatorViewModel.shared.startTranslation(
                    text: finalText,
                    mode: .translate,
                    sourceApp: "Snipaste 截图翻译",
                    trigger: .screenshot,
                    image: image
                )
                self.showTranslationCard(atSavedAnchor: true, nearMouse: true)
            }
        }

        // When user clicks "🔍 提字" on the Snipaste Pro Capture Toolbar
        SnipasteCaptureManager.shared.onOCRExtractText = { [weak self] image, screenRect in
            guard let self = self else { return }
            self.lastAnchorPoint = CGPoint(x: screenRect.midX, y: screenRect.minY)
            Task { @MainActor in
                let text = await VisionOCRService.shared.recognizeText(in: image)
                if !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    TranslatorViewModel.shared.preparePillSelection(
                        text: text,
                        sourceApp: "Snipaste OCR 提字",
                        trigger: .screenshot
                    )
                    self.showPillBar(nearMouse: false)
                }
            }
        }
    }

    // MARK: - Stage 1: Show Pill Bar (Image 1)

    public func showPillBar(nearMouse: Bool = true) {
        if pillPanel == nil {
            createPillPanel()
        }
        guard let pill = pillPanel else { return }

        // Hide card if not pinned
        if !TranslatorViewModel.shared.isPinned {
            cardPanel?.orderOut(nil)
        }

        let mouse = NSEvent.mouseLocation
        lastAnchorPoint = mouse

        if nearMouse {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let pSize = pill.frame.size

            var x = mouse.x - pSize.width / 2
            var y = mouse.y - pSize.height - 6 // Pop up right below cursor so it never collides with Zhihu/web top tooltips
            if y < visible.minY + 12 {
                y = mouse.y + 16
            }
            x = max(visible.minX + 8, min(x, visible.maxX - pSize.width - 8))
            pill.setFrameOrigin(NSPoint(x: x, y: y))
        }

        pill.level = .popUpMenu
        pill.orderFrontRegardless()
    }

    public func hidePillBar() {
        pillPanel?.orderOut(nil)
    }

    // MARK: - Stage 2: Show Translation Card (Image 2)

    public func showTranslationCard(atSavedAnchor: Bool = false, nearMouse: Bool = true) {
        hidePillBar()
        if cardPanel == nil {
            createCardPanel()
        }
        guard let card = cardPanel else { return }

        let anchor = atSavedAnchor && lastAnchorPoint != .zero ? lastAnchorPoint : NSEvent.mouseLocation
        if nearMouse && !card.isVisible {
            let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let cSize = card.frame.size

            var x = anchor.x - cSize.width / 2
            var y = anchor.y - cSize.height - 6
            if y < visible.minY + 12 {
                y = min(anchor.y + 18, visible.maxY - cSize.height - 12)
            }
            x = max(visible.minX + 12, min(x, visible.maxX - cSize.width - 12))
            card.setFrameOrigin(NSPoint(x: x, y: y))
        }

        card.level = .floating
        card.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hideTranslationCard() {
        cardPanel?.orderOut(nil)
    }

    public func handleOutsideClick(at screenPoint: NSPoint) {
        if let pill = pillPanel, pill.isVisible {
            if !NSPointInRect(screenPoint, pill.frame) {
                pill.orderOut(nil)
            }
        }
        if let card = cardPanel, card.isVisible, !TranslatorViewModel.shared.isPinned {
            if !NSPointInRect(screenPoint, card.frame) {
                card.orderOut(nil)
            }
        }
    }

    // MARK: - Panel Builders

    private func createPillPanel() {
        let panel = BorderlessKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true

        let view = SelectionPillBarView(
            onSelectAction: { [weak self] mode in
                guard let self = self else { return }
                TranslatorViewModel.shared.startTranslation(mode: mode)
                self.showTranslationCard(atSavedAnchor: true, nearMouse: true)
            },
            onTriggerScreenshot: { [weak self] in
                self?.hidePillBar()
                self?.triggerScreenshotFlow()
            },
            onOpenVocabWindow: { [weak self] in
                self?.hidePillBar()
                self?.showVocabularyWindow()
            },
            onOpenSettingsWindow: { [weak self] in
                self?.hidePillBar()
                self?.showSettingsWindow()
            },
            onDismiss: { [weak self] in
                self?.hidePillBar()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.pillPanel = panel
    }

    private func createCardPanel() {
        let panel = BorderlessKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 476, height: 390),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        let rootView = FloatingTranslatorView(
            onTriggerScreenshot: { [weak self] in
                self?.triggerScreenshotFlow()
            },
            onOpenVocabWindow: { [weak self] in
                self?.showVocabularyWindow()
            },
            onOpenSettingsWindow: { [weak self] in
                self?.showSettingsWindow()
            },
            onClosePanel: { [weak self] in
                self?.hideTranslationCard()
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.cardPanel = panel
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === cardPanel else { return }
        if !TranslatorViewModel.shared.isPinned {
            cardPanel?.orderOut(nil)
        }
    }

    public func triggerScreenshotFlow() {
        hidePillBar()
        if !TranslatorViewModel.shared.isPinned {
            cardPanel?.orderOut(nil)
        }
        SnipasteCaptureManager.shared.startCapture()
    }

    public func triggerPinFlow() {
        // If Snipaste Capture Overlay is currently open, F3 pins the selected region!
        if SnipasteCaptureManager.shared.pinActiveSelectionIfCapturing() {
            return
        }
        // Otherwise F3 pins the current clipboard content (Image / Text / HEX Color) onto the screen!
        SnipastePinManager.shared.pinFromClipboard()
    }

    public func showVocabularyWindow() {
        if vocabWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "SnapLex 语境生词本 (SQLite + Markdown 双写)"
            win.center()
            win.contentView = NSHostingView(rootView: VocabularyBookView())
            win.isReleasedWhenClosed = false
            self.vocabWindow = win
        }
        VocabularyStore.shared.reloadItems()
        vocabWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func showSettingsWindow() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "SnapLex 偏好设置"
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView())
            win.isReleasedWhenClosed = false
            self.settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
