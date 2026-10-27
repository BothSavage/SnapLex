import AppKit
import XCTest
@testable import SnapLex

final class SelectionAccessibilityCoordinateTests: XCTestCase {
    func testCocoaPointsConvertFromStableZeroScreenOriginAcrossDisplays() {
        let zeroScreenMaxY: CGFloat = 900
        let cases: [(name: String, cocoa: NSPoint, expected: NSPoint)] = [
            ("primary-bottom-left", NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 900)),
            ("primary-top-right", NSPoint(x: 1920, y: 900), NSPoint(x: 1920, y: 0)),
            ("display-above-primary", NSPoint(x: 0, y: 1080), NSPoint(x: 0, y: -180)),
            ("display-below-primary", NSPoint(x: -1280, y: -200), NSPoint(x: -1280, y: 1100))
        ]

        for item in cases {
            let actual = SelectionAccessibilityReader.accessibilityPoint(
                fromCocoaPoint: item.cocoa,
                zeroScreenMaxY: zeroScreenMaxY
            )
            XCTAssertEqual(actual.x, item.expected.x, "case=\(item.name) x")
            XCTAssertEqual(actual.y, item.expected.y, "case=\(item.name) y")
        }
    }
}
