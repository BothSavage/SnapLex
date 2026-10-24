import Foundation
import AppKit
import Carbon
import ApplicationServices

public struct SelectedTextPayload {
    public let text: String
    public let sourceApp: String
    public let trigger: TranslationTriggerSource
}

@MainActor
public final class SelectionAndHotKeyManager: ObservableObject {
    public static let shared = SelectionAndHotKeyManager()

    @Published public var isAXTrusted: Bool = AXIsProcessTrusted()

    /// Fired when mouse drag-select or double Cmd+C triggers popup
    public var onShowSelectionPopup: ((SelectedTextPayload) -> Void)?
    /// Fired when hotkey Option+A triggers the Image 2 Translation Card directly
    public var onTriggerDirectTranslateCard: ((SelectedTextPayload) -> Void)?
    /// Fired when F1 or Option+S triggers Snipaste Pro Capture & Annotation Overlay
    public var onTriggerScreenshot: (() -> Void)?
    /// Fired when F3 or Option+P triggers Snipaste Pro Pin-to-Screen
    public var onTriggerPinToScreen: (() -> Void)?
    /// Fired when Shift+F3 restores last closed Pin
    public var onTriggerRestoreLastPin: (() -> Void)?
    /// Fired when Option+X unlocks all Click-Through Pin windows
    public var onTriggerUnlockClickThrough: (() -> Void)?
    /// Fired when Option+R opens the Screen Recorder Assistant
    public var onTriggerScreenRecorder: (() -> Void)?
    /// Fired when F10 stops active screen recording
    public var onTriggerStopRecording: (() -> Void)?
    public var onTriggerManualPanel: (() -> Void)?
    public var onOutsideMouseDown: ((NSPoint) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?
    private var directTranslationTask: Task<Void, Never>?

    // Mouse drag selection state
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownTime: TimeInterval = 0
    private var mouseDownWasInsideSnapLexWindow = false
    private var lastAutoPopupText: String = ""
    private var lastAutoPopupTime: TimeInterval = 0

    // Double Cmd+C & AX trust monitor
    private var pasteboardTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastCopyTimestamp: TimeInterval = 0
    private var lastCopiedString: String = ""
    private var ignoreNextChangeCount: Bool = false

    private init() {}

    public func start() {
        isAXTrusted = isAccessibilityTrusted(prompt: false)
        if !isAXTrusted {
            // Prompt macOS system Accessibility dialog on launch so mouse-select works immediately
            _ = isAccessibilityTrusted(prompt: true)
        }
        registerCarbonHotKeys()
        startPasteboardAndTrustMonitor()
        startGlobalMouseMonitors()
    }

    public func openSystemAccessibilitySettings() {
        _ = isAccessibilityTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility Check

    public nonisolated func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Global Mouse Selection Monitor (Works in Chrome / Safari / Zhihu / PDF / IDE)

    private func startGlobalMouseMonitors() {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let pt = NSEvent.mouseLocation
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self = self else { return }
                self.mouseDownPoint = pt
                self.mouseDownTime = now
                self.mouseDownWasInsideSnapLexWindow = WindowManager.shared.ownsScreenPoint(pt)
                self.onOutsideMouseDown?(pt)
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            let upPoint = NSEvent.mouseLocation
            let clickCount = event.clickCount
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self = self else { return }
                guard AppSettings.shared.enableMouseHoverBar else { return }
                guard !self.mouseDownWasInsideSnapLexWindow,
                      !WindowManager.shared.ownsScreenPoint(upPoint) else { return }

                // Ignore clicks inside SnapLex itself
                guard let sourceApplication = NSWorkspace.shared.frontmostApplication,
                      sourceApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    return
                }

                let dx = hypot(upPoint.x - self.mouseDownPoint.x, upPoint.y - self.mouseDownPoint.y)
                let duration = now - self.mouseDownTime
                let isDragSelect = (dx >= 10 && duration >= 0.05 && duration <= 12.0)
                let isMultiClickSelect = (clickCount == 2 || clickCount == 3)

                guard isDragSelect || isMultiClickSelect else { return }

                // Text editing and caret/selection gestures inside input controls
                // must remain owned by the target app. Showing our pill there
                // steals focus from search boxes, chat composers and editors.
                guard !self.isEditableTextFocused(in: sourceApplication.processIdentifier) else { return }

                let downPt = self.mouseDownPoint
                try? await Task.sleep(nanoseconds: 75_000_000) // Wait 75ms for browser/app selection to settle

                // Don't let an async AX read from the previous app open a pill
                // after the user has already switched windows.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourceApplication.processIdentifier else {
                    return
                }

                if let selected = await self.extractSelectionAfterMouseUp(downPoint: downPt, upPoint: upPoint, isDrag: isDragSelect),
                   !selected.isEmpty,
                   selected.count <= 4000 {
                    // Avoid re-popping identical selection if user just clicked once
                    if !isDragSelect && !isMultiClickSelect && selected == self.lastAutoPopupText && (now - self.lastAutoPopupTime) < 1.0 {
                        return
                    }
                    self.lastAutoPopupText = selected
                    self.lastAutoPopupTime = now
                    let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
                    self.onShowSelectionPopup?(
                        SelectedTextPayload(text: selected, sourceApp: appName, trigger: .mouseSelect)
                    )
                }
            }
        }
    }

    /// Multi-tier selection extraction:
    /// Tier 1: Enable AXManualAccessibility/AXEnhancedUserInterface on target PID (required for Chrome/Arc/Edge/Electron) & read kAXSelectedTextAttribute
    /// Tier 2: Hit-test element at mouse position via AXUIElementCopyElementAtPosition & read kAXSelectedTextAttribute
    /// Tier 3: Non-destructive synthetic Cmd+C fallback (captures selection in any web/PDF/canvas app when AX attribute isn't exposed)
    private func extractSelectionAfterMouseUp(downPoint: NSPoint, upPoint: NSPoint, isDrag: Bool) async -> String? {
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            enableChromiumAccessibility(pid: frontApp.processIdentifier)
        }

        if let selectedText = await readSelectedTextWithRetries(at: upPoint) {
            return selectedText
        }

        // Tier 3: Synthetic Cmd+C fallback (works in 100% of browsers & apps even before Chrome finishes building its AX tree)
        let pb = NSPasteboard.general
        let prevCount = pb.changeCount
        ignoreNextChangeCount = true
        simulateCmdC()

        try? await Task.sleep(nanoseconds: 85_000_000) // 85ms wait for pasteboard update
        defer { ignoreNextChangeCount = false }

        if pb.changeCount != prevCount,
           let copied = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !copied.isEmpty {
            lastChangeCount = pb.changeCount
            return copied
        }

        return nil
    }

    private func enableChromiumAccessibility(pid: pid_t) {
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElem, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElem, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Accessibility selection can lag the mouse-up event, especially on the first
    /// interaction after an app becomes active. Retry focused and hit-tested AX
    /// reads briefly before falling back to synthetic copy.
    private func readSelectedTextWithRetries(at point: NSPoint?) async -> String? {
        guard isAccessibilityTrusted(prompt: false) else { return nil }

        for attempt in 0..<3 {
            if let text = readSelectedTextViaAX()?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if let point,
               let text = readSelectedTextAtPosition(point)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
        }
        return nil
    }

    private func readSelectedTextAtPosition(_ cocoaPoint: NSPoint) -> String? {
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return nil }
        // Accessibility uses top-left screen origin
        let cgX = Float(cocoaPoint.x)
        let cgY = Float(mainScreenHeight - cocoaPoint.y)

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, cgX, cgY, &hitElement)
        guard err == .success, let elem = hitElement else { return nil }

        var current: AXUIElement? = elem
        for _ in 0..<5 {
            guard let target = current else { break }
            var selectedText: CFTypeRef?
            if AXUIElementCopyAttributeValue(target, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
               let str = selectedText as? String,
               !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str
            }
            var parent: CFTypeRef?
            if AXUIElementCopyAttributeValue(target, kAXParentAttribute as CFString, &parent) == .success,
               let p = axElement(from: parent) {
                current = p
            } else {
                break
            }
        }
        return nil
    }

    private func isEditableTextFocused(in processIdentifier: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focused = axElement(from: focusedValue) else {
            return false
        }

        var current: AXUIElement? = focused
        for _ in 0..<8 {
            guard let element = current else { break }

            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String,
               ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField", "AXTextEntryArea"].contains(role) {
                return true
            }

            var editableAncestor: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editableAncestor) == .success,
               axElement(from: editableAncestor) != nil {
                return true
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = axElement(from: parentValue) else {
                break
            }
            current = parent
        }
        return false
    }

    // MARK: - Grab Selected Text for Hotkey Option+A

    public func grabCurrentSelection() async -> SelectedTextPayload? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "macOS"
        if let pid = frontApp?.processIdentifier {
            enableChromiumAccessibility(pid: pid)
        }

        if let axText = await readSelectedTextWithRetries(at: NSEvent.mouseLocation) {
            return SelectedTextPayload(
                text: axText,
                sourceApp: appName,
                trigger: .selection
            )
        }

        if isAccessibilityTrusted(prompt: false) {
            let pb = NSPasteboard.general
            let prevCount = pb.changeCount
            ignoreNextChangeCount = true
            simulateCmdC()

            try? await Task.sleep(nanoseconds: 90_000_000)
            if pb.changeCount != prevCount,
               let copied = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !copied.isEmpty {
                lastChangeCount = pb.changeCount
                ignoreNextChangeCount = false
                return SelectedTextPayload(text: copied, sourceApp: appName, trigger: .selection)
            }
            ignoreNextChangeCount = false
        }

        return nil
    }

    private func readSelectedTextViaAX() -> String? {
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedInApp: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedInApp) == .success,
               let element = axElement(from: focusedInApp) {
                var selectedText: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
                   let str = selectedText as? String,
                   !str.isEmpty {
                    return str
                }
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard err == .success, let element = axElement(from: focusedElement) else { return nil }

        var selectedText: CFTypeRef?
        let textErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText)
        if textErr == .success, let str = selectedText as? String {
            return str
        }
        return nil
    }

    private func axElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private func simulateCmdC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyCDown?.flags = .maskCommand
        let keyCUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyCUp?.flags = .maskCommand

        keyCDown?.post(tap: .cghidEventTap)
        keyCUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Double Cmd+C & AX Trust Polling

    private func startPasteboardAndTrustMonitor() {
        lastChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let currentTrust = self.isAccessibilityTrusted(prompt: false)
                if currentTrust != self.isAXTrusted {
                    self.isAXTrusted = currentTrust
                }
                self.checkPasteboardChange()
            }
        }
    }

    private func checkPasteboardChange() {
        guard AppSettings.shared.enableDoubleCmdC else { return }
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if ignoreNextChangeCount {
            return
        }

        guard let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastCopyTimestamp

        if delta <= 0.60 && str == lastCopiedString {
            lastCopyTimestamp = 0
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
                  !WindowManager.shared.ownsScreenPoint(NSEvent.mouseLocation),
                  !isEditableTextFocused(in: frontmost.processIdentifier) else {
                return
            }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
            onShowSelectionPopup?(SelectedTextPayload(text: str, sourceApp: appName, trigger: .doubleCopy))
        } else {
            lastCopyTimestamp = now
            lastCopiedString = str
        }
    }

    // MARK: - Carbon Global HotKeys (Option+A, Option+S, Option+D)

    private func registerCarbonHotKeys() {
        unregisterCarbonHotKeys()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        if eventHandlerRef == nil {
            let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
                guard let eventRef = eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    let id = hotKeyID.id
                    Task { @MainActor in
                        SelectionAndHotKeyManager.shared.handleHotKey(id: id)
                    }
                }
                return noErr
            }

            InstallEventHandler(
                GetApplicationEventTarget(),
                handler,
                1,
                &eventType,
                nil,
                &eventHandlerRef
            )
        }

        let signature = OSType(0x534C_4558)
        for shortcut in GlobalShortcut.allCases where shortcut.isGlobal {
            guard let eventID = shortcut.eventID else { continue }
            registerSingleHotKey(
                id: eventID,
                signature: signature,
                binding: AppSettings.shared.shortcutBinding(for: shortcut)
            )
        }
    }

    public func refreshHotKeys() {
        guard eventHandlerRef != nil else { return }
        registerCarbonHotKeys()
    }

    private func unregisterCarbonHotKeys() {
        for hotKey in hotKeyRefs {
            if let hotKey { UnregisterEventHotKey(hotKey) }
        }
        hotKeyRefs.removeAll()
    }

    private func registerSingleHotKey(id: UInt32, signature: OSType, binding: ShortcutBinding) {
        guard !binding.isReservedForTextEditing else { return }
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRefs.append(ref)
        }
    }

    private func handleHotKey(id: UInt32) {
        guard !ShortcutRecorderController.shared.isCapturing else { return }
        switch id {
        case 1:
            // Synthetic Cmd+C must never re-enter selection translation. Keep
            // only one extraction pending, and don't show a stale/empty card
            // when there is no current selection.
            guard !ignoreNextChangeCount, directTranslationTask == nil else { return }
            let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            directTranslationTask = Task { [weak self] in
                guard let self else { return }
                defer { self.directTranslationTask = nil }
                guard let payload = await self.grabCurrentSelection(),
                      !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
                self.onTriggerDirectTranslateCard?(payload)
            }
        case 2, 4:
            onTriggerScreenshot?()
        case 3:
            onTriggerManualPanel?()
        case 5, 6:
            onTriggerPinToScreen?()
        case 7:
            onTriggerRestoreLastPin?()
        case 8:
            onTriggerUnlockClickThrough?()
        case 9:
            onTriggerScreenRecorder?()
        case 10:
            onTriggerStopRecording?()
        default:
            break
        }
    }
}
