import CoreGraphics
import Foundation
import ImageIO

/// Encodes immutable image snapshots away from the UI thread.
enum PNGImageWriter {
    private static let queue = DispatchQueue(label: "io.github.snaplex.png-export", qos: .userInitiated)

    static func write(_ image: CGImage, to url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let saved = autoreleasepool {
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                        return false
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { return false }
                    do {
                        try (data as Data).write(to: url, options: .atomic)
                        return true
                    } catch {
                        return false
                    }
                }
                continuation.resume(returning: saved)
            }
        }
    }
}
