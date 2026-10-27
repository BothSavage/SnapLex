import CoreGraphics
import XCTest
@testable import SnapLex

final class ScrollingCaptureStabilityTests: XCTestCase {
    func testActualImageRegistrationExtendsDownwardAndUpwardOffMainThread() async throws {
        let page = try makeTexturedPage()
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 256, height: 320)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 64, width: 256, height: 320)))
        let down = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return ScrollingCaptureEngine.processSlice(second, master: first, previous: first, viewportTop: 0)
        }.value
        let downResult = try XCTUnwrap(down)
        XCTAssertTrue(downResult.extended)
        XCTAssertFalse(downResult.upward)
        XCTAssertEqual(downResult.master.height, 384)
        XCTAssertEqual(downResult.viewportTop, 64)

        let up = await Task.detached {
            ScrollingCaptureEngine.processSlice(first, master: second, previous: second, viewportTop: 0)
        }.value
        let upResult = try XCTUnwrap(up)
        XCTAssertTrue(upResult.extended)
        XCTAssertTrue(upResult.upward)
        XCTAssertEqual(upResult.master.height, 384)
        XCTAssertEqual(upResult.viewportTop, 0)
    }

    func testUnchangedFrameDoesNotDuplicateContent() throws {
        let page = try makeTexturedPage()
        XCTAssertNil(ScrollingCaptureEngine.processSlice(page, master: page, previous: page, viewportTop: 0))
    }

    func testBitmapBudgetRejectsWideTallAndOverflowingAllocations() {
        XCTAssertTrue(ScrollingCaptureEngine.canAllocateStitchedBitmap(width: 1024, height: 20_000))
        XCTAssertFalse(ScrollingCaptureEngine.canAllocateStitchedBitmap(width: 7680, height: 20_000))
        XCTAssertFalse(ScrollingCaptureEngine.canAllocateStitchedBitmap(width: 100, height: 36_001))
        XCTAssertFalse(ScrollingCaptureEngine.canAllocateStitchedBitmap(width: Int.max, height: 2))
        XCTAssertFalse(ScrollingCaptureEngine.canAllocateStitchedBitmap(width: 0, height: 100))
    }

    private func makeTexturedPage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 256, height: 640, bitsPerComponent: 8, bytesPerRow: 256 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let pixels = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        var seed: UInt32 = 42
        for y in 0..<640 {
            for x in 0..<256 {
                seed = seed &* 1664525 &+ 1013904223
                let value = UInt8(truncatingIfNeeded: seed >> 24)
                let offset = y * context.bytesPerRow + x * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return try XCTUnwrap(context.makeImage())
    }
}
