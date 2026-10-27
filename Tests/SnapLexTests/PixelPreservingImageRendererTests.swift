import AppKit
import XCTest
@testable import SnapLex

@MainActor
final class PixelPreservingImageRendererTests: XCTestCase {
    func testRetinaCapturePreservesOriginalPixelDetailAndLogicalSize() throws {
        let source = try stripedImage(width: 200, height: 120)
        let selection = CGRect(x: 10, y: 10, width: 60, height: 30)
        let result = try XCTUnwrap(PixelPreservingImageRenderer.capture(
            base: source, screenBounds: CGRect(x: 0, y: 0, width: 100, height: 60),
            selection: selection, drawAnnotations: { _ in }
        ))
        let bitmap = try XCTUnwrap(result.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(result.size, selection.size)
        XCTAssertEqual(bitmap.pixelsWide, 120)
        XCTAssertEqual(bitmap.pixelsHigh, 60)
        let imageForHistory = try XCTUnwrap(result.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(imageForHistory.width, 120)
        XCTAssertEqual(imageForHistory.height, 60)
        for x in 0..<12 {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 10)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, x.isMultiple(of: 2) ? 0 : 1, accuracy: 0.05)
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 120)
        XCTAssertEqual(decoded.pixelsHigh, 60)
    }

    func testStandardResolutionCaptureDoesNotArtificiallyUpscale() throws {
        let source = try stripedImage(width: 100, height: 60)
        let result = try XCTUnwrap(PixelPreservingImageRenderer.capture(
            base: source, screenBounds: CGRect(x: 0, y: 0, width: 100, height: 60),
            selection: CGRect(x: 10, y: 10, width: 60, height: 30), drawAnnotations: { _ in }
        ))
        let bitmap = try XCTUnwrap(result.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, 60)
        XCTAssertEqual(bitmap.pixelsHigh, 30)
    }

    func testPinTransformRetainsPixelDimensionsAndAvoidsUnnecessaryRedraw() throws {
        let source = NSImage(cgImage: try stripedImage(width: 200, height: 120), size: NSSize(width: 100, height: 60))
        let unchanged = PixelPreservingImageRenderer.transform(source, rotationDegrees: 0, flipHorizontally: false)
        XCTAssertTrue(unchanged === source)
        let rotated = PixelPreservingImageRenderer.transform(source, rotationDegrees: 90, flipHorizontally: false)
        let bitmap = try XCTUnwrap(rotated.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rotated.size, NSSize(width: 60, height: 100))
        XCTAssertEqual(bitmap.pixelsWide, 120)
        XCTAssertEqual(bitmap.pixelsHigh, 200)
    }

    func testAnnotationIsDrawnAtTheCorrectRetinaScale() throws {
        let source = try stripedImage(width: 200, height: 120)
        let result = try XCTUnwrap(PixelPreservingImageRenderer.capture(
            base: source, screenBounds: CGRect(x: 0, y: 0, width: 100, height: 60),
            selection: CGRect(x: 10, y: 10, width: 60, height: 30),
            drawAnnotations: { context in
                context.setFillColor(NSColor.red.cgColor)
                context.fill(CGRect(x: 20, y: 20, width: 5, height: 5))
            }
        ))
        let bitmap = try XCTUnwrap(result.representations.first as? NSBitmapImageRep)
        let center = try XCTUnwrap(bitmap.colorAt(x: 24, y: 35)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.9)
        XCTAssertLessThan(center.greenComponent, 0.1)
    }

    func testInPlaceTranslationKeepsOriginalPixelDimensions() throws {
        let source = NSImage(cgImage: try stripedImage(width: 200, height: 120), size: NSSize(width: 100, height: 60))
        let rendered = InPlaceOCRService.renderTranslatedBlocksOnImage(baseImage: source, blocks: [])
        let bitmap = try XCTUnwrap(rendered.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rendered.size, source.size)
        XCTAssertEqual(bitmap.pixelsWide, 200)
        XCTAssertEqual(bitmap.pixelsHigh, 120)
    }

    private func stripedImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for x in 0..<width {
            context.setFillColor((x.isMultiple(of: 2) ? NSColor.black : NSColor.white).cgColor)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
