import AppKit
import SwiftUI
import XCTest
@testable import SnapLex

@MainActor
final class SnapLexTranslationIconTests: XCTestCase {
    func testTranslationIconFitsToolbarButtonBounds() {
        let host = NSHostingView(
            rootView: SnapLexTranslationIcon(size: 17)
                .padding(2)
        )
        host.frame = NSRect(x: 0, y: 0, width: 30, height: 28)
        host.layoutSubtreeIfNeeded()

        let fittingSize = host.fittingSize
        XCTAssertGreaterThan(fittingSize.width, 20)
        XCTAssertLessThanOrEqual(fittingSize.width, 28)
        XCTAssertLessThanOrEqual(fittingSize.height, 24)
    }
}
