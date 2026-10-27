import ApplicationServices
import Foundation

enum SelectionCompatibilityPolicy {
    static func canCopyWeChatSelection(
        bundleIdentifier: String?,
        sourceProcessIdentifier: pid_t,
        snapshot: SelectionAXSnapshot
    ) -> Bool {
        guard bundleIdentifier == "com.tencent.xinWeChat", !snapshot.timedOut else { return false }
        let targets = [snapshot.downTarget, snapshot.upTarget, snapshot.focusedTarget]
        guard !targets.contains(.secure), !targets.contains(.editable) else { return false }
        for pid in [snapshot.downProcessIdentifier, snapshot.upProcessIdentifier, snapshot.focusedProcessIdentifier].compactMap({ $0 }) {
            guard pid == sourceProcessIdentifier else { return false }
        }
        if let text = snapshot.selectedText, SelectionTriggerPolicy.isValidSelectedText(text) { return false }
        if let error = snapshot.lastAccessibilityError {
            let unsupported = [AXError.noValue, .attributeUnsupported, .notImplemented].map { Int32($0.rawValue) }
            guard unsupported.contains(error) else { return false }
        }
        return true
    }
}
