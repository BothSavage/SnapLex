import Foundation

struct SelectionMouseDownSnapshot: Equatable, Sendable {
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let processIdentifier: pid_t?
    let isInsideSnapLexWindow: Bool

    init(
        x: Double,
        y: Double,
        timestamp: TimeInterval,
        processIdentifier: pid_t?,
        isInsideSnapLexWindow: Bool = false
    ) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
        self.processIdentifier = processIdentifier
        self.isInsideSnapLexWindow = isInsideSnapLexWindow
    }
}

struct SelectionMouseUpSnapshot: Equatable, Sendable {
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let processIdentifier: pid_t?
    let clickCount: Int
    let isInsideSnapLexWindow: Bool

    init(
        x: Double,
        y: Double,
        timestamp: TimeInterval,
        processIdentifier: pid_t?,
        clickCount: Int,
        isInsideSnapLexWindow: Bool = false
    ) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
        self.processIdentifier = processIdentifier
        self.clickCount = clickCount
        self.isInsideSnapLexWindow = isInsideSnapLexWindow
    }
}

struct SelectionMouseGestureSnapshot: Equatable, Sendable {
    let down: SelectionMouseDownSnapshot
    let up: SelectionMouseUpSnapshot
    let generation: UInt64

    var touchesSnapLexWindow: Bool {
        down.isInsideSnapLexWindow || up.isInsideSnapLexWindow
    }

    var distance: CGFloat {
        hypot(up.x - down.x, up.y - down.y)
    }

    var duration: TimeInterval {
        up.timestamp - down.timestamp
    }
}

/// Captures a complete, immutable mouse gesture at event time. The global
/// monitor callbacks run on the main thread, but their follow-up Tasks may run
/// after later mouse events, so async handlers must never read mutable down
/// state to reconstruct the gesture.
struct SelectionMouseGestureTracker {
    private(set) var generation: UInt64 = 0
    private var pendingDown: SelectionMouseDownSnapshot?

    var hasPendingMouseDown: Bool {
        pendingDown != nil
    }

    @discardableResult
    mutating func recordMouseDown(_ snapshot: SelectionMouseDownSnapshot) -> UInt64 {
        generation &+= 1
        pendingDown = snapshot
        return generation
    }

    mutating func cancelPendingGesture() {
        generation &+= 1
        pendingDown = nil
    }

    mutating func recordMouseUp(_ snapshot: SelectionMouseUpSnapshot) -> SelectionMouseGestureSnapshot? {
        guard let down = pendingDown else { return nil }
        pendingDown = nil
        return SelectionMouseGestureSnapshot(down: down, up: snapshot, generation: generation)
    }

    func isCurrent(_ gesture: SelectionMouseGestureSnapshot) -> Bool {
        gesture.generation == generation
    }
}
