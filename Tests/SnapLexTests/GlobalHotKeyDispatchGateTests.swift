import XCTest
@testable import SnapLex

final class GlobalHotKeyDispatchGateTests: XCTestCase {
    func testOnlyFirstPressBeforeReleaseIsDispatched() {
        let gate = GlobalHotKeyDispatchGate()

        XCTAssertTrue(gate.shouldDispatchPress(for: 3))
        XCTAssertFalse(gate.shouldDispatchPress(for: 3))
        XCTAssertFalse(gate.shouldDispatchPress(for: 3))

        gate.noteRelease(for: 3)
        XCTAssertTrue(gate.shouldDispatchPress(for: 3))
    }

    func testDifferentHotKeysHaveIndependentPressLatches() {
        let gate = GlobalHotKeyDispatchGate()

        XCTAssertTrue(gate.shouldDispatchPress(for: 1))
        XCTAssertTrue(gate.shouldDispatchPress(for: 3))
        XCTAssertFalse(gate.shouldDispatchPress(for: 1))
        XCTAssertFalse(gate.shouldDispatchPress(for: 3))
    }

    func testStrayReleaseIsHarmlessAndResetRearmsAllHotKeys() {
        let gate = GlobalHotKeyDispatchGate()

        gate.noteRelease(for: 99)
        XCTAssertTrue(gate.shouldDispatchPress(for: 3))
        XCTAssertFalse(gate.shouldDispatchPress(for: 3))

        gate.reset()
        XCTAssertTrue(gate.shouldDispatchPress(for: 3))
    }
}
