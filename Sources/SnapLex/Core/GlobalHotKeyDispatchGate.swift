import Foundation

/// Filters repeated Carbon key-down notifications so one physical key press
/// dispatches a global shortcut only once. A matching release re-arms it.
final class GlobalHotKeyDispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pressedIDs: Set<UInt32> = []

    func shouldDispatchPress(for id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressedIDs.insert(id).inserted
    }

    func noteRelease(for id: UInt32) {
        lock.lock()
        pressedIDs.remove(id)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        pressedIDs.removeAll()
        lock.unlock()
    }
}
