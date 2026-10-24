import AppKit
import Combine
import ImageIO

public struct ScreenshotHistoryRecord: Identifiable, Equatable {
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

    private var directoryURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLex", isDirectory: true)
            .appendingPathComponent("ScreenshotHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private init() {
        reload()
        applyRetentionLimit()
    }

    @discardableResult
    public func save(_ image: NSImage) -> ScreenshotHistoryRecord? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let id = UUID().uuidString
        let url = directoryURL.appendingPathComponent("\(id).png")
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        reload()
        applyRetentionLimit()
        return records.first { $0.id == id }
    }

    public func reload() {
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
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(_ record: ScreenshotHistoryRecord) {
        try? FileManager.default.removeItem(at: record.fileURL)
        reload()
    }

    public func deleteAll() {
        for record in records {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        reload()
    }

    public func applyRetentionLimit() {
        reload()
        let keepCount = max(1, AppSettings.shared.screenshotHistoryLimit)
        for record in records.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        if records.count > keepCount {
            records = Array(records.prefix(keepCount))
        }
    }
}
