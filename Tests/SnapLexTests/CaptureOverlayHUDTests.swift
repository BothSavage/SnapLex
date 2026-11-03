import CoreGraphics
import XCTest
@testable import SnapLex

final class CaptureOverlayHUDTests: XCTestCase {
    func testPixelSamplingUsesTheSourcePixelUnderThePoint() {
        let image = CGSize(width: 200, height: 100)
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)

        XCTAssertEqual(
            CapturePixelGeometry.pixel(at: CGPoint(x: 10, y: 70), imageSize: image, imageRect: rect),
            CGPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            CapturePixelGeometry.pixel(at: CGPoint(x: 10, y: 20), imageSize: image, imageRect: rect),
            CGPoint(x: 0, y: 99)
        )
        XCTAssertEqual(
            CapturePixelGeometry.pixel(at: CGPoint(x: 110, y: 70), imageSize: image, imageRect: rect),
            CGPoint(x: 199, y: 0)
        )
        XCTAssertEqual(
            CapturePixelGeometry.step(imageSize: image, imageRect: rect),
            CGSize(width: 0.5, height: 0.5)
        )
    }

    func testSelectionMovementStaysInsideTheImage() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let selection = CGRect(x: 10, y: 20, width: 80, height: 40)
        let moved = CapturePixelGeometry.moving(selection, by: CGPoint(x: -50, y: 500), within: bounds)
        XCTAssertEqual(moved, CGRect(x: 0, y: 260, width: 80, height: 40))
    }

    func testMagnifierAvoidsTheShortcutGuideAndTheCursor() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        let guide = CGRect(x: 16, y: 16, width: 320, height: 150)
        let cursor = CGPoint(x: 500, y: 400)
        let frame = CapturePixelGeometry.hudFrame(
            at: cursor,
            size: CGSize(width: 180, height: 230),
            within: bounds,
            avoiding: guide
        )

        XCTAssertFalse(frame.intersects(guide))
        XCTAssertFalse(frame.insetBy(dx: -8, dy: -8).contains(cursor))
        XCTAssertTrue(bounds.insetBy(dx: 12, dy: 12).contains(frame))

        let crowded = CapturePixelGeometry.hudFrame(
            at: CGPoint(x: 48, y: 48),
            size: CGSize(width: 180, height: 230),
            within: bounds,
            avoiding: guide
        )
        XCTAssertFalse(crowded.insetBy(dx: -8, dy: -8).contains(CGPoint(x: 48, y: 48)))
    }

    @MainActor
    func testShortcutGuideSitsAtTheLowerLeft() {
        let frame = CaptureShortcutGuideRenderer.frame(
            in: CGRect(x: 0, y: 0, width: 1440, height: 900),
            bottomInset: 70
        )
        XCTAssertEqual(frame.minX, 16)
        XCTAssertEqual(frame.minY, 82)
        XCTAssertEqual(frame.height, 150)
        XCTAssertGreaterThan(frame.width, 200)
        XCTAssertLessThan(frame.maxX, 1440)
    }
}
