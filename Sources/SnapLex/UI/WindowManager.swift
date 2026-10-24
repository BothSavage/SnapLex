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

    public private(set) var isSettingsPinned: Bool = false
    private var lastAnchorPoint: NSPoint = .zero

    private override init() {
        super.init()
        setupSnipasteCallbacks()
    }

    private func setupSnipasteCallbacks() {
        // When user clicks "翻译" on the Snipaste Capture Toolbar
        SnipasteCaptureManager.shared.onOCRTranslateImage = { [weak self] image, screenRect in
            guard let self = self else { return }
            self.lastAnchorPoint = CGPoint(x: screenRect.midX, y: screenRect.minY)
            Task { @MainActor in
                let text = await VisionOCRService.shared.recognizeText(in: image)
                let finalText = text.isEmpty ? "（未在截图中识别到文字）" : text
                TranslatorViewModel.shared.startTranslation(
                    text: finalText,
                    mode: .translate,
                    sourceApp: "截图翻译",
                    trigger: .screenshot,
                    image: image
                )
                self.showTranslationCard(atSavedAnchor: true, nearMouse: true)
            }
        }

        // When user clicks "提取文字" on the Snipaste Capture Toolbar
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
                        sourceApp: "OCR 提字",
                        trigger: .screenshot
                    )
                    self.showPillBar(nearMouse: false)
                }
            }
        }
    }

    // MARK: - Stage 1: Show Pill Bar

    public func showPillBar(nearMouse: Bool = true) {
        if pillPanel == nil {
            createPillPanel()
        }
        guard let pill = pillPanel else { return }
        if let hosting = pill.contentView {
            hosting.invalidateIntrinsicContentSize()
            hosting.layoutSubtreeIfNeeded()
            pill.setContentSize(hosting.fittingSize)
        }

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
            var y = mouse.y - pSize.height - 6
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

    // MARK: - Stage 2: Show Translation Card

    public func showTranslationCard(atSavedAnchor: Bool = false, nearMouse: Bool = true) {
        hidePillBar()
        if cardPanel == nil {
            createCardPanel()
        }
        guard let card = cardPanel else { return }
        if let hosting = card.contentView {
            hosting.invalidateIntrinsicContentSize()
            hosting.layoutSubtreeIfNeeded()
            card.setContentSize(hosting.fittingSize)
        }

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
        } else if !nearMouse && !card.isVisible {
            card.center()
        }

        card.level = .floating
        card.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dynamically updates `cardPanel` size when async translation or dictionary text arrives, keeping the top edge anchored.
    public func resizeCardPanelToFitContent() {
        guard let card = cardPanel, let hosting = card.contentView else { return }
        DispatchQueue.main.async {
            hosting.invalidateIntrinsicContentSize()
            hosting.layoutSubtreeIfNeeded()
            let newSize = hosting.fittingSize
            guard newSize.width > 50, newSize.height > 50 else { return }

            let oldFrame = card.frame
            guard abs(oldFrame.width - newSize.width) > 1 || abs(oldFrame.height - newSize.height) > 1 else { return }

            let screen = card.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            // Keep top-left corner stable while growing/shrinking downward, clamped to visible screen bounds
            let topY = oldFrame.maxY
            var newOriginY = topY - newSize.height
            if newOriginY < visible.minY + 12 {
                newOriginY = visible.minY + 12
            }
            if newOriginY + newSize.height > visible.maxY - 12 {
                newOriginY = max(visible.minY + 12, visible.maxY - newSize.height - 12)
            }
            let newOriginX = max(visible.minX + 12, min(oldFrame.origin.x, visible.maxX - newSize.width - 12))

            card.setFrame(
                NSRect(x: newOriginX, y: newOriginY, width: newSize.width, height: newSize.height),
                display: true,
                animate: false
            )
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
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
            contentRect: NSRect(x: 0, y: 0, width: 512, height: 320),
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
        if SnipasteCaptureManager.shared.pinActiveSelectionIfCapturing() {
            return
        }
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
            win.title = "SnapLex 生词本"
            win.center()
            win.contentView = NSHostingView(rootView: VocabularyBookView())
            win.isReleasedWhenClosed = false
            self.vocabWindow = win
        }
        VocabularyStore.shared.reloadItems()
        vocabWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func setSettingsPinned(_ pinned: Bool) {
        self.isSettingsPinned = pinned
        settingsWindow?.level = pinned ? .floating : .normal
    }

    public func showSettingsWindow() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "SnapLex 偏好设置"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            win.minSize = NSSize(width: 500, height: 420)
            win.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
            win.appearance = NSAppearance(named: .darkAqua)
            win.level = isSettingsPinned ? .floating : .normal
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView())
            win.isReleasedWhenClosed = false
            self.settingsWindow = win
        }
        settingsWindow?.level = isSettingsPinned ? .floating : .normal
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
