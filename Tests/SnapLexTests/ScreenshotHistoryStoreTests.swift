import AppKit
import Combine
import XCTest
@testable import SnapLex

@MainActor
final class ScreenshotHistoryStoreTests: XCTestCase {
    func testReloadDoesNotPublishAnUnchangedHistory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { 10 })
        await store.waitForPendingOperations()
        var publications = 0
        let subscription = store.$records.dropFirst().sink { _ in publications += 1 }

        store.reload()
        await store.waitForPendingOperations()
        XCTAssertEqual(publications, 0)

        let saved = await store.save(makeImage(width: 12, height: 8))
        XCTAssertNotNil(saved)
        XCTAssertEqual(publications, 1)
        withExtendedLifetime(subscription) {}
    }

    func testSavePersistsPNGDimensionsAndDeleteRemovesFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let store = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { 10 }, now: { timestamp })

        let savedResult = await store.save(makeImage(width: 13, height: 7))
        let saved = try XCTUnwrap(savedResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.fileURL.path))
        XCTAssertEqual(saved.pixelWidth, 13)
        XCTAssertEqual(saved.pixelHeight, 7)

        timestamp = Date(timeIntervalSince1970: 2_000)
        let secondResult = await store.save(makeImage(width: 4, height: 9))
        let second = try XCTUnwrap(secondResult)
        let reopened = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { 10 })
        await reopened.waitForPendingOperations()
        XCTAssertEqual(reopened.records.count, 2)
        XCTAssertEqual(reopened.records.first?.id, second.id)
        XCTAssertEqual(reopened.records.first?.pixelWidth, 4)
        XCTAssertEqual(reopened.records.first?.pixelHeight, 9)

        reopened.delete(reopened.records.first { $0.id == saved.id }!)
        await reopened.waitForPendingOperations()
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.fileURL.path))
        XCTAssertEqual(reopened.records.map(\.id), [second.id])
        reopened.deleteAll()
        await reopened.waitForPendingOperations()
        XCTAssertTrue(reopened.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testRetentionKeepsNewestFilesAndRespondsToPreferenceChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limit = 2
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let store = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { limit }, now: { timestamp })

        let oldestResult = await store.save(makeImage(width: 5, height: 5))
        let oldest = try XCTUnwrap(oldestResult)
        timestamp = Date(timeIntervalSince1970: 2_000)
        let middleResult = await store.save(makeImage(width: 5, height: 5))
        let middle = try XCTUnwrap(middleResult)
        timestamp = Date(timeIntervalSince1970: 3_000)
        let newestResult = await store.save(makeImage(width: 5, height: 5))
        let newest = try XCTUnwrap(newestResult)

        XCTAssertEqual(Set(store.records.map(\.id)), Set([middle.id, newest.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.fileURL.path))

        limit = 1
        store.applyRetentionLimit()
        await store.waitForPendingOperations()
        XCTAssertEqual(store.records.map(\.id), [newest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: middle.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.fileURL.path))
    }

    func testInvalidImageDoesNotCreateARecordOrFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { 10 })

        let result = await store.save(NSImage())
        await store.waitForPendingOperations()
        XCTAssertNil(result)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testThumbnailLoaderCreatesBoundedPreviewWithoutChangingOriginal() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("large.png")
        let sourceImage = makeImage(width: 2_400, height: 1_200)
        let sourceBitmap = try XCTUnwrap(sourceImage.representations.first as? NSBitmapImageRep)
        let pngData = try XCTUnwrap(sourceBitmap.representation(using: .png, properties: [:]))
        try pngData.write(to: fileURL)

        let loadedPreview = await ScreenshotThumbnailLoader.load(for: fileURL, maxPixelSize: 640)
        let preview = try XCTUnwrap(loadedPreview)
        let previewBitmap = try XCTUnwrap(preview.representations.first as? NSBitmapImageRep)

        XCTAssertEqual(previewBitmap.pixelsWide, 640)
        XCTAssertEqual(previewBitmap.pixelsHigh, 320)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(data: pngData)).pixelsWide, 2_400)
        let cachedPreview = await ScreenshotThumbnailLoader.load(for: fileURL, maxPixelSize: 640)
        let cachedBitmap = try XCTUnwrap(cachedPreview?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(cachedBitmap.pixelsWide, 640)

        let smallerPreview = await ScreenshotThumbnailLoader.load(for: fileURL, maxPixelSize: 320)
        let smallerBitmap = try XCTUnwrap(smallerPreview?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(smallerBitmap.pixelsWide, 320)
    }

    func testBlockedDiskQueueDoesNotBlockCaptureAndClearCannotResurrectPendingSaves() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "SnapLexScreenshotHistoryTests.blocked")
        queue.suspend()
        let store = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { 10 }, ioQueue: queue)

        // With disk deliberately unavailable, these calls must return on the
        // main actor. Clear must run after both pending writes in the same FIFO.
        store.saveInBackground(makeImage(width: 17, height: 9))
        store.saveInBackground(makeImage(width: 19, height: 11))
        store.deleteAll()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        queue.resume()
        await store.waitForPendingOperations()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testQueuedRetentionUsesLatestFilesAndSurvivesReload() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "SnapLexScreenshotHistoryTests.retention")
        queue.suspend()
        var limit = 10
        var timestamp = Date(timeIntervalSince1970: 1000)
        let store = ScreenshotHistoryStore(directoryURL: directory, retentionLimit: { limit }, now: { timestamp }, ioQueue: queue)
        store.saveInBackground(makeImage(width: 17, height: 9))
        timestamp = Date(timeIntervalSince1970: 2000)
        store.saveInBackground(makeImage(width: 19, height: 11))
        limit = 1
        store.applyRetentionLimit()
        queue.resume()
        await store.waitForPendingOperations()

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.pixelWidth, 19)
        store.reload()
        await store.waitForPendingOperations()
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.pixelWidth, 19)
    }

    private func makeImage(width: Int, height: Int) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = graphicsContext
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapLexScreenshotHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
