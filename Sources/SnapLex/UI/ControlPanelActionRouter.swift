import Foundation

enum ControlPanelAction: Equatable, Sendable {
    case screenshot
    case recording
    case pinClipboard
    case openDashboard(DashboardSection)
    case restart
    case quit
}

@MainActor
struct ControlPanelActionHandlers {
    var onScreenshot: () -> Void
    var onRecord: () -> Void
    var onPinClipboard: () -> Void
    var onOpenDashboard: (DashboardSection) -> Void
    var onQuit: () -> Void
    var onRestart: () -> Void = {}

    func perform(_ action: ControlPanelAction) {
        switch action {
        case .screenshot:
            onScreenshot()
        case .recording:
            onRecord()
        case .pinClipboard:
            onPinClipboard()
        case let .openDashboard(section):
            onOpenDashboard(section)
        case .restart:
            onRestart()
        case .quit:
            onQuit()
        }
    }
}
