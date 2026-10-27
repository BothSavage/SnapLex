import Foundation
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics
import os

private let selectionEventTraceEnabled = ProcessInfo.processInfo.environment["SNAPLEX_SELECTION_TRACE"] == "1"

public struct SelectedTextPayload {
    public let text: String
    public let sourceApp: String
    public let trigger: TranslationTriggerSource
    /// Correlates selection capture with the UI presentation stage without
    /// writing the selected text to diagnostic logs.
    public let diagnosticID: String

    public init(
        text: String,
        sourceApp: String,
        trigger: TranslationTriggerSource,
        diagnosticID: String = UUID().uuidString
    ) {
        self.text = text
        self.sourceApp = sourceApp
        self.trigger = trigger
        self.diagnosticID = diagnosticID
    }
}

@MainActor
public final class SelectionAndHotKeyManager: ObservableObject {
    public static let shared = SelectionAndHotKeyManager()

    @Published public var isAXTrusted: Bool = AXIsProcessTrusted()

    /// Fired when mouse drag-select triggers the popup.
    public var onShowSelectionPopup: ((SelectedTextPayload) -> Void)?
    /// Fired when the explicit selection-translation shortcut opens the translation card
    public var onTriggerDirectTranslateCard: ((SelectedTextPayload) -> Void)?
    /// Fired when a screenshot shortcut triggers the capture and annotation overlay
    public var onTriggerScreenshot: (() -> Void)?
    /// Fired when a pin shortcut pins the current image to the screen
    public var onTriggerPinToScreen: (() -> Void)?
    /// Fired when Shift+F3 restores last closed Pin
    public var onTriggerRestoreLastPin: (() -> Void)?
    /// Fired when the unlock shortcut enables clicks on pinned images
    public var onTriggerUnlockClickThrough: (() -> Void)?
    /// Fired when the screen-recording shortcut opens its assistant
    public var onTriggerScreenRecorder: (() -> Void)?
    /// Fired when F10 stops active screen recording
    public var onTriggerStopRecording: (() -> Void)?
    public var onTriggerManualPanel: (() -> Void)?
    public var onOutsideMouseDown: ((NSPoint) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyDispatchGate = GlobalHotKeyDispatchGate()
    private var directTranslationTask: Task<Void, Never>?
    private let accessibilityReader = SelectionAccessibilityReader()
    private let selectionLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "Selection"
    )
    private var hasStarted = false
    private var globalMouseMonitorRegistration = GlobalMouseMonitorRegistrationCoordinator()
    private let mouseGestureGenerationGate = SelectionMouseGestureGenerationGate()

    // Mouse drag selection state
    private var globalMouseDownMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var mouseEventAdapter = SelectionMouseEventAdapter()
    private var lastAutoPopupText: String = ""
    private var lastAutoPopupTime: TimeInterval = 0
    private var lastAutoPopupProcessIdentifier: pid_t?

    private var permissionTimer: Timer?

    private init() {}

    public func start() {
        if !hasStarted {
            hasStarted = true
            isAXTrusted = isAccessibilityTrusted(prompt: false)
            registerCarbonHotKeys()
            startPermissionMonitor()
        }
        ensureGlobalMouseMonitors(force: globalMouseMonitorRegistration.lastAttempt == nil)
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

    private func ensureGlobalMouseMonitors(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let isRetry = globalMouseMonitorRegistration.lastAttempt != nil
        let attempted = globalMouseMonitorRegistration.ensureRegistered(
            now: now,
            force: force,
            registerDown: { self.registerGlobalMouseDownMonitor() },
            registerUp: { self.registerGlobalMouseUpMonitor() }
        )
        guard attempted else { return }

        let inputMonitoringTrusted = CGPreflightListenEventAccess()
        selectionLogger.info("global mouse monitor registration attempted down=\(self.globalMouseMonitorRegistration.downRegistered, privacy: .public) up=\(self.globalMouseMonitorRegistration.upRegistered, privacy: .public) axTrusted=\(self.isAXTrusted, privacy: .public) inputMonitoringTrusted=\(inputMonitoringTrusted, privacy: .public) retry=\(isRetry, privacy: .public)")
        NSLog("SnapLex selection diagnostics: global mouse monitor registration down=%@ up=%@ axTrusted=%@ inputMonitoringTrusted=%@ retry=%@",
              self.globalMouseMonitorRegistration.downRegistered ? "yes" : "no",
              self.globalMouseMonitorRegistration.upRegistered ? "yes" : "no",
              self.isAXTrusted ? "yes" : "no",
              inputMonitoringTrusted ? "yes" : "no",
              isRetry ? "yes" : "no")
        if !self.globalMouseMonitorRegistration.downRegistered || !self.globalMouseMonitorRegistration.upRegistered {
            selectionLogger.error("global mouse selection is unavailable; registration will retry after permission changes or backoff")
        }
    }

    private func registerGlobalMouseDownMonitor() -> Bool {
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            let isLeftMouseDown = event.type == .leftMouseDown
            if selectionEventTraceEnabled {
                NSLog("SnapLex selection trace: global monitor callback received stage=down button=%@",
                      isLeftMouseDown ? "left" : "right")
            }
            let point = SelectionMouseEventAdapter.screenPoint(
                for: event, zeroScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0,
                fallbackLocation: NSEvent.mouseLocation
            )
            let eventTime = SelectionMouseEventAdapter.timestamp(for: event, fallback: ProcessInfo.processInfo.systemUptime)
            let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let isInsideSnapLexWindow = MainActor.assumeIsolated {
                WindowManager.shared.ownsScreenPoint(point)
            }
            self.selectionLogger.debug("global mouse down received button=\(isLeftMouseDown ? "left" : "right", privacy: .public) foregroundPID=\(processIdentifier ?? 0, privacy: .public) clickThroughOverlay=\(isInsideSnapLexWindow, privacy: .public)")
            if selectionEventTraceEnabled {
                NSLog("SnapLex selection trace: global monitor callback processed stage=down button=%@ foregroundPID=%d clickThroughOverlay=%@",
                      isLeftMouseDown ? "left" : "right",
                      Int32(processIdentifier ?? 0),
                      isInsideSnapLexWindow ? "yes" : "no")
            }
            MainActor.assumeIsolated {
                if isLeftMouseDown {
                    let outcome = self.mouseEventAdapter.receive(.leftMouseDown(SelectionMouseDownSnapshot(
                        x: point.x,
                        y: point.y,
                        timestamp: eventTime,
                        processIdentifier: processIdentifier,
                        isInsideSnapLexWindow: isInsideSnapLexWindow
                    )))
                    self.mouseGestureGenerationGate.update(to: self.mouseEventAdapter.currentGeneration)
                    if case let .leftMouseDownRecorded(generation, replacedPendingDown) = outcome {
                        self.selectionLogger.debug("mouse event bridge recorded left-down generation=\(generation, privacy: .public) replacedPending=\(replacedPendingDown, privacy: .public)")
                    }
                } else {
                    let outcome = self.mouseEventAdapter.receive(.rightMouseDown)
                    self.mouseGestureGenerationGate.update(to: self.mouseEventAdapter.currentGeneration)
                    if case let .rightMouseDownCancelled(generation, cancelledPendingDown) = outcome {
                        self.selectionLogger.debug("mouse event bridge cancelled by right-down generation=\(generation, privacy: .public) hadPending=\(cancelledPendingDown, privacy: .public)")
                    }
                }
                self.onOutsideMouseDown?(point)
            }
        }
        return globalMouseDownMonitor != nil
    }

    private func registerGlobalMouseUpMonitor() -> Bool {
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self else { return }
            if selectionEventTraceEnabled {
                NSLog("SnapLex selection trace: global monitor callback received stage=up")
            }
            let point = SelectionMouseEventAdapter.screenPoint(
                for: event, zeroScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0,
                fallbackLocation: NSEvent.mouseLocation
            )
            let eventTime = SelectionMouseEventAdapter.timestamp(for: event, fallback: ProcessInfo.processInfo.systemUptime)
            let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let isInsideSnapLexWindow = MainActor.assumeIsolated {
                WindowManager.shared.ownsScreenPoint(point)
            }
            let outcome = MainActor.assumeIsolated {
                let outcome = self.mouseEventAdapter.receive(.leftMouseUp(SelectionMouseUpSnapshot(
                    x: point.x,
                    y: point.y,
                    timestamp: eventTime,
                    processIdentifier: processIdentifier,
                    clickCount: event.clickCount,
                    isInsideSnapLexWindow: isInsideSnapLexWindow
                )))
                self.mouseGestureGenerationGate.update(to: self.mouseEventAdapter.currentGeneration)
                return outcome
            }
            guard case let .gestureCompleted(gesture) = outcome else {
                self.selectionLogger.debug("global mouse up received paired=false foregroundPID=\(processIdentifier ?? 0, privacy: .public) clickCount=\(event.clickCount, privacy: .public) clickThroughOverlay=\(isInsideSnapLexWindow, privacy: .public)")
                if selectionEventTraceEnabled {
                    NSLog("SnapLex selection trace: global monitor callback processed stage=up paired=no foregroundPID=%d clickCount=%ld clickThroughOverlay=%@",
                          Int32(processIdentifier ?? 0), event.clickCount, isInsideSnapLexWindow ? "yes" : "no")
                }
                return
            }
            self.selectionLogger.debug("global mouse up received paired=true foregroundPID=\(processIdentifier ?? 0, privacy: .public) clickCount=\(event.clickCount, privacy: .public) clickThroughOverlay=\(isInsideSnapLexWindow, privacy: .public) gestureDistance=\(Int(gesture.distance), privacy: .public) gestureMilliseconds=\(Int(gesture.duration * 1_000), privacy: .public)")
            if selectionEventTraceEnabled {
                NSLog("SnapLex selection trace: global monitor callback processed stage=up paired=yes downPID=%d upPID=%d clickCount=%ld downInSnapLex=%@ upInSnapLex=%@ distance=%ld durationMs=%ld",
                      Int32(gesture.down.processIdentifier ?? 0),
                      Int32(processIdentifier ?? 0), event.clickCount,
                      gesture.down.isInsideSnapLexWindow ? "yes" : "no",
                      isInsideSnapLexWindow ? "yes" : "no",
                      Int(gesture.distance), Int(gesture.duration * 1_000))
            }
            if SelectionTriggerPolicy.isSelectionGesture(
                distance: gesture.distance,
                duration: gesture.duration,
                clickCount: event.clickCount
            ) {
                NSLog("SnapLex selection diagnostics: mouse selection gesture paired=yes foregroundPID=%d clickCount=%ld clickThroughOverlay=%@ distance=%ld durationMs=%ld",
                      Int32(processIdentifier ?? 0),
                      event.clickCount,
                      isInsideSnapLexWindow ? "yes" : "no",
                      Int(gesture.distance),
                      Int(gesture.duration * 1_000))
            }
            Task { @MainActor [weak self] in
                await self?.handleMouseSelection(gesture)
            }
        }
        return globalMouseUpMonitor != nil
    }

    private func refreshGlobalMouseMonitors(reason: String) {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        globalMouseMonitorRegistration.reset()
        _ = mouseEventAdapter.receive(.rightMouseDown)
        mouseGestureGenerationGate.update(to: mouseEventAdapter.currentGeneration)
        selectionLogger.info("global mouse monitors refreshed reason=\(reason, privacy: .public)")
        NSLog("SnapLex selection diagnostics: global mouse monitors refreshed reason=%@", reason)
        ensureGlobalMouseMonitors(force: true)
    }

    private func handleMouseSelection(_ gesture: SelectionMouseGestureSnapshot) async {
        let downProcessIdentifier = gesture.down.processIdentifier
        let processIdentifier = gesture.up.processIdentifier
        guard let processIdentifier,
              let sourceApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
            selectionLogger.debug("mouse selection suppressed reason=foreground-changed-during-gesture downPID=\(downProcessIdentifier ?? 0, privacy: .public) upPID=\(processIdentifier ?? 0, privacy: .public)")
            return
        }

        let requestID = UUID().uuidString
        selectionLogger.debug("mouse selection started request=\(requestID, privacy: .public) sourcePID=\(sourceApplication.processIdentifier, privacy: .public)")
        if selectionEventTraceEnabled {
            NSLog("SnapLex selection trace: flow started request=%@ sourcePID=%d", requestID, Int32(sourceApplication.processIdentifier))
        }
        let outcome = await SelectionMouseSelectionFlow.resolve(
            gesture: gesture,
            ownProcessIdentifier: NSRunningApplication.current.processIdentifier,
            isEnabled: { AppSettings.shared.enableMouseHoverBar },
            isCurrentGesture: { self.mouseEventAdapter.isCurrent(gesture) },
            foregroundProcessIdentifier: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            waitForSelectionToSettle: {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: 75_000_000)
                let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                self.selectionLogger.debug("mouse selection settle wait completed request=\(requestID, privacy: .public) milliseconds=\(elapsedMilliseconds, privacy: .public)")
            },
            readAccessibility: { gesture in
                let zeroScreenMaxY = Double(NSScreen.screens.first?.frame.maxY ?? 0)
                return await self.accessibilityReader.inspectSelection(
                    processIdentifier: sourceApplication.processIdentifier,
                    downX: gesture.down.x,
                    downY: gesture.down.y,
                    upX: gesture.up.x,
                    upY: gesture.up.y,
                    zeroScreenMaxY: zeroScreenMaxY,
                    shouldProceed: { [mouseGestureGenerationGate] in
                        mouseGestureGenerationGate.isCurrent(gesture.generation)
                    }
                )
            },
            isDuplicate: { text, timestamp in
                SelectionTriggerPolicy.isDuplicate(
                    text: text,
                    processIdentifier: sourceApplication.processIdentifier,
                    lastText: self.lastAutoPopupText,
                    lastProcessIdentifier: self.lastAutoPopupProcessIdentifier,
                    now: timestamp,
                    lastTime: self.lastAutoPopupTime
                )
            },
            readCompatibilitySelection: { snapshot in
                guard SelectionCompatibilityPolicy.canCopyWeChatSelection(
                    bundleIdentifier: sourceApplication.bundleIdentifier,
                    sourceProcessIdentifier: processIdentifier,
                    snapshot: snapshot
                ), self.isAccessibilityTrusted(prompt: false) else { return nil }
                return await SelectionClipboardCapture.readSelection(
                    from: .general,
                    canContinue: {
                        self.mouseEventAdapter.isCurrent(gesture)
                            && AppSettings.shared.enableMouseHoverBar
                            && NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
                    },
                    sendCopy: { self.simulateCmdC() }
                )
            },
            onAccepted: { selected in
                self.lastAutoPopupText = selected
                self.lastAutoPopupTime = gesture.up.timestamp
                self.lastAutoPopupProcessIdentifier = sourceApplication.processIdentifier
                let appName = sourceApplication.localizedName ?? "macOS"
                if selectionEventTraceEnabled {
                    NSLog("SnapLex selection trace: accepted callback emitted request=%@ characters=%ld", requestID, selected.count)
                }
                self.onShowSelectionPopup?(
                    SelectedTextPayload(
                        text: selected,
                        sourceApp: appName,
                        trigger: .mouseSelect,
                        diagnosticID: requestID
                    )
                )
            }
        )

        switch outcome {
        case let .suppressedBeforeAccessibility(reason):
            selectionLogger.info("mouse selection suppressed request=\(requestID, privacy: .public) stage=preflight reason=\(reason.rawValue, privacy: .public) clicks=\(gesture.up.clickCount, privacy: .public) distance=\(gesture.distance, privacy: .public) duration=\(gesture.duration, privacy: .public)")
            traceMouseSelectionOutcome("suppressed stage=preflight reason=\(reason.rawValue)", requestID: requestID)
        case .cancelledBeforeAccessibility:
            selectionLogger.debug("mouse selection cancelled request=\(requestID, privacy: .public) stage=before-accessibility reason=gesture-or-app-changed")
            traceMouseSelectionOutcome("cancelled stage=before-accessibility reason=gesture-or-app-changed", requestID: requestID)
        case let .cancelledAfterAccessibility(snapshot):
            logMouseAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.debug("mouse selection cancelled request=\(requestID, privacy: .public) stage=after-accessibility reason=gesture-or-app-changed")
            traceMouseSelectionOutcome("cancelled stage=after-accessibility reason=gesture-or-app-changed", requestID: requestID)
        case let .suppressedAfterAccessibility(reason, snapshot):
            logMouseAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.info("mouse selection suppressed request=\(requestID, privacy: .public) stage=accessibility reason=\(reason.rawValue, privacy: .public) timedOut=\(snapshot.timedOut, privacy: .public) sourcePID=\(sourceApplication.processIdentifier, privacy: .public) downPID=\(snapshot.downProcessIdentifier ?? 0, privacy: .public) upPID=\(snapshot.upProcessIdentifier ?? 0, privacy: .public)")
            traceMouseSelectionOutcome("suppressed stage=accessibility reason=\(reason.rawValue) timedOut=\(snapshot.timedOut)", requestID: requestID)
        case let .accepted(snapshot):
            logMouseAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.info("mouse selection accepted request=\(requestID, privacy: .public) characters=\(snapshot.selectedText?.count ?? 0, privacy: .public) sourcePID=\(sourceApplication.processIdentifier, privacy: .public)")
            traceMouseSelectionOutcome("accepted characters=\(snapshot.selectedText?.count ?? 0) axMs=\(snapshot.durationMilliseconds)", requestID: requestID)
        case let .acceptedByCompatibilityCopy(text, snapshot):
            logMouseAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.info("mouse selection accepted request=\(requestID, privacy: .public) capture=wechat-copy characters=\(text.count, privacy: .public) sourcePID=\(processIdentifier, privacy: .public)")
            traceMouseSelectionOutcome("accepted capture=wechat-copy characters=\(text.count)", requestID: requestID)
        }
    }

    private func traceMouseSelectionOutcome(_ outcome: String, requestID: String) {
        guard selectionEventTraceEnabled else { return }
        NSLog("SnapLex selection trace: flow outcome request=%@ %@", requestID, outcome)
    }

    private func logMouseAccessibilitySnapshot(_ snapshot: SelectionAXSnapshot, requestID: String) {
        selectionLogger.debug("mouse selection AX request=\(requestID, privacy: .public) milliseconds=\(snapshot.durationMilliseconds, privacy: .public) queueWait=\(snapshot.queueWaitMilliseconds, privacy: .public) worker=\(snapshot.workerDurationMilliseconds, privacy: .public) calls=\(snapshot.accessibilityCallCount, privacy: .public) error=\(snapshot.lastAccessibilityError ?? 0, privacy: .public) timedOut=\(snapshot.timedOut, privacy: .public) focus=\(String(describing: snapshot.focusedTarget), privacy: .public) focusPID=\(snapshot.focusedProcessIdentifier ?? 0, privacy: .public) down=\(String(describing: snapshot.downTarget), privacy: .public) up=\(String(describing: snapshot.upTarget), privacy: .public) depthLimitDown=\(snapshot.downAncestorLimitReached, privacy: .public) depthLimitUp=\(snapshot.upAncestorLimitReached, privacy: .public)")
        if selectionEventTraceEnabled {
            NSLog("SnapLex selection trace: AX snapshot request=%@ focusTarget=%@ focusPID=%d downTarget=%@ upTarget=%@ downPID=%d upPID=%d durationMs=%ld queueWaitMs=%ld workerMs=%ld calls=%ld error=%d timedOut=%@ depthLimitDown=%@ depthLimitUp=%@",
                  requestID,
                  String(describing: snapshot.focusedTarget),
                  Int32(snapshot.focusedProcessIdentifier ?? 0),
                  String(describing: snapshot.downTarget),
                  String(describing: snapshot.upTarget),
                  Int32(snapshot.downProcessIdentifier ?? 0),
                  Int32(snapshot.upProcessIdentifier ?? 0),
                  snapshot.durationMilliseconds,
                  snapshot.queueWaitMilliseconds,
                  snapshot.workerDurationMilliseconds,
                  snapshot.accessibilityCallCount,
                  snapshot.lastAccessibilityError ?? 0,
                  snapshot.timedOut ? "yes" : "no",
                  snapshot.downAncestorLimitReached ? "yes" : "no",
                  snapshot.upAncestorLimitReached ? "yes" : "no")
        }
        if snapshot.downAncestorLimitReached || snapshot.upAncestorLimitReached {
            selectionLogger.error("mouse selection AX ancestor traversal reached its safety limit request=\(requestID, privacy: .public) down=\(snapshot.downAncestorLimitReached, privacy: .public) up=\(snapshot.upAncestorLimitReached, privacy: .public)")
        }
    }

    /// Copies only after Accessibility confirmed both selection endpoints are
    /// outside editable controls.
    private func syntheticCopySelection(previousChangeCount: Int) async -> String? {
        let pb = NSPasteboard.general
        simulateCmdC()
        try? await Task.sleep(nanoseconds: 85_000_000) // 85ms wait for pasteboard update
        let currentChangeCount = pb.changeCount
        if currentChangeCount != previousChangeCount,
           let copied = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !copied.isEmpty {
            return copied
        }
        return nil
    }

    // MARK: - Grab Selected Text for the explicit translate shortcut

    public func grabCurrentSelection() async -> SelectedTextPayload? {
        let requestID = UUID().uuidString
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != NSRunningApplication.current.processIdentifier else {
            selectionLogger.debug("direct selection suppressed request=\(requestID, privacy: .public) reason=no-external-frontmost-app")
            return nil
        }
        selectionLogger.info("direct selection started request=\(requestID, privacy: .public) sourcePID=\(frontApp.processIdentifier, privacy: .public)")
        let point = NSEvent.mouseLocation
        let zeroScreenMaxY = Double(NSScreen.screens.first?.frame.maxY ?? 0)
        let outcome = await SelectionDirectCaptureFlow.resolve(
            sourceProcessIdentifier: frontApp.processIdentifier,
            ownProcessIdentifier: NSRunningApplication.current.processIdentifier,
            hasAccessibilityPermission: { self.isAccessibilityTrusted(prompt: false) },
            foregroundProcessIdentifier: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            readAccessibility: {
                await self.accessibilityReader.inspectSelection(
                    processIdentifier: frontApp.processIdentifier,
                    downX: point.x,
                    downY: point.y,
                    upX: point.x,
                    upY: point.y,
                    zeroScreenMaxY: zeroScreenMaxY
                )
            },
            synthesizeCopy: {
                let previousChangeCount = NSPasteboard.general.changeCount
                return await self.syntheticCopySelection(previousChangeCount: previousChangeCount)
            }
        )

        switch outcome {
        case let .accepted(text, source, snapshot):
            logDirectAccessibilitySnapshot(snapshot, requestID: requestID)
            let sourceLabel = source == .accessibility ? "ax" : "synthetic-copy"
            selectionLogger.info("direct selection accepted request=\(requestID, privacy: .public) source=\(sourceLabel, privacy: .public) characters=\(text.count, privacy: .public) sourcePID=\(frontApp.processIdentifier, privacy: .public)")
            return SelectedTextPayload(text: text, sourceApp: frontApp.localizedName ?? "macOS", trigger: .selection, diagnosticID: requestID)
        case let .suppressed(reason, snapshot):
            if let snapshot { logDirectAccessibilitySnapshot(snapshot, requestID: requestID) }
            selectionLogger.info("direct selection suppressed request=\(requestID, privacy: .public) reason=\(reason.rawValue, privacy: .public) sourcePID=\(frontApp.processIdentifier, privacy: .public)")
        case .cancelledBeforeAccessibility:
            selectionLogger.debug("direct selection cancelled request=\(requestID, privacy: .public) stage=before-accessibility reason=foreground-changed")
        case let .cancelledAfterAccessibility(snapshot):
            logDirectAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.info("direct selection cancelled request=\(requestID, privacy: .public) stage=after-accessibility reason=foreground-changed")
        case let .cancelledBeforeSyntheticCopy(snapshot):
            logDirectAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.info("direct selection cancelled request=\(requestID, privacy: .public) stage=before-copy reason=foreground-changed")
        case let .cancelledAfterSyntheticCopy(snapshot):
            logDirectAccessibilitySnapshot(snapshot, requestID: requestID)
            selectionLogger.info("direct selection cancelled request=\(requestID, privacy: .public) stage=after-copy reason=foreground-changed")
        }
        return nil
    }

    private func logDirectAccessibilitySnapshot(_ snapshot: SelectionAXSnapshot, requestID: String) {
        selectionLogger.debug("direct selection AX request=\(requestID, privacy: .public) milliseconds=\(snapshot.durationMilliseconds, privacy: .public) queueWait=\(snapshot.queueWaitMilliseconds, privacy: .public) worker=\(snapshot.workerDurationMilliseconds, privacy: .public) calls=\(snapshot.accessibilityCallCount, privacy: .public) error=\(snapshot.lastAccessibilityError ?? 0, privacy: .public) timedOut=\(snapshot.timedOut, privacy: .public) focus=\(String(describing: snapshot.focusedTarget), privacy: .public) down=\(String(describing: snapshot.downTarget), privacy: .public) up=\(String(describing: snapshot.upTarget), privacy: .public) depthLimitDown=\(snapshot.downAncestorLimitReached, privacy: .public) depthLimitUp=\(snapshot.upAncestorLimitReached, privacy: .public)")
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

    // MARK: - Accessibility Permission Monitoring

    private func startPermissionMonitor() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let currentTrust = self.isAccessibilityTrusted(prompt: false)
                if currentTrust != self.isAXTrusted {
                    self.isAXTrusted = currentTrust
                    self.refreshGlobalMouseMonitors(reason: currentTrust ? "accessibility-granted" : "accessibility-revoked")
                }
                self.ensureGlobalMouseMonitors()
            }
        }
    }

    // MARK: - Carbon Global HotKeys

    private func registerCarbonHotKeys() {
        unregisterCarbonHotKeys()

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        if eventHandlerRef == nil {
            let gateContext = Unmanaged.passUnretained(hotKeyDispatchGate).toOpaque()
            let handler: EventHandlerUPP = { _, eventRef, userData -> OSStatus in
                guard let eventRef = eventRef, let userData = userData else { return noErr }
                let dispatchGate = Unmanaged<GlobalHotKeyDispatchGate>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
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
                    if GetEventKind(eventRef) == UInt32(kEventHotKeyReleased) {
                        dispatchGate.noteRelease(for: id)
                        return noErr
                    }
                    guard dispatchGate.shouldDispatchPress(for: id) else { return noErr }
                    Task { @MainActor in
                        SelectionAndHotKeyManager.shared.handleHotKey(id: id)
                    }
                }
                return noErr
            }

            let status = eventTypes.withUnsafeBufferPointer { eventTypesBuffer in
                InstallEventHandler(
                    GetApplicationEventTarget(),
                    handler,
                    eventTypesBuffer.count,
                    eventTypesBuffer.baseAddress,
                    gateContext,
                    &eventHandlerRef
                )
            }
            if status != noErr {
                selectionLogger.error("Carbon keyboard event handler registration failed status=\(status, privacy: .public)")
                return
            }
        }

        let signature = OSType(0x534C_4558)
        let globalShortcuts = GlobalShortcut.allCases.filter(\.isGlobal)
        for shortcut in GlobalShortcut.allCases where shortcut.isGlobal {
            guard let eventID = shortcut.eventID else { continue }
            registerSingleHotKey(
                id: eventID,
                signature: signature,
                binding: AppSettings.shared.shortcutBinding(for: shortcut),
                shortcut: shortcut
            )
        }
        selectionLogger.info("Carbon keyboard registration attempted globalShortcuts=\(globalShortcuts.count, privacy: .public) registered=\(self.hotKeyRefs.count, privacy: .public)")
    }

    public func refreshHotKeys() {
        guard !ShortcutRecorderController.shared.isCapturing else { return }
        registerCarbonHotKeys()
    }

    func suspendHotKeysForRecording() {
        unregisterCarbonHotKeys()
    }

    private func unregisterCarbonHotKeys() {
        hotKeyDispatchGate.reset()
        for hotKey in hotKeyRefs {
            if let hotKey { UnregisterEventHotKey(hotKey) }
        }
        hotKeyRefs.removeAll()
    }

    private func registerSingleHotKey(
        id: UInt32,
        signature: OSType,
        binding: ShortcutBinding,
        shortcut: GlobalShortcut
    ) {
        guard !binding.isReservedForTextEditing else {
            selectionLogger.error("Carbon shortcut rejected as text-editing key shortcut=\(shortcut.rawValue, privacy: .public)")
            return
        }
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
        } else {
            selectionLogger.error("Carbon shortcut registration failed shortcut=\(shortcut.rawValue, privacy: .public) status=\(status, privacy: .public) keyCode=\(binding.keyCode, privacy: .public)")
        }
    }

    private func handleHotKey(id: UInt32) {
        guard !ShortcutRecorderController.shared.isCapturing else { return }
        selectionLogger.debug("global shortcut dispatched eventID=\(id, privacy: .public)")
        switch id {
        case 1:
            // Keep only one extraction pending, and don't show a stale/empty
            // card when there is no current selection.
            guard directTranslationTask == nil else {
                selectionLogger.debug("direct selection suppressed reason=request-already-running")
                return
            }
            let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            directTranslationTask = Task { [weak self] in
                guard let self else { return }
                defer { self.directTranslationTask = nil }
                guard let payload = await self.grabCurrentSelection() else {
                    self.selectionLogger.info("direct selection action ended reason=no-payload")
                    return
                }
                guard !Task.isCancelled,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else {
                    self.selectionLogger.debug("direct selection action cancelled reason=task-or-foreground-changed")
                    return
                }
                self.selectionLogger.info("direct selection action presented characters=\(payload.text.count, privacy: .public) sourceApp=\(payload.sourceApp, privacy: .private)")
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
