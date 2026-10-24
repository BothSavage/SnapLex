import AppKit
import Vision

public struct DetectedCode: Identifiable, Equatable, Sendable {
    public let payload: String
    public let symbology: String

    public var id: String { "\(symbology):\(payload)" }

    public init(payload: String, symbology: String) {
        self.payload = payload
        self.symbology = symbology
    }
}

public enum VisionBarcodeScanningError: LocalizedError {
    case invalidImage

    public var errorDescription: String? {
        L10n.string("无法读取这张图片。")
    }
}

/// Scans local screenshots for QR codes and other barcodes. Payloads are returned as text and never opened.
public final class VisionBarcodeScanningService {
    public static let shared = VisionBarcodeScanningService()

    private init() {}

    public func scanBarcodes(in image: NSImage) async throws -> [DetectedCode] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw VisionBarcodeScanningError.invalidImage
        }

        let observations = try await ImageRequestHandler(cgImage).perform(DetectBarcodesRequest())
        var seen = Set<String>()
        return observations.compactMap { observation in
            guard let payload = observation.payloadString?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !payload.isEmpty else { return nil }
            let symbology = String(describing: observation.symbology)
            guard seen.insert("\(symbology):\(payload)").inserted else { return nil }
            return DetectedCode(payload: payload, symbology: symbology)
        }
    }
}
