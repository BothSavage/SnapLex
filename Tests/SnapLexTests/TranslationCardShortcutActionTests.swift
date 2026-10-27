import XCTest
@testable import SnapLex

final class TranslationCardShortcutActionTests: XCTestCase {
    func testHiddenCardShortcutShowsCard() {
        XCTAssertEqual(TranslationCardShortcutAction.action(isVisible: false), .show)
    }

    func testVisibleCardShortcutHidesCard() {
        XCTAssertEqual(TranslationCardShortcutAction.action(isVisible: true), .hide)
    }
}
