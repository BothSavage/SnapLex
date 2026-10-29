import Foundation
import Vision

enum VisionTextRecognition {
    private static let queue = DispatchQueue(label: "io.github.snaplex.ocr", qos: .userInitiated)

    static func recognize(_ image: CGImage, languages: [String]) async -> [VNRecognizedTextObservation] {
        guard !Task.isCancelled else { return [] }
        let work = RecognitionWork(image: image, languages: languages)
        let observations = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation can arrive before the continuation is installed.
                // The queued closure owns only the work, so cancelling queued work
                // also releases its image without waiting for earlier requests.
                guard work.install(continuation) else { return }
                queue.async { work.perform() }
            }
        } onCancel: {
            work.cancel()
        }
        return Task.isCancelled ? [] : observations
    }

    /// All mutable state is protected by the lock. Vision is configured and read
    /// only on the OCR queue; cancel() is the sole cross-thread request operation.
    private final class RecognitionWork: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        private let languages: [String]
        private var continuation: CheckedContinuation<[VNRecognizedTextObservation], Never>?
        private var request: VNRecognizeTextRequest?
        private var isCancelled = false

        init(image: CGImage, languages: [String]) {
            self.image = image
            self.languages = languages
        }

        func install(_ continuation: CheckedContinuation<[VNRecognizedTextObservation], Never>) -> Bool {
            lock.lock()
            if isCancelled {
                lock.unlock()
                continuation.resume(returning: [])
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            image = nil
            let request = request
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            // Never call into Vision or resume a continuation while holding the
            // state lock. perform() may return concurrently with cancellation.
            request?.cancel()
            continuation?.resume(returning: [])
        }

        func perform() {
            autoreleasepool {
                lock.lock()
                let image = isCancelled ? nil : self.image
                self.image = nil
                lock.unlock()
                guard let image else { return }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = languages

                lock.lock()
                guard !isCancelled else {
                    lock.unlock()
                    return
                }
                self.request = request
                lock.unlock()

                let result: [VNRecognizedTextObservation]
                do {
                    // Read results after perform returns, without a completion
                    // callback that could compete with a throwing perform.
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    result = request.results ?? []
                } catch {
                    result = []
                }

                lock.lock()
                self.request = nil
                let continuation = continuation
                self.continuation = nil
                let cancelled = isCancelled
                lock.unlock()
                continuation?.resume(returning: cancelled ? [] : result)
            }
        }
    }
}
