import AppKit
import CoreGraphics

/// Draw in point coordinates while allocating an explicit pixel-sized bitmap.
@MainActor
enum PixelPreservingImageRenderer {
    static func render(
        size: CGSize,
        pixelWidth: Int,
        pixelHeight: Int,
        draw: (CGContext) -> Void
    ) -> NSImage? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, pixelWidth > 0, pixelHeight > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(pixelWidth) / size.width, y: CGFloat(pixelHeight) / size.height)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    static func capture(
        base: CGImage,
        screenBounds: CGRect,
        selection: CGRect,
        drawAnnotations: (CGContext) -> Void
    ) -> NSImage? {
        guard screenBounds.width > 0, screenBounds.height > 0,
              selection.width > 0, selection.height > 0 else { return nil }
        let scaleX = CGFloat(base.width) / screenBounds.width
        let scaleY = CGFloat(base.height) / screenBounds.height
        let width = (selection.width * scaleX).rounded(.up)
        let height = (selection.height * scaleY).rounded(.up)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= CGFloat(Int32.max), height <= CGFloat(Int32.max) else { return nil }
        return render(size: selection.size, pixelWidth: Int(width), pixelHeight: Int(height)) { context in
            context.translateBy(x: -selection.minX, y: -selection.minY)
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(base, in: screenBounds)
            context.restoreGState()
            drawAnnotations(context)
        }
    }

    static func transform(_ source: NSImage, rotationDegrees: Int, flipHorizontally: Bool) -> NSImage {
        if rotationDegrees % 360 == 0 && !flipHorizontally { return source }
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let swapAxes = rotationDegrees % 180 != 0
        let size = swapAxes
            ? NSSize(width: source.size.height, height: source.size.width)
            : source.size
        guard size.width > 1, size.height > 1 else { return source }
        let pixelWidth = swapAxes ? cgImage.height : cgImage.width
        let pixelHeight = swapAxes ? cgImage.width : cgImage.height
        return render(size: size, pixelWidth: pixelWidth, pixelHeight: pixelHeight) { context in
            context.translateBy(x: size.width / 2, y: size.height / 2)
            if flipHorizontally { context.scaleBy(x: -1, y: 1) }
            context.rotate(by: -CGFloat(rotationDegrees) * .pi / 180)
            source.draw(
                in: NSRect(x: -source.size.width / 2, y: -source.size.height / 2,
                           width: source.size.width, height: source.size.height),
                from: .zero, operation: .copy, fraction: 1
            )
        } ?? source
    }
}
