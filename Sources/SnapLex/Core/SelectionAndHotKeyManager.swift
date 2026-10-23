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

    // Mouse drag selection state
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownTime: TimeInterval = 0
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

                // Ignore clicks inside SnapLex itself
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
                    return
                }

                let dx = hypot(upPoint.x - self.mouseDownPoint.x, upPoint.y - self.mouseDownPoint.y)
                let duration = now - self.mouseDownTime
                let isDragSelect = (dx >= 10 && duration >= 0.05 && duration <= 12.0)
                let isMultiClickSelect = (clickCount == 2 || clickCount == 3)

                guard isDragSelect || isMultiClickSelect else { return }

                let downPt = self.mouseDownPoint
                try? await Task.sleep(nanoseconds: 75_000_000) // Wait 75ms for browser/app selection to settle

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
        guard isAccessibilityTrusted(prompt: false) else { return nil }

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            enableChromiumAccessibility(pid: frontApp.processIdentifier)
        }

        // Tier 1: Focused element AXSelectedText
        if let axText = readSelectedTextViaAX()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !axText.isEmpty {
            return axText
        }

        // Tier 2: Element at mouse position AXSelectedText
        if let hitText = readSelectedTextAtPosition(upPoint)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hitText.isEmpty {
            return hitText
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
               let p = parent {
                current = (p as! AXUIElement)
            } else {
                break
            }
        }
        return nil
    }

    // MARK: - Grab Selected Text for Hotkey Option+A

    public func grabCurrentSelection() async -> SelectedTextPayload? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "macOS"
        if let pid = frontApp?.processIdentifier {
            enableChromiumAccessibility(pid: pid)
        }

        if let axText = readSelectedTextViaAX(), !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SelectedTextPayload(
                text: axText.trimmingCharacters(in: .whitespacesAndNewlines),
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

        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clip.isEmpty {
            return SelectedTextPayload(text: clip, sourceApp: appName, trigger: .selection)
        }

        return nil
    }

    private func readSelectedTextViaAX() -> String? {
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedInApp: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedInApp) == .success,
               let element = focusedInApp {
                var selectedText: CFTypeRef?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
                   let str = selectedText as? String,
                   !str.isEmpty {
                    return str
                }
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard err == .success, let element = focusedElement else { return nil }

        var selectedText: CFTypeRef?
        let textErr = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)
        if textErr == .success, let str = selectedText as? String {
            return str
        }
        return nil
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
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "macOS"
            onShowSelectionPopup?(SelectedTextPayload(text: str, sourceApp: appName, trigger: .doubleCopy))
        } else {
            lastCopyTimestamp = now
            lastCopiedString = str
        }
    }

    // MARK: - Carbon Global HotKeys (Option+A, Option+S, Option+D)

    private func registerCarbonHotKeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

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

                let signature = OSType(0x534C_4558)
        // 1: Option + A (Selection Translate)
        registerSingleHotKey(id: 1, signature: signature, keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        // 2: Option + S (Snipaste Capture + OCR Translate)
        registerSingleHotKey(id: 2, signature: signature, keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey))
        // 3: Option + D (Open Translation Card)
        registerSingleHotKey(id: 3, signature: signature, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))
        // 4: F1 (Snipaste Classic Capture Shortcut)
        registerSingleHotKey(id: 4, signature: signature, keyCode: UInt32(kVK_F1), modifiers: 0)
        // 5: F3 (Snipaste Classic Pin-to-Screen Shortcut)
        registerSingleHotKey(id: 5, signature: signature, keyCode: UInt32(kVK_F3), modifiers: 0)
        // 6: Option + P (Mac-friendly Pin-to-Screen Shortcut when Fn keys are media keys)
        registerSingleHotKey(id: 6, signature: signature, keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey))
        // 7: Shift + F3 (Restore last closed Pin window)
        registerSingleHotKey(id: 7, signature: signature, keyCode: UInt32(kVK_F3), modifiers: UInt32(shiftKey))
        // 8: Option + X (Unlock all Click-Through Pin windows)
        registerSingleHotKey(id: 8, signature: signature, keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(optionKey))
        // 9: Option + R (Open Screen Recorder Assistant 录屏助手)
        registerSingleHotKey(id: 9, signature: signature, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey))
        // 10: F10 (Stop Screen Recording & Export GIF/MP4)
        registerSingleHotKey(id: 10, signature: signature, keyCode: UInt32(kVK_F10), modifiers: 0)
    }

    private func registerSingleHotKey(id: UInt32, signature: OSType, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
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
        switch id {
        case 1:
            Task {
                if let payload = await grabCurrentSelection() {
                    onTriggerDirectTranslateCard?(payload)
                } else {
                    onTriggerManualPanel?()
                }
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
