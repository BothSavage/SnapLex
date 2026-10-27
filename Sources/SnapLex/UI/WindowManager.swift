import AppKit
import SwiftUI
import os

private let selectionWindowTraceEnabled = ProcessInfo.processInfo.environment["SNAPLEX_SELECTION_TRACE"] == "1"

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
    private var cardResizeScheduled = false
    private var settingsWindow: NSWindow?
    private var translationHistoryWindow: NSWindow?
    private var screenshotHistoryWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private let selectionLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "Selection"
    )

    public private(set) var isSettingsPinned: Bool = false
    private var lastAnchorPoint: NSPoint = .zero

    var hasVisibleUtilityWindow: Bool {
        [pillPanel, cardPanel, settingsWindow, translationHistoryWindow, screenshotHistoryWindow, dashboardWindow]
            .contains { $0?.isVisible == true }
    }

    public func ownsScreenPoint(_ point: NSPoint) -> Bool {
        let visibleFrames = NSApp.windows.map { window in
            WindowScreenFrame(
                minX: window.frame.minX,
                minY: window.frame.minY,
                maxX: window.frame.maxX,
                maxY: window.frame.maxY,
                isVisible: window.isVisible,
                passesMouseEventsThrough: window.ignoresMouseEvents
            )
        }
        return WindowScreenOwnershipPolicy.owns(
            pointX: point.x,
            pointY: point.y,
            windows: visibleFrames
        )
    }

    private override init() {
        super.init()
        setupCaptureCallbacks()
    }

    private func setupCaptureCallbacks() {
        // When user clicks "翻译" on the Capture Toolbar
        CaptureManager.shared.onOCRTranslateImage = { [weak self] image, screenRect in
            guard let self = self else { return }
            self.lastAnchorPoint = CGPoint(x: screenRect.midX, y: screenRect.minY)
            Task { @MainActor in
                let text = await VisionOCRService.shared.recognizeText(in: image)
                let finalText = text.isEmpty ? L10n.string("（未在截图中识别到文字）") : text
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

        // When user clicks "提取文字" on the Capture Toolbar
        CaptureManager.shared.onOCRExtractText = { [weak self] image, screenRect in
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

    public func showPillBar(nearMouse: Bool = true, diagnosticID: String? = nil) {
        selectionLogger.debug("pill presentation started request=\(diagnosticID ?? "-", privacy: .public) nearMouse=\(nearMouse, privacy: .public) alreadyVisible=\(self.pillPanel?.isVisible == true, privacy: .public)")
        if selectionWindowTraceEnabled {
            NSLog("SnapLex selection trace: pill presentation started request=%@ nearMouse=%@ alreadyVisible=%@",
                  diagnosticID ?? "-",
                  nearMouse ? "yes" : "no",
                  pillPanel?.isVisible == true ? "yes" : "no")
        }
        if pillPanel == nil {
            createPillPanel()
        }
        guard let pill = pillPanel else {
            selectionLogger.error("pill presentation failed request=\(diagnosticID ?? "-", privacy: .public) reason=panel-unavailable")
            if selectionWindowTraceEnabled {
                NSLog("SnapLex selection trace: pill presentation failed request=%@ reason=panel-unavailable", diagnosticID ?? "-")
            }
            return
        }
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
        selectionLogger.info("pill panel ordered front request=\(diagnosticID ?? "-", privacy: .public) visible=\(pill.isVisible, privacy: .public) width=\(Int(pill.frame.width), privacy: .public) height=\(Int(pill.frame.height), privacy: .public)")
        if selectionWindowTraceEnabled {
            NSLog("SnapLex selection trace: pill panel ordered front request=%@ visible=%@ frame=%@",
                  diagnosticID ?? "-",
                  pill.isVisible ? "yes" : "no",
                  NSStringFromRect(pill.frame))
        }
    }

    public func hidePillBar() {
        pillPanel?.orderOut(nil)
    }

    // MARK: - Stage 2: Show Translation Card

    public func showTranslationCard(
        atSavedAnchor: Bool = false,
        nearMouse: Bool = true,
        focusInput: Bool = false,
        diagnosticID: String? = nil
    ) {
        selectionLogger.info("translation card presentation started selectionRequest=\(diagnosticID ?? "-", privacy: .public) nearMouse=\(nearMouse, privacy: .public) focusInput=\(focusInput, privacy: .public) existingVisible=\(self.cardPanel?.isVisible == true, privacy: .public)")
        hidePillBar()
        if cardPanel == nil {
            createCardPanel()
        }
        guard let card = cardPanel else {
            selectionLogger.error("translation card presentation failed selectionRequest=\(diagnosticID ?? "-", privacy: .public) reason=panel-unavailable")
            return
        }
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
        if focusInput {
            card.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Reading a translation must not redirect typing away from the
            // source app. The user can still click the card to edit its input.
            card.orderFrontRegardless()
        }
        selectionLogger.info("translation card ordered front selectionRequest=\(diagnosticID ?? "-", privacy: .public) visible=\(card.isVisible, privacy: .public) focusInput=\(focusInput, privacy: .public) width=\(Int(card.frame.width), privacy: .public) height=\(Int(card.frame.height), privacy: .public)")
    }

    /// Dynamically updates `cardPanel` size when async translation or dictionary text arrives, keeping the top edge anchored.
    public func resizeCardPanelToFitContent() {
        guard !cardResizeScheduled, cardPanel?.contentView != nil else { return }
        cardResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cardResizeScheduled = false
            guard let card = self.cardPanel, let hosting = card.contentView else { return }
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

    public func toggleTranslationCard(nearMouse: Bool = true, focusInput: Bool = true) {
        switch TranslationCardShortcutAction.action(isVisible: cardPanel?.isVisible == true) {
        case .show:
            showTranslationCard(nearMouse: nearMouse, focusInput: focusInput)
        case .hide:
            hideTranslationCard()
        }
    }

    func dismissVisibleUtilityWindow() {
        [pillPanel, cardPanel, settingsWindow, dashboardWindow]
            .compactMap { $0 }
            .first(where: \.isVisible)?
            .orderOut(nil)
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
        panel.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)

        let view = SelectionPillBarView(
            onSelectAction: { [weak self] mode in
                guard let self = self else { return }
                let diagnosticID = TranslatorViewModel.shared.startPillSelectionTranslation(mode: mode)
                self.showTranslationCard(atSavedAnchor: true, nearMouse: true, diagnosticID: diagnosticID)
            },
            onTriggerScreenshot: { [weak self] in
                self?.hidePillBar()
                self?.triggerScreenshotFlow()
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
        panel.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
        panel.delegate = self

        let rootView = FloatingTranslatorView(
            onTriggerScreenshot: { [weak self] in
                self?.triggerScreenshotFlow()
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

        // The dashboard is a normal app window, so the capture overlay would
        // otherwise freeze it as part of the screenshot. Let WindowServer commit
        // the hide before taking the desktop snapshot.
        let dismissDashboardFirst = dashboardWindow?.isVisible == true
        dashboardWindow?.orderOut(nil)

        if dismissDashboardFirst {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                CaptureManager.shared.startCapture()
            }
        } else {
            CaptureManager.shared.startCapture()
        }
    }

    public func triggerPinFlow() {
        if CaptureManager.shared.pinActiveSelectionIfCapturing() {
            return
        }
        PinManager.shared.pinFromClipboard()
    }

    public func showTranslationHistoryWindow() {
        showDashboard(section: .translations)
    }

    public func showScreenshotHistoryWindow() {
        showDashboard(section: .screenshots)
    }

    public func setSettingsPinned(_ pinned: Bool) {
        self.isSettingsPinned = pinned
        settingsWindow?.level = pinned ? .floating : .normal
    }

    public func showSettingsWindow() {
        showDashboard(section: .preferences)
    }

    public func showDashboard(section: DashboardSection = .home) {
        DashboardNavigation.shared.select(section)
        if dashboardWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "SnapLex"
            win.minSize = NSSize(width: 1080, height: 720)
            win.center()
            win.backgroundColor = .windowBackgroundColor
            win.appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
            win.contentView = NSHostingView(rootView: DashboardView())
            win.isReleasedWhenClosed = false
            win.delegate = self
            dashboardWindow = win
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hideDashboard() {
        dashboardWindow?.orderOut(nil)
    }

    public func applyAppearance() {
        let appearance = SnapLexTheme.appKitAppearance(for: AppSettings.shared.appearanceMode)
        [pillPanel, cardPanel, settingsWindow, translationHistoryWindow, screenshotHistoryWindow, dashboardWindow]
            .forEach { $0?.appearance = appearance }
        CaptureManager.shared.applyAppearance(appearance)
        PinManager.shared.applyAppearance(appearance)
        ScrollingCaptureEngine.shared.applyAppearance(appearance)
        ScreenRecorderManager.shared.applyAppearance(appearance)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === dashboardWindow else { return true }
        sender.orderOut(nil)
        return false
    }
}
