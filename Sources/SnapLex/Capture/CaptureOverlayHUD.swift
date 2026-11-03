import AppKit
import CoreText

/// All capture coordinates are in AppKit points; keyboard steps and samples use source pixels.
enum CapturePixelGeometry {
    static func pixel(at point: CGPoint, imageSize: CGSize, imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: min(imageSize.width - 1, max(0, floor((point.x - imageRect.minX) * imageSize.width / imageRect.width))),
            y: min(imageSize.height - 1, max(0, floor((imageRect.maxY - point.y) * imageSize.height / imageRect.height)))
        )
    }

    static func step(imageSize: CGSize, imageRect: CGRect) -> CGSize {
        CGSize(width: imageRect.width / imageSize.width, height: imageRect.height / imageSize.height)
    }

    static func moving(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(bounds.minX, rect.minX + delta.x), max(bounds.minX, bounds.maxX - rect.width)),
            y: min(max(bounds.minY, rect.minY + delta.y), max(bounds.minY, bounds.maxY - rect.height)),
            width: rect.width,
            height: rect.height
        )
    }

    static func hudFrame(at cursor: CGPoint, size: CGSize, within bounds: CGRect, avoiding guide: CGRect) -> CGRect {
        let safe = bounds.insetBy(dx: 12, dy: 12)
        let candidates = [
            CGPoint(x: cursor.x + 22, y: cursor.y - size.height - 22),
            CGPoint(x: cursor.x - size.width - 22, y: cursor.y - size.height - 22),
            CGPoint(x: cursor.x + 22, y: cursor.y + 22),
            CGPoint(x: cursor.x - size.width - 22, y: cursor.y + 22)
        ].map { origin in
            CGRect(
                x: max(safe.minX, min(origin.x, safe.maxX - size.width)),
                y: max(safe.minY, min(origin.y, safe.maxY - size.height)),
                width: size.width, height: size.height
            )
        }
        return candidates.first { !$0.intersects(guide) && !$0.insetBy(dx: -8, dy: -8).contains(cursor) }
            ?? candidates.first { !$0.insetBy(dx: -8, dy: -8).contains(cursor) }
            ?? candidates[0]
    }
}

@MainActor
enum CaptureShortcutGuideRenderer {
    private static var rows: [([String], String)] {
        [
            (["W", "A", "S", "D"], L10n.string("光标移动 1 像素")),
            (["↑", "↓", "←", "→"], L10n.string("选区移动 1 像素")),
            (["⌘", "A"], L10n.string("选择当前屏幕 / 全屏")),
            (["["], L10n.string("回放截图历史")),
            (["]"], L10n.string("显示 / 隐藏截取的鼠标指针"))
        ]
    }

    static func frame(in bounds: CGRect, bottomInset: CGFloat) -> CGRect {
        let textWidth = rows.map { width(of: $0.1, size: 11) }.max() ?? 0
        return CGRect(
            x: bounds.minX + 16, y: bounds.minY + max(16, bottomInset + 12),
            width: min(bounds.width - 32, ceil(textWidth) + 112), height: 150
        )
    }

    static func draw(in context: CGContext, frame: CGRect) {
        context.saveGState()
        let path = CGPath(roundedRect: frame, cornerWidth: 9, cornerHeight: 9, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.075, alpha: 0.94).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.clip(to: frame.insetBy(dx: 6, dy: 6))

        for (index, row) in rows.enumerated() {
            let y = frame.maxY - 29 - CGFloat(index) * 27
            for (keyIndex, key) in row.0.enumerated() {
                let keyRect = CGRect(x: frame.minX + 12 + CGFloat(keyIndex) * 20, y: y - 3, width: 17, height: 18)
                context.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
                let keyPath = CGPath(roundedRect: keyRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                context.addPath(keyPath)
                context.drawPath(using: .fillStroke)
                MagnifierHUDTextRenderer.draw(
                    key, fontName: "HelveticaNeue-Medium", fontSize: 11, color: NSColor.white.cgColor,
                    at: CGPoint(x: keyRect.midX - width(of: key, size: 11) / 2, y: y), in: context
                )
            }
            MagnifierHUDTextRenderer.draw(
                row.1, fontName: "HelveticaNeue-Medium", fontSize: 11,
                color: NSColor.white.withAlphaComponent(0.95).cgColor,
                at: CGPoint(x: frame.minX + 98, y: y), in: context
            )
        }
        context.restoreGState()
    }

    static func width(of text: String, size: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil))
    }
}
