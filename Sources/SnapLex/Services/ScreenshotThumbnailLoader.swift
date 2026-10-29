import AppKit
import ImageIO

/// Shares bounded previews between history tiles. Only ImageIO decoding runs
/// off the main actor; the request registry, cache, and AppKit objects stay here.
@MainActor
enum ScreenshotThumbnailLoader {
    private struct Key: Hashable, Sendable {
        let path: String
        let maxPixelSize: Int
    }

    private struct Request {
        let id = UUID()
        let fileURL: URL
        var subscribers: [UUID: CheckedContinuation<CGImage?, Never>]
        var isRunning = false
    }

    private struct CachedThumbnail {
        let image: CGImage
        let cost: Int
    }

    private static let cacheCostLimit = 32 * 1024 * 1024
    private static let cacheCountLimit = 64
    private static let concurrentDecodeLimit = 2
    private static var cache: [Key: CachedThumbnail] = [:]
    private static var cacheOrder: [Key] = [] // Least recently used first.
    private static var cacheCost = 0
    private static var requests: [Key: Request] = [:]
    private static var pendingKeys: [Key] = []
    private static var runningTasks: [UUID: Task<Void, Never>] = [:]

    static func load(for fileURL: URL, maxPixelSize: Int = 640) async -> NSImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }
        let standardizedURL = fileURL.standardizedFileURL
        let key = Key(path: standardizedURL.path, maxPixelSize: maxPixelSize)
        if let cachedImage = cachedImage(for: key) {
            return makeImage(from: cachedImage)
        }

        let subscriberID = UUID()
        return await withTaskCancellationHandler {
            let thumbnail: CGImage? = await withCheckedContinuation { continuation in
                // Registration does not suspend on the main actor. Cancellation
                // before registration is caught here; cancellation after this
                // check queues cleanup behind this synchronous registration.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                subscribe(
                    key: key,
                    fileURL: standardizedURL,
                    subscriberID: subscriberID,
                    continuation: continuation
                )
            }
            guard !Task.isCancelled, let thumbnail else { return nil }
            return makeImage(from: thumbnail)
        } onCancel: {
            Task { @MainActor in
                cancel(key: key, subscriberID: subscriberID)
            }
        }
    }

    private static func subscribe(
        key: Key,
        fileURL: URL,
        subscriberID: UUID,
        continuation: CheckedContinuation<CGImage?, Never>
    ) {
        if requests[key] != nil {
            requests[key]?.subscribers[subscriberID] = continuation
        } else {
            requests[key] = Request(fileURL: fileURL, subscribers: [subscriberID: continuation])
            pendingKeys.append(key)
        }
        startPendingWork()
    }

    private static func cancel(key: Key, subscriberID: UUID) {
        guard var request = requests[key],
              let continuation = request.subscribers.removeValue(forKey: subscriberID) else { return }

        if request.subscribers.isEmpty {
            requests.removeValue(forKey: key)
            if request.isRunning {
                // ImageIO is synchronous and cannot be interrupted. Keep its
                // slot occupied until completion, but discard its result.
                runningTasks[request.id]?.cancel()
            } else {
                pendingKeys.removeAll { $0 == key }
            }
        } else {
            requests[key] = request
        }
        continuation.resume(returning: nil)
    }

    private static func startPendingWork() {
        while runningTasks.count < concurrentDecodeLimit, !pendingKeys.isEmpty {
            let key = pendingKeys.removeFirst()
            guard var request = requests[key] else { continue }
            request.isRunning = true
            requests[key] = request
            let requestID = request.id
            let fileURL = request.fileURL
            runningTasks[requestID] = Task.detached(priority: .utility) {
                let thumbnail = Task.isCancelled ? nil : thumbnailImage(
                    for: fileURL,
                    maxPixelSize: key.maxPixelSize
                )
                await complete(
                    key: key,
                    requestID: requestID,
                    thumbnail: Task.isCancelled ? nil : thumbnail
                )
            }
        }
    }

    private static func complete(key: Key, requestID: UUID, thumbnail: CGImage?) {
        guard runningTasks.removeValue(forKey: requestID) != nil else { return }
        // A cancelled decode can finish after a replacement request for the
        // same key has arrived. Only its own generation may touch that request.
        if let request = requests[key], request.id == requestID {
            requests.removeValue(forKey: key)
            if let thumbnail {
                insertInCache(thumbnail, for: key)
            }
            for continuation in request.subscribers.values {
                continuation.resume(returning: thumbnail)
            }
        }
        startPendingWork()
    }

    private static func cachedImage(for key: Key) -> CGImage? {
        guard let cached = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return cached.image
    }

    private static func insertInCache(_ image: CGImage, for key: Key) {
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        // Oversized results may be returned to callers, but cannot defeat the
        // cache's hard byte limit. Queued requests retain no decoded images.
        guard !overflow, cost <= cacheCostLimit else { return }
        if let previous = cache.removeValue(forKey: key) {
            cacheCost -= previous.cost
            cacheOrder.removeAll { $0 == key }
        }
        while cache.count >= cacheCountLimit || cacheCost > cacheCostLimit - cost {
            let oldestKey = cacheOrder.removeFirst()
            if let oldest = cache.removeValue(forKey: oldestKey) {
                cacheCost -= oldest.cost
            }
        }
        cache[key] = CachedThumbnail(image: image, cost: cost)
        cacheOrder.append(key)
        cacheCost += cost
    }

    private static func makeImage(from thumbnail: CGImage) -> NSImage {
        let representation = NSBitmapImageRep(cgImage: thumbnail)
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(representation)
        return image
    }

    nonisolated private static func thumbnailImage(for fileURL: URL, maxPixelSize: Int) -> CGImage? {
        autoreleasepool {
            guard maxPixelSize > 0,
                  !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(
                    fileURL as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  !Task.isCancelled,
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
