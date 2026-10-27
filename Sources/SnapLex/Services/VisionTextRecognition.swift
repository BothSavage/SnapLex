import Foundation
import Vision

enum VisionTextRecognition {
    private static let queue = DispatchQueue(label: "io.github.snaplex.ocr", qos: .userInitiated)

    static func recognize(_ image: CGImage, languages: [String]) async -> [VNRecognizedTextObservation] {
        guard !Task.isCancelled else { return [] }
        let observations: [VNRecognizedTextObservation] = await withCheckedContinuation { continuation in
            queue.async {
                let result: [VNRecognizedTextObservation] = autoreleasepool {
                    // Read results after perform returns. A completion handler
                    // plus a throwing perform can otherwise resume twice.
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = languages
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                        return request.results ?? []
                    } catch {
                        return []
                    }
                }
                continuation.resume(returning: result)
            }
        }
        return Task.isCancelled ? [] : observations
    }
}
