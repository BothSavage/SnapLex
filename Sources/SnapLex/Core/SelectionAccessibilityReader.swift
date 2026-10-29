import AppKit
import ApplicationServices
import Foundation
import os

struct SelectionAXSnapshot: Equatable, Sendable {
    let focusedTarget: SelectionAXTargetKind
    /// The focus element was fetched from the AX application element created
    /// for the captured source PID, so this records its verified owner.
    let focusedProcessIdentifier: pid_t?
    let downTarget: SelectionAXTargetKind
    let upTarget: SelectionAXTargetKind
    let downProcessIdentifier: pid_t?
    let upProcessIdentifier: pid_t?
    let downAncestorLimitReached: Bool
    let upAncestorLimitReached: Bool
    let selectedText: String?
    let durationMilliseconds: Int
    let queueWaitMilliseconds: Int
    let workerDurationMilliseconds: Int
    let accessibilityCallCount: Int
    let lastAccessibilityError: Int32?
    let timedOut: Bool
}

/// Performs cross-process Accessibility IPC on one serial worker queue.
/// It never logs or writes the selected text to the pasteboard.
final class SelectionAccessibilityReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.snaplex.selection-ax", qos: .userInitiated)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "SelectionAX"
    )
    private let perMessageTimeout: TimeInterval = 0.06
    private let maximumQueueWaitNanoseconds: UInt64 = 300_000_000
    private let workerBudgetNanoseconds: UInt64 = 280_000_000
    // Native/WebKit accessibility trees can be substantially deeper than a
    // normal AppKit view tree (for example, nested markdown inside a browser
    // conversation). Keep a high structural ceiling; each AX call still shares
    // the request's strict worker deadline, so this does not extend wall time.
    static let maximumAncestorDepth = 128

    /// AXUIElement's messaging timeout is reported as `cannotComplete`.
    /// Preserve that distinction in snapshots so a timed-out IPC is not
    /// diagnosed as an ordinary unsupported/failed attribute read.
    static func isTimeoutError(_ errorCode: Int32) -> Bool {
        errorCode == Int32(AXError.cannotComplete.rawValue)
    }

    static func isUnsupportedParentOnApplicationRoot(_ role: String?, errorCode: Int32) -> Bool {
        role == "AXApplication" && errorCode == Int32(AXError.attributeUnsupported.rawValue)
    }

    private struct RequestContext {
        let deadline: UInt64
        var shouldProceed: @Sendable () -> Bool = { true }
        // Request-local raw reads preserve the policy's depth and role-chain
        // classification for each endpoint, even where their ancestors overlap.
        var ancestorReads: [CFHashCode: [(AXUIElement, SelectionAXAncestorRead<AXUIElement>)]] = [:]
        var callCount = 0
        var lastError: Int32?
        var timedOut = false
    }

    private struct ElementInspection {
        let target: SelectionAXTargetKind
        let selectedText: String?
        let ancestorLimitReached: Bool
    }

    func inspectSelection(
        processIdentifier: pid_t,
        downX: Double,
        downY: Double,
        upX: Double,
        upY: Double,
        zeroScreenMaxY: Double,
        shouldProceed: @escaping @Sendable () -> Bool = { true }
    ) async -> SelectionAXSnapshot {
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        let cancellationGate = SelectionMouseGestureGenerationGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    let timing = self.makeTimingBudget(enqueuedAt: enqueuedAt)
                    var context = self.makeContext(startedAt: startedAt, timing: timing)
                    context.shouldProceed = { shouldProceed() && cancellationGate.isCurrent(0) }
                    guard shouldProceed() else {
                        self.logger.debug("mouse AX request cancelled before IPC queueWaitMs=\((startedAt - enqueuedAt) / 1_000_000, privacy: .public)")
                        continuation.resume(returning: self.emptySnapshot(
                            enqueuedAt: enqueuedAt,
                            startedAt: startedAt,
                            context: context,
                            timedOut: false
                        ))
                        return
                    }
                    guard timing.shouldStartWorker(at: startedAt), self.hasTime(context) else {
                        context.timedOut = true
                        self.logger.info("mouse AX request rejected before IPC reason=queue-wait-exceeded queueWaitMs=\((startedAt - enqueuedAt) / 1_000_000, privacy: .public)")
                        continuation.resume(returning: self.emptySnapshot(
                            enqueuedAt: enqueuedAt,
                            startedAt: startedAt,
                            context: context,
                            timedOut: true
                        ))
                        return
                    }

                    let appElement = AXUIElementCreateApplication(processIdentifier)
                    let downPoint = Self.accessibilityPoint(
                        fromCocoaPoint: NSPoint(x: downX, y: downY),
                        zeroScreenMaxY: CGFloat(zeroScreenMaxY)
                    )
                    let upPoint = Self.accessibilityPoint(
                        fromCocoaPoint: NSPoint(x: upX, y: upY),
                        zeroScreenMaxY: CGFloat(zeroScreenMaxY)
                    )
                    let downElement = self.element(
                        in: appElement,
                        x: downPoint.x,
                        y: downPoint.y,
                        context: &context
                    )
                    let upElement = downPoint == upPoint ? downElement : self.element(
                        in: appElement,
                        x: upPoint.x,
                        y: upPoint.y,
                        context: &context
                    )
                    let downInspection = downElement.flatMap { self.inspect($0, context: &context) }
                    let upInspection = upElement.flatMap { self.inspect($0, context: &context) }

                    // Endpoint hit tests are the primary signal for a mouse or
                    // explicit selection. Read focus only as a bounded fallback
                    // when both safe page endpoints omitted a usable selection.
                    var focusedInspection: ElementInspection?
                    var focusedTarget: SelectionAXTargetKind = .unavailable
                    if Self.shouldReadFocusedSelection(
                        downTarget: downInspection?.target ?? .unavailable,
                        upTarget: upInspection?.target ?? .unavailable,
                        downText: downInspection?.selectedText,
                        upText: upInspection?.selectedText
                    ),
                       let focused = self.focusedElement(in: appElement, context: &context),
                       let inspection = self.inspect(focused, context: &context) {
                        focusedInspection = inspection
                        focusedTarget = inspection.target
                    }

                    // Never reuse a focused editable field's previous selection for
                    // a page drag. Prefer the mouse-up hit target, then the down target.
                    let selectedText = Self.selectedText(
                        upText: upInspection?.selectedText,
                        downText: downInspection?.selectedText,
                        focusedTarget: focusedTarget,
                        focusedText: focusedInspection?.selectedText
                    )

                    let downPID = downElement.flatMap { self.processIdentifier(of: $0, context: &context) }
                    let upPID = upElement.flatMap { element in
                        if let downElement, CFEqual(element, downElement) { return downPID }
                        return self.processIdentifier(of: element, context: &context)
                    }
                    let timedOut = !self.hasTime(context)
                    let completedAt = DispatchTime.now().uptimeNanoseconds
                    let duration = completedAt - startedAt
                    continuation.resume(returning: SelectionAXSnapshot(
                        focusedTarget: focusedTarget,
                        focusedProcessIdentifier: focusedInspection == nil ? nil : processIdentifier,
                        downTarget: downInspection?.target ?? .unavailable,
                        upTarget: upInspection?.target ?? .unavailable,
                        downProcessIdentifier: downPID,
                        upProcessIdentifier: upPID,
                        downAncestorLimitReached: downInspection?.ancestorLimitReached ?? false,
                        upAncestorLimitReached: upInspection?.ancestorLimitReached ?? false,
                        selectedText: selectedText,
                        durationMilliseconds: Int((completedAt - enqueuedAt) / 1_000_000),
                        queueWaitMilliseconds: Int((startedAt - enqueuedAt) / 1_000_000),
                        workerDurationMilliseconds: Int(duration / 1_000_000),
                        accessibilityCallCount: context.callCount,
                        lastAccessibilityError: context.lastError,
                        timedOut: timedOut || context.timedOut
                    ))
                }
            }
        } onCancel: {
            cancellationGate.update(to: 1)
        }
    }

    static func accessibilityPoint(fromCocoaPoint point: NSPoint, zeroScreenMaxY: CGFloat) -> NSPoint {
        NSPoint(x: point.x, y: zeroScreenMaxY - point.y)
    }

    static func selectedText(
        upText: String?,
        downText: String?,
        focusedTarget: SelectionAXTargetKind,
        focusedText: String?
    ) -> String? {
        // Hit-tested endpoint text is strongest. Browser WebViews often expose
        // the page selection only on their focused AXWebArea, so use that as a
        // safe fallback only when AX classifies the focused chain as non-editable.
        return SelectionTriggerPolicy.preferredSelectedText(
            upText: upText,
            downText: downText,
            focusedText: focusedText,
            focusedTarget: focusedTarget
        )
    }

    static func shouldReadFocusedSelection(
        downTarget: SelectionAXTargetKind,
        upTarget: SelectionAXTargetKind,
        downText: String?,
        upText: String?
    ) -> Bool {
        // An explicit editable endpoint always wins. Some AX providers cannot
        // resolve one or both hit-test endpoints, while still exposing the
        // selected range on their focused WebArea/document element.
        guard downTarget != .editable, upTarget != .editable,
              downTarget != .secure, upTarget != .secure else { return false }
        return SelectionTriggerPolicy.preferredSelectedText(
            upText: upText,
            downText: downText,
            focusedText: nil,
            focusedTarget: .unavailable
        ) == nil
    }

    private func makeTimingBudget(enqueuedAt: UInt64) -> SelectionAccessibilityTimingBudget {
        SelectionAccessibilityTimingBudget(
            enqueuedAtNanoseconds: enqueuedAt,
            maximumQueueWaitNanoseconds: maximumQueueWaitNanoseconds,
            workerBudgetNanoseconds: workerBudgetNanoseconds
        )
    }

    private func makeContext(
        startedAt: UInt64,
        timing: SelectionAccessibilityTimingBudget
    ) -> RequestContext {
        return RequestContext(deadline: timing.workerDeadline(startedAt: startedAt))
    }

    private func hasTime(_ context: RequestContext) -> Bool {
        context.shouldProceed() && !context.timedOut
            && DispatchTime.now().uptimeNanoseconds < context.deadline
    }

    private func remainingTimeout(_ context: RequestContext) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard context.shouldProceed(), !context.timedOut, now < context.deadline else { return nil }
        let remaining = Double(context.deadline - now) / 1_000_000_000
        return Float(min(perMessageTimeout, remaining))
    }

    private func focusedElement(in appElement: AXUIElement, context: inout RequestContext) -> AXUIElement? {
        guard let timeout = remainingTimeout(context) else {
            context.timedOut = true
            return nil
        }
        AXUIElementSetMessagingTimeout(appElement, timeout)
        context.callCount += 1
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard error == .success else {
            recordAccessibilityError(error, context: &context)
            return nil
        }
        return axElement(from: value)
    }

    private func element(
        in appElement: AXUIElement,
        x: Double,
        y: Double,
        context: inout RequestContext
    ) -> AXUIElement? {
        guard let timeout = remainingTimeout(context) else {
            context.timedOut = true
            return nil
        }
        AXUIElementSetMessagingTimeout(appElement, timeout)
        context.callCount += 1
        var value: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(appElement, Float(x), Float(y), &value)
        guard error == .success else {
            recordAccessibilityError(error, context: &context)
            return nil
        }
        return value
    }

    private func inspect(_ startingElement: AXUIElement, context: inout RequestContext) -> ElementInspection? {
        let inspection = SelectionTriggerPolicy.inspectAXAncestorChain(
            startingAt: startingElement,
            maximumDepth: Self.maximumAncestorDepth
        ) { element in
            guard hasTime(context) else {
                context.timedOut = true
                return .timedOut
            }
            let key = CFHash(element)
            if let cached = context.ancestorReads[key]?.first(where: { CFEqual($0.0, element) }) {
                return cached.1
            }
            let read = readAncestor(element, context: &context)
            switch read {
            case .parent, .root:
                context.ancestorReads[key, default: []].append((element, read))
            case .failed, .timedOut:
                break
            }
            return read
        }
        if inspection.timedOut { context.timedOut = true }
        if let lastError = inspection.lastError { context.lastError = lastError }
        return ElementInspection(
            target: inspection.target,
            selectedText: inspection.selectedText,
            ancestorLimitReached: inspection.ancestorLimitReached
        )
    }

    private func readAncestor(
        _ element: AXUIElement,
        context: inout RequestContext
    ) -> SelectionAXAncestorRead<AXUIElement> {
        guard let timeout = remainingTimeout(context) else {
            context.timedOut = true
            return .timedOut
        }
        AXUIElementSetMessagingTimeout(element, timeout)
        context.callCount += 1

        let attributes: CFArray = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXSelectedTextAttribute as CFString
        ] as CFArray
        var values: CFArray?
        let attributesError = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values)
        var role: String?
        var selectedText: String?

        if attributesError == .success,
           let values = values as? [Any],
           values.count == 3 {
            role = SelectionTriggerPolicy.normalizedTextEntryRole(role: values[0] as? String, subrole: values[1] as? String)
            selectedText = role == "AXSecureTextField" ? nil : values[2] as? String
        } else if attributesError == .attributeUnsupported {
            // Some AX providers reject the entire multi-attribute request
            // when only one attribute (commonly selected text on a
            // hit-tested Preview group) is unsupported. Read each value
            // independently so an unsupported selection attribute does
            // not hide an otherwise safe role and parent chain.
            recordAccessibilityError(attributesError, context: &context)
            guard let roleTimeout = remainingTimeout(context) else {
                context.timedOut = true
                return .timedOut
            }
            AXUIElementSetMessagingTimeout(element, roleTimeout)
            context.callCount += 1
            var roleValue: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(
                element,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            if roleError == .success {
                role = roleValue as? String
            } else if roleError != .noValue {
                recordAccessibilityError(roleError, context: &context)
            }
            if context.timedOut { return .timedOut }

            guard let subroleTimeout = remainingTimeout(context) else {
                context.timedOut = true
                return .timedOut
            }
            AXUIElementSetMessagingTimeout(element, subroleTimeout)
            context.callCount += 1
            var subroleValue: CFTypeRef?
            let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
            if subroleError == .success {
                role = SelectionTriggerPolicy.normalizedTextEntryRole(role: role, subrole: subroleValue as? String)
            } else if subroleError != .noValue && subroleError != .attributeUnsupported {
                recordAccessibilityError(subroleError, context: &context)
            }
            if context.timedOut { return .timedOut }
            if role == "AXSecureTextField" {
                return .root(role: role, selectedText: nil, valueIsSettable: nil)
            }

            guard let selectedTextTimeout = remainingTimeout(context) else {
                context.timedOut = true
                return .timedOut
            }
            AXUIElementSetMessagingTimeout(element, selectedTextTimeout)
            context.callCount += 1
            var selectedTextValue: CFTypeRef?
            let selectedTextError = AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                &selectedTextValue
            )
            if selectedTextError == .success {
                selectedText = selectedTextValue as? String
            } else if selectedTextError != .noValue {
                recordAccessibilityError(selectedTextError, context: &context)
            }
            if context.timedOut { return .timedOut }
        } else if attributesError != .success {
            recordAccessibilityError(attributesError, context: &context)
            return context.timedOut ? .timedOut : .failed(error: Int32(attributesError.rawValue))
        } else {
            context.lastError = -1
            return .failed(error: -1)
        }

        var valueIsSettable: Bool?
        if SelectionTriggerPolicy.editableAXRoles.contains(role ?? ""),
           role != "AXSecureTextField" {
            guard let editabilityTimeout = remainingTimeout(context) else {
                context.timedOut = true
                return .timedOut
            }
            AXUIElementSetMessagingTimeout(element, editabilityTimeout)
            context.callCount += 1
            var isSettable = DarwinBoolean(false)
            let editabilityError = AXUIElementIsAttributeSettable(
                element,
                kAXValueAttribute as CFString,
                &isSettable
            )
            if editabilityError == .success {
                valueIsSettable = isSettable.boolValue
            } else {
                recordAccessibilityError(editabilityError, context: &context)
                if context.timedOut { return .timedOut }
            }
        }

        if SelectionTriggerPolicy.editableAXRoles.contains(role ?? ""),
           role == "AXSecureTextField" || valueIsSettable != false {
            return .root(role: role, selectedText: selectedText, valueIsSettable: valueIsSettable)
        }

        // Read parent separately so AXError.noValue identifies a real root.
        // A CFNull parent slot from CopyMultipleAttributeValues is ambiguous.
        guard let parentTimeout = remainingTimeout(context) else {
            context.timedOut = true
            return .timedOut
        }
        AXUIElementSetMessagingTimeout(element, parentTimeout)
        context.callCount += 1
        var parentValue: CFTypeRef?
        let parentError = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        )
        if parentError == .success, let parent = axElement(from: parentValue) {
            return .parent(
                role: role,
                selectedText: selectedText,
                valueIsSettable: valueIsSettable,
                node: parent
            )
        }
        if parentError == .noValue
            || Self.isUnsupportedParentOnApplicationRoot(role, errorCode: Int32(parentError.rawValue)) {
            return .root(role: role, selectedText: selectedText, valueIsSettable: valueIsSettable)
        }

        let errorCode = parentError == .success ? -1 : Int32(parentError.rawValue)
        if parentError == .success {
            context.lastError = errorCode
        } else {
            recordAccessibilityError(parentError, context: &context)
        }
        return .failed(error: errorCode)
    }

    private func processIdentifier(of element: AXUIElement, context: inout RequestContext) -> pid_t? {
        guard hasTime(context) else { return nil }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }
        return processIdentifier
    }

    private func recordAccessibilityError(_ error: AXError, context: inout RequestContext) {
        let errorCode = Int32(error.rawValue)
        context.lastError = errorCode
        if Self.isTimeoutError(errorCode) {
            context.timedOut = true
        }
    }

    private func emptySnapshot(
        enqueuedAt: UInt64,
        startedAt: UInt64,
        context: RequestContext,
        timedOut: Bool
    ) -> SelectionAXSnapshot {
        let completedAt = DispatchTime.now().uptimeNanoseconds
        let elapsed = completedAt - enqueuedAt
        return SelectionAXSnapshot(
            focusedTarget: .unavailable,
            focusedProcessIdentifier: nil,
            downTarget: .unavailable,
            upTarget: .unavailable,
            downProcessIdentifier: nil,
            upProcessIdentifier: nil,
            downAncestorLimitReached: false,
            upAncestorLimitReached: false,
            selectedText: nil,
            durationMilliseconds: Int(elapsed / 1_000_000),
            queueWaitMilliseconds: Int((startedAt - enqueuedAt) / 1_000_000),
            workerDurationMilliseconds: Int((completedAt - startedAt) / 1_000_000),
            accessibilityCallCount: context.callCount,
            lastAccessibilityError: context.lastError,
            timedOut: timedOut
        )
    }

    private func axElement(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

}
