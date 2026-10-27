import Foundation

/// Lets the serial AX worker cheaply reject queued mouse gestures after a newer
/// gesture or cancellation supersedes them, without reading MainActor state.
final class SelectionMouseGestureGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var currentGeneration: UInt64 = 0

    func update(to generation: UInt64) {
        lock.lock()
        currentGeneration = generation
        lock.unlock()
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == currentGeneration
    }
}
