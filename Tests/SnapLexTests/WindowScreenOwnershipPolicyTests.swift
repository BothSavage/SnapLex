import XCTest
@testable import SnapLex

final class WindowScreenOwnershipPolicyTests: XCTestCase {
    func testOnlyVisibleClickThroughWindowsOwnTheirPoints() {
        let windows = [
            makeFrame(0, 0, 100, 100, visible: true, passesMouseEventsThrough: false), // dashboard
            makeFrame(120, 0, 220, 100, visible: true, passesMouseEventsThrough: false), // translation card
            makeFrame(240, 0, 340, 100, visible: true, passesMouseEventsThrough: true), // click-through pin
            makeFrame(360, 0, 460, 100, visible: true, passesMouseEventsThrough: false), // recorder assistant
            makeFrame(480, 0, 580, 100, visible: false, passesMouseEventsThrough: true) // hidden click-through pin
        ]

        for (index, x) in [50.0, 170, 290, 410, 530].enumerated() {
            XCTAssertEqual(
                WindowScreenOwnershipPolicy.owns(pointX: x, pointY: 50, windows: windows),
                index == 2,
                "windowIndex=\(index)"
            )
        }
    }

    func testRectMinEdgesAreIncludedAndMaxEdgesAreExcluded() {
        let window = makeFrame(10, 20, 30, 40, visible: true, passesMouseEventsThrough: true)
        XCTAssertTrue(WindowScreenOwnershipPolicy.owns(pointX: 10, pointY: 20, windows: [window]))
        XCTAssertTrue(WindowScreenOwnershipPolicy.owns(pointX: 29.999, pointY: 39.999, windows: [window]))
        XCTAssertFalse(WindowScreenOwnershipPolicy.owns(pointX: 30, pointY: 25, windows: [window]))
        XCTAssertFalse(WindowScreenOwnershipPolicy.owns(pointX: 15, pointY: 40, windows: [window]))
    }

    func testOwnershipAcross441ScreenPointsAndFiveWindowRegions() {
        let windows = [
            makeFrame(0, 0, 3, 4, visible: true, passesMouseEventsThrough: true),
            makeFrame(2, 2, 6, 6, visible: true, passesMouseEventsThrough: false),
            makeFrame(6, 0, 8, 3, visible: false, passesMouseEventsThrough: true),
            makeFrame(-3, 4, 1, 8, visible: true, passesMouseEventsThrough: true),
            makeFrame(7, 7, 10, 10, visible: true, passesMouseEventsThrough: true)
        ]
        var scenarios = 0

        for xStep in 0...20 {
            for yStep in 0...20 {
                let x = Double(xStep) / 2 - 2
                let y = Double(yStep) / 2 - 2
                let expected = windows.contains {
                    $0.isVisible && $0.passesMouseEventsThrough
                        && x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY
                }
                XCTAssertEqual(
                    WindowScreenOwnershipPolicy.owns(pointX: x, pointY: y, windows: windows),
                    expected,
                    "x=\(x) y=\(y)"
                )
                scenarios += 1
            }
        }
        XCTAssertEqual(scenarios, 441)
    }

    private func makeFrame(
        _ minX: Double,
        _ minY: Double,
        _ maxX: Double,
        _ maxY: Double,
        visible: Bool,
        passesMouseEventsThrough: Bool
    ) -> WindowScreenFrame {
        WindowScreenFrame(
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            isVisible: visible,
            passesMouseEventsThrough: passesMouseEventsThrough
        )
    }
}
