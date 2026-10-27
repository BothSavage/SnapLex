import AppKit
import ImageIO

/// Loads bounded PNG previews away from the main thread. The screenshot
/// history keeps the original file intact; this cache is only for UI tiles.
enum ScreenshotThumbnailLoader {
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()

    static func load(for fileURL: URL, maxPixelSize: Int = 640) async -> NSImage? {
        let key = "\(fileURL.standardizedFileURL.path)\u{1F}\(maxPixelSize)" as NSString
        if let cachedData = cache.object(forKey: key) {
            return NSImage(data: cachedData as Data)
        }

        let data = await Task.detached(priority: .utility) {
            thumbnailData(for: fileURL, maxPixelSize: maxPixelSize)
        }.value

        guard !Task.isCancelled, let data else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return NSImage(data: data)
    }

    private static func thumbnailData(for fileURL: URL, maxPixelSize: Int) -> Data? {
        autoreleasepool {
            guard maxPixelSize > 0,
                  let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ] as CFDictionary
                  ) else {
                return nil
            }

            let bitmap = NSBitmapImageRep(cgImage: thumbnail)
            return bitmap.representation(using: .png, properties: [:])
        }
    }
}
