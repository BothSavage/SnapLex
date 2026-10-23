import Foundation
import AppKit
import Vision

public struct OCRCaptureResult {
    public let image: NSImage
    public let recognizedText: String
    public let sourceApp: String
}

public final class VisionOCRService {
    public static let shared = VisionOCRService()

    private init() {}

    /// Launches macOS native interactive screenshot selector (`screencapture -i -x`) and runs Apple Vision OCR
    public func captureInteractiveAndRecognize() async -> OCRCaptureResult? {
        let activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "屏幕截图"
        let tempPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("snaplex_ocr_\(UUID().uuidString).png")

        let captured = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i: interactive region selection, -x: do not play sound
                proc.arguments = ["-i", "-x", tempPath]
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let exists = FileManager.default.fileExists(atPath: tempPath)
                    continuation.resume(returning: proc.terminationStatus == 0 && exists)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }

        guard captured,
              let nsImage = NSImage(contentsOfFile: tempPath) else {
            try? FileManager.default.removeItem(atPath: tempPath)
            return nil
        }

        try? FileManager.default.removeItem(atPath: tempPath)

        let text = await recognizeText(in: nsImage)
        return OCRCaptureResult(image: nsImage, recognizedText: text, sourceApp: activeAppName)
    }

    /// Runs Apple Silicon hardware-accelerated Vision OCR (`VNRecognizeTextRequest`)
    public func recognizeText(in image: NSImage) async -> String {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            return ""
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { req, _ in
                    guard let observations = req.results as? [VNRecognizedTextObservation] else {
                        continuation.resume(returning: "")
                        return
                    }

                    let lines: [String] = observations.compactMap { obs in
                        obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
                    }.filter { !$0.isEmpty }

                    let merged = Self.smartMergeLines(lines)
                    continuation.resume(returning: merged)
                }

                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant", "ja-JP"]

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Intelligently joins soft-wrapped English PDF/article lines while preserving distinct list/code lines
    private static func smartMergeLines(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        if lines.count == 1 { return lines[0] }

        var result = ""
        for (idx, line) in lines.enumerated() {
            if idx == 0 {
                result = line
                continue
            }
            // Handle hyphenated word wrap at end of line
            if result.hasSuffix("-") && line.first?.isLowercase == true {
                result.removeLast()
                result += line
            } else if result.hasSuffix(".") || result.hasSuffix("。") || result.hasSuffix(":") || result.hasSuffix(";") || line.hasPrefix("-") || line.hasPrefix("•") {
                result += "\n" + line
            } else {
                let hasChinese = line.range(of: "\\p{Han}", options: .regularExpression) != nil
                result += (hasChinese ? "" : " ") + line
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
