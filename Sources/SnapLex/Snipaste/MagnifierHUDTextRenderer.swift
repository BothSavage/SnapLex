import CoreGraphics
import CoreText
import Foundation

enum MagnifierHUDTextRenderer {
    static func draw(
        _ text: String,
        fontName: String,
        fontSize: CGFloat,
        color: CGColor,
        at point: CGPoint,
        in context: CGContext
    ) {
        guard !text.isEmpty, fontSize.isFinite, fontSize > 0 else { return }

        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attributedString = CFAttributedStringCreate(
            nil,
            text as CFString,
            attributes as CFDictionary
        ) else { return }

        let line = CTLineCreateWithAttributedString(attributedString)
        context.saveGState()
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
