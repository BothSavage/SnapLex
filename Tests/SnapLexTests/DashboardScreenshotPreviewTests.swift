import AppKit
import SwiftUI
import XCTest
@testable import SnapLex

@MainActor
final class DashboardScreenshotPreviewTests: XCTestCase {
    func testWideScreenshotThumbnailStaysInsideItsGridCell() throws {
        let sourceImage = NSImage(size: NSSize(width: 1_600, height: 900))
        sourceImage.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: sourceImage.size).fill()
        sourceImage.unlockFocus()

        let host = NSHostingView(
            rootView: HStack(spacing: 0) {
                DashboardScreenshotPreview(image: sourceImage, height: 104)
                    .frame(width: 120, height: 120)
                Color.blue
                    .frame(width: 40, height: 120)
            }
        )
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 120)
        host.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        let outsideTile = try XCTUnwrap(
            bitmap.colorAt(x: Int(140 * scaleX), y: Int(60 * scaleY))?.usingColorSpace(.deviceRGB)
        )

        XCTAssertGreaterThan(outsideTile.blueComponent, outsideTile.redComponent)
        XCTAssertGreaterThan(outsideTile.blueComponent, outsideTile.greenComponent)
    }
}
