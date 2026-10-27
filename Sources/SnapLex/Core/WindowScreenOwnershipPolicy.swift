import Foundation

struct WindowScreenFrame: Equatable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let isVisible: Bool
    let passesMouseEventsThrough: Bool

    func contains(x: Double, y: Double) -> Bool {
        isVisible && passesMouseEventsThrough
            && x >= minX && x < maxX && y >= minY && y < maxY
    }
}

enum WindowScreenOwnershipPolicy {
    static func owns(pointX: Double, pointY: Double, windows: [WindowScreenFrame]) -> Bool {
        windows.contains { $0.contains(x: pointX, y: pointY) }
    }
}
