import XCTest
@testable import SnapLex

@MainActor
final class ControlPanelActionRouterTests: XCTestCase {
    func testEveryControlPanelButtonRoutesToItsInjectedActionExactlyOnce() {
        var events: [String] = []
        let handlers = ControlPanelActionHandlers(
            onScreenshot: { events.append("screenshot") },
            onRecord: { events.append("record") },
            onPinClipboard: { events.append("pin") },
            onOpenDashboard: { events.append("dashboard:\($0.rawValue)") },
            onQuit: { events.append("quit") }
        )

        handlers.perform(.screenshot)
        handlers.perform(.recording)
        handlers.perform(.pinClipboard)
        handlers.perform(.openDashboard(.home))
        handlers.perform(.openDashboard(.screenshots))
        handlers.perform(.openDashboard(.translations))
        handlers.perform(.quit)
        handlers.perform(.openDashboard(.home))

        XCTAssertEqual(events, [
            "screenshot",
            "record",
            "pin",
            "dashboard:home",
            "dashboard:screenshots",
            "dashboard:translations",
            "quit",
            "dashboard:home"
        ])
    }
}
