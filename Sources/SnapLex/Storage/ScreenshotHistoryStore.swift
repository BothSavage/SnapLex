import AppKit
import Combine
import ImageIO
import os

public struct ScreenshotHistoryRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let fileURL: URL
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
}

@MainActor
public final class ScreenshotHistoryStore: ObservableObject {
    public static let shared = ScreenshotHistoryStore()

    @Published public private(set) var records: [ScreenshotHistoryRecord] = []

    private let files: ScreenshotHistoryFiles
    private let ioQueue: DispatchQueue
    private let retentionLimit: () -> Int
    private let now: () -> Date
    private let screenshotLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnapLex",
        category: "ScreenshotHistory"
    )

    private static var productionDirectoryURL: URL {
        if let testRoot = LocalTestDataPaths.rootDirectory {
            return testRoot
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("SnapLex", isDirectory: true)
                .appendingPathComponent("ScreenshotHistory", isDirectory: true)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLex", isDirectory: true)
            .appendingPathComponent("ScreenshotHistory", isDirectory: true)
        return directory
    }

    private convenience init() {
        self.init(
            directoryURL: Self.productionDirectoryURL,
            retentionLimit: { AppSettings.shared.screenshotHistoryLimit },
            now: { Date() }
        )
    }

    /// Isolated directory and policy injection for tests. The app uses the
    /// Application Support directory only through the private convenience init.
    init(
        directoryURL: URL,
        retentionLimit: @escaping () -> Int,
        now: @escaping () -> Date = { Date() },
        ioQueue: DispatchQueue = DispatchQueue(label: "io.github.snaplex.screenshot-history", qos: .utility)
    ) {
        self.files = ScreenshotHistoryFiles(directoryURL: directoryURL)
        self.ioQueue = ioQueue
        self.retentionLimit = retentionLimit
        self.now = now
        reload()
    }

    /// Snapshot AppKit's image on the main actor, then encode and write on a
    /// serial worker. Capture actions can close their overlay immediately.
    public func saveInBackground(_ image: NSImage) {
        enqueueSave(image)
    }

    @discardableResult
    public func save(_ image: NSImage) async -> ScreenshotHistoryRecord? {
        await withCheckedContinuation { continuation in
            enqueueSave(image) { continuation.resume(returning: $0) }
        }
    }

    private func enqueueSave(_ image: NSImage, completion: ((ScreenshotHistoryRecord?) -> Void)? = nil) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion?(nil)
            return
        }
        let createdAt = now()
        let limit = max(1, retentionLimit())
        let files = files
        let logger = screenshotLogger
        ioQueue.async { [weak self] in
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let saved = autoreleasepool { files.save(cgImage, createdAt: createdAt, limit: limit) }
            let snapshot = files.records
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            logger.debug("screenshot history save completed success=\(saved != nil, privacy: .public) milliseconds=\(milliseconds, privacy: .public)")
            DispatchQueue.main.async {
                self?.records = snapshot
                completion?(saved)
            }
        }
    }

    public func reload() {
        let limit = max(1, retentionLimit())
        updateFiles { files in
            files.reload()
            files.applyRetentionLimit(limit)
        }
    }

    public func delete(_ record: ScreenshotHistoryRecord) {
        updateFiles { $0.delete(record) }
    }

    public func deleteAll() {
        updateFiles { files in
            for record in files.records { files.delete(record) }
        }
    }

    public func applyRetentionLimit() {
        let limit = max(1, retentionLimit())
        updateFiles { $0.applyRetentionLimit(limit) }
    }

    /// Also waits for the queued UI snapshots, so callers observe committed
    /// state. Every mutation uses the same FIFO, including clear and retention.
    func waitForPendingOperations() async {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func updateFiles(_ operation: @escaping @Sendable (ScreenshotHistoryFiles) -> Void) {
        let files = files
        ioQueue.async { [weak self] in
            autoreleasepool { operation(files) }
            let snapshot = files.records
            DispatchQueue.main.async { self?.records = snapshot }
        }
    }
}

/// Accessed exclusively on its store's serial I/O queue. Saves insert metadata
/// directly instead of re-reading every existing PNG after each capture.
private final class ScreenshotHistoryFiles: @unchecked Sendable {
    let directoryURL: URL
    private(set) var records: [ScreenshotHistoryRecord] = []

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func reload() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        records = urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
                let properties = imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                return ScreenshotHistoryRecord(
                    id: url.deletingPathExtension().lastPathComponent,
                    fileURL: url,
                    createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                    pixelWidth: width,
                    pixelHeight: height
                )
            }
            .sorted { $0.createdAt == $1.createdAt ? $0.id > $1.id : $0.createdAt > $1.createdAt }
    }

    func save(_ image: CGImage, createdAt: Date, limit: Int) -> ScreenshotHistoryRecord? {
        let id = UUID().uuidString
        let url = directoryURL.appendingPathComponent("\(id).png")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        do {
            try (data as Data).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        let record = ScreenshotHistoryRecord(
            id: id, fileURL: url, createdAt: createdAt,
            pixelWidth: image.width, pixelHeight: image.height
        )
        let index = records.firstIndex { $0.createdAt <= createdAt } ?? records.endIndex
        records.insert(record, at: index)
        applyRetentionLimit(limit)
        return record
    }

    func delete(_ record: ScreenshotHistoryRecord) {
        // Only delete files owned by this store, even when passed stale input.
        guard records.contains(where: { $0.id == record.id && $0.fileURL == record.fileURL }) else { return }
        do {
            try FileManager.default.removeItem(at: record.fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // A file removed externally should disappear from history too.
        } catch {
            return
        }
        records.removeAll { $0.id == record.id }
    }

    func applyRetentionLimit(_ limit: Int) {
        for record in records.dropFirst(max(1, limit)) { delete(record) }
    }
}
