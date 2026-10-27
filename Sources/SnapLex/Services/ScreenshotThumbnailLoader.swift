import AppKit
import ImageIO

/// Loads bounded previews away from the main thread. The screenshot
/// history keeps the original file intact; this cache is only for UI tiles.
enum ScreenshotThumbnailLoader {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()

    static func load(for fileURL: URL, maxPixelSize: Int = 640) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(fileURL.standardizedFileURL.path)\u{1F}\(maxPixelSize)" as NSString
        if let cachedImage = cache.object(forKey: key) {
            return makeImage(from: cachedImage)
        }

        let thumbnail = await Task.detached(priority: .utility) {
            thumbnailImage(for: fileURL, maxPixelSize: maxPixelSize)
        }.value

        guard !Task.isCancelled, let thumbnail else { return nil }
        let (cost, overflow) = thumbnail.bytesPerRow.multipliedReportingOverflow(by: thumbnail.height)
        cache.setObject(thumbnail, forKey: key, cost: overflow ? Int.max : cost)
        return makeImage(from: thumbnail)
    }

    private static func makeImage(from thumbnail: CGImage) -> NSImage {
        let representation = NSBitmapImageRep(cgImage: thumbnail)
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(representation)
        return image
    }

    private static func thumbnailImage(for fileURL: URL, maxPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard maxPixelSize > 0,
                  let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ] as CFDictionary
                  ) else {
                return nil
            }

            return thumbnail
        }
    }
}
