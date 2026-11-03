import AppKit
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

    /// Writes a uniquely named PNG into a folder, creating the folder when needed.
    @MainActor
    static func export(_ image: NSImage, to directory: URL, pattern: String) async -> URL? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var naming = SnapPreferences.standard
        naming.fileNamePattern = pattern
        let url = naming.uniqueFileURL(in: directory, at: Date())
        return await write(cgImage, to: url) ? url : nil
    }
}
