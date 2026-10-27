import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import SnapLex

@MainActor
final class VisionImageToolsTests: XCTestCase {
    func testBothOCRPathsRecognizeTextAndCancelledRecognitionReturnsEmpty() async throws {
        let image = NSImage(size: NSSize(width: 640, height: 140))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 140).fill()
        ("SNAPLEX STABILITY" as NSString).draw(
            at: NSPoint(x: 24, y: 42),
            withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        )
        image.unlockFocus()

        let text = await VisionOCRService.shared.recognizeText(in: image)
        XCTAssertTrue(text.uppercased().contains("SNAPLEX"), text)
        let blocks = await InPlaceOCRService.shared.recognizeBlocks(in: image)
        XCTAssertTrue(blocks.contains { $0.originalText.uppercased().contains("SNAPLEX") })
        let cancelled = Task { @MainActor in await VisionOCRService.shared.recognizeText(in: image) }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertTrue(result.isEmpty)
    }

    func testBarcodeScannerReadsGeneratedQRCode() async throws {
        let payload = "https://example.com/snaplex-test"
        let qrCode = CIFilter.qrCodeGenerator()
        qrCode.message = Data(payload.utf8)
        qrCode.correctionLevel = "H"
        let qr = try XCTUnwrap(qrCode.outputImage)
        let scaledQR = qr.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let paddedExtent = CGRect(
            x: 0,
            y: 0,
            width: scaledQR.extent.width + 80,
            height: scaledQR.extent.height + 80
        )
        let whiteBackground = CIImage(color: .white).cropped(to: paddedExtent)
        let paddedQR = scaledQR.transformed(by: CGAffineTransform(translationX: 40, y: 40))
        let qrImage = paddedQR.composited(over: whiteBackground)
        let cgImage = try XCTUnwrap(CIContext().createCGImage(qrImage, from: paddedExtent))
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: paddedExtent.width, height: paddedExtent.height)
        )

        let results = try await VisionBarcodeScanningService.shared.scanBarcodes(in: image)

        XCTAssertTrue(results.contains { $0.payload == payload && $0.symbology.lowercased().contains("qr") })
    }
}
