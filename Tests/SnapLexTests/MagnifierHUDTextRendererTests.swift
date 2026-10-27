import CoreGraphics
import XCTest
@testable import SnapLex

final class MagnifierHUDTextRendererTests: XCTestCase {
    func testCoreTextRendererDrawsHUDTextForAllProductionFontStyles() throws {
        let width = 360
        let height = 72
        let bytesPerRow = width * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: height * bytesPerRow)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: 0, count: height * bytesPerRow)

        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        let styles: [(String, String, CGFloat, CGFloat)] = [
            ("#A1B2C3", "Menlo-Bold", 11, 5),
            ("POS: (120, 240)", "Menlo", 10, 25),
            ("[C] Copy color  [Shift] Change", "HelveticaNeue-Medium", 9.5, 45)
        ]

        for (text, fontName, fontSize, y) in styles {
            MagnifierHUDTextRenderer.draw(
                text,
                fontName: fontName,
                fontSize: fontSize,
                color: CGColor(gray: 0.1, alpha: 1),
                at: CGPoint(x: 5, y: y),
                in: context
            )
        }

        let hasRenderedPixels = stride(from: 3, to: height * bytesPerRow, by: 4)
            .contains { pixels[$0] > 0 }
        XCTAssertTrue(hasRenderedPixels, "The magnifier's CoreText HUD labels should render to a bitmap context.")
    }

    func testRendererIgnoresEmptyTextAndInvalidFontSizes() throws {
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: 32 * 32 * 4)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: 0, count: 32 * 32 * 4)

        let context = try XCTUnwrap(CGContext(
            data: pixels,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        MagnifierHUDTextRenderer.draw("", fontName: "Menlo", fontSize: 12, color: .black, at: .zero, in: context)
        MagnifierHUDTextRenderer.draw("text", fontName: "Menlo", fontSize: .nan, color: .black, at: .zero, in: context)
        MagnifierHUDTextRenderer.draw("text", fontName: "Menlo", fontSize: 0, color: .black, at: .zero, in: context)

        XCTAssertFalse((0 ..< 32 * 32 * 4).contains { pixels[$0] != 0 })
    }
}
