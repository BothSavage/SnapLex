import XCTest
@testable import SnapLex

@MainActor
final class TranslationEngineSelectionActionTests: XCTestCase {
    func testSelectingDifferentEngineUpdatesPreferenceAndRerunsOnce() {
        var events: [String] = []

        let didChange = TranslationEngineSelectionAction.select(
            .apple,
            currentEngine: .google,
            updateSetting: { events.append("setting:apple") },
            rerunCurrentInput: { events.append("rerun") }
        )

        XCTAssertTrue(didChange)
        XCTAssertEqual(events, ["setting:apple", "rerun"])
    }

    func testReselectingCurrentEngineHasNoSideEffects() {
        var sideEffectCount = 0

        let didChange = TranslationEngineSelectionAction.select(
            .google,
            currentEngine: .google,
            updateSetting: { sideEffectCount += 1 },
            rerunCurrentInput: { sideEffectCount += 1 }
        )

        XCTAssertFalse(didChange)
        XCTAssertEqual(sideEffectCount, 0)
    }
}
