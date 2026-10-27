import AppKit

enum SelectionMouseEvent: Equatable, Sendable {
    case leftMouseDown(SelectionMouseDownSnapshot)
    case rightMouseDown
    case leftMouseUp(SelectionMouseUpSnapshot)
}

enum SelectionMouseEventOutcome: Equatable, Sendable {
    case leftMouseDownRecorded(generation: UInt64, replacedPendingDown: Bool)
    case rightMouseDownCancelled(generation: UInt64, cancelledPendingDown: Bool)
    case gestureCompleted(SelectionMouseGestureSnapshot)
    case orphanMouseUp
}

/// Adapts the production NSEvent callback kinds into the immutable gesture
/// snapshots consumed by the asynchronous selection flow.
struct SelectionMouseEventAdapter {
    private var tracker = SelectionMouseGestureTracker()

    var currentGeneration: UInt64 { tracker.generation }

    static func screenPoint(
        for event: NSEvent,
        zeroScreenMaxY: CGFloat,
        fallbackLocation: @autoclosure () -> NSPoint
    ) -> NSPoint {
        // Global callbacks can run after the pointer has already moved. Use
        // the event's immutable Quartz position instead of live mouseLocation.
        if let point = event.cgEvent?.location, point.x.isFinite, point.y.isFinite {
            return NSPoint(x: point.x, y: zeroScreenMaxY - point.y)
        }
        return fallbackLocation()
    }

    static func timestamp(for event: NSEvent, fallback: @autoclosure () -> TimeInterval) -> TimeInterval {
        event.timestamp.isFinite && event.timestamp > 0 ? event.timestamp : fallback()
    }

    mutating func receive(_ event: SelectionMouseEvent) -> SelectionMouseEventOutcome {
        switch event {
        case let .leftMouseDown(snapshot):
            let replacedPendingDown = tracker.hasPendingMouseDown
            let generation = tracker.recordMouseDown(snapshot)
            return .leftMouseDownRecorded(
                generation: generation,
                replacedPendingDown: replacedPendingDown
            )

        case .rightMouseDown:
            let cancelledPendingDown = tracker.hasPendingMouseDown
            tracker.cancelPendingGesture()
            return .rightMouseDownCancelled(
                generation: tracker.generation,
                cancelledPendingDown: cancelledPendingDown
            )

        case let .leftMouseUp(snapshot):
            guard let gesture = tracker.recordMouseUp(snapshot) else {
                return .orphanMouseUp
            }
            return .gestureCompleted(gesture)
        }
    }

    func isCurrent(_ gesture: SelectionMouseGestureSnapshot) -> Bool {
        tracker.isCurrent(gesture)
    }
}
