import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import SnapLex

@MainActor
final class VisionImageToolsTests: XCTestCase {
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
