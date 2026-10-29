import Foundation
import AppKit
import Vision
import CoreGraphics

public struct OCRTextBlock: Identifiable, Sendable {
    public let id = UUID()
    public var originalText: String
    public var translatedText: String
    /// Normalized bounding box in Vision coordinates (origin at bottom-left, 0...1)
    public var normalizedRect: CGRect

    public init(originalText: String, translatedText: String = "", normalizedRect: CGRect) {
        self.originalText = originalText
        self.translatedText = translatedText
        self.normalizedRect = normalizedRect
    }
}

public struct InPlaceOCRResult: Sendable {
    public let blocks: [OCRTextBlock]
    public let fullOriginalText: String
    public let fullTranslatedText: String
    public let renderedTranslatedImage: NSImage
}

public final class InPlaceOCRService: @unchecked Sendable {
    public static let shared = InPlaceOCRService()

    private init() {}

    /// Step 1: Recognize text blocks with bounding boxes from an NSImage, merging lines into natural paragraph blocks
    @MainActor
    public func recognizeBlocks(in image: NSImage) async -> [OCRTextBlock] {
        guard !Task.isCancelled,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let observations = await VisionTextRecognition.recognize(
            cgImage, languages: ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
        )
        guard !observations.isEmpty else { return [] }

        struct RawLine {
            let text: String
            let box: CGRect // Vision normalized (0..1, bottom-left origin)
        }

        var rawLines: [RawLine] = []
        for obs in observations {
            if let top = obs.topCandidates(1).first {
                let str = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !str.isEmpty {
                    rawLines.append(RawLine(text: str, box: obs.boundingBox))
                }
            }
        }

        // Sort top-to-bottom (descending maxY in Vision bottom-left coords), then left-to-right
        rawLines.sort { a, b in
            if abs(a.box.maxY - b.box.maxY) > 0.014 {
                return a.box.maxY > b.box.maxY
            }
            return a.box.minX < b.box.minX
        }

        // Merge vertically adjacent lines that belong to the same paragraph block
        var mergedBlocks: [OCRTextBlock] = []
        for line in rawLines {
            if let lastIdx = mergedBlocks.indices.last {
                let prev = mergedBlocks[lastIdx]
                let prevBox = prev.normalizedRect
                let curBox = line.box

                let lineHeight = max(0.012, min(prevBox.height, curBox.height))
                let verticalGap = prevBox.minY - curBox.maxY
                let sameLeftMargin = abs(prevBox.minX - curBox.minX) < 0.045
                let similarHeight = abs(prevBox.height - curBox.height) < lineHeight * 0.65

                // Merge if on the immediate next line of the same paragraph
                if verticalGap >= -lineHeight * 0.35 &&
                   verticalGap <= lineHeight * 0.85 &&
                   sameLeftMargin &&
                   similarHeight {
                    let joiner = Self.shouldJoinWithSpace(prev.originalText, line.text) ? " " : ""
                    mergedBlocks[lastIdx].originalText += joiner + line.text
                    mergedBlocks[lastIdx].normalizedRect = prevBox.union(curBox)
                    continue
                }
            }
            mergedBlocks.append(OCRTextBlock(originalText: line.text, normalizedRect: line.box))
        }

        return mergedBlocks
    }

    // MARK: - In-Place Overlay Image Renderer (Matches User's Image 2!)

    @MainActor
    public static func renderTranslatedBlocksOnImage(baseImage: NSImage, blocks: [OCRTextBlock]) -> NSImage {
        let size = baseImage.size
        guard size.width > 4, size.height > 4,
              let cgImage = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return baseImage
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return PixelPreservingImageRenderer.render(size: size, pixelWidth: cgImage.width, pixelHeight: cgImage.height) { _ in
            baseImage.draw(in: NSRect(origin: .zero, size: size))
            for block in blocks {
                let textToDraw = block.translatedText.isEmpty ? block.originalText : block.translatedText
                guard !textToDraw.isEmpty else { continue }

                // Vision coordinates and the output bitmap both use a bottom-left origin.
                let rect = CGRect(
                    x: block.normalizedRect.minX * size.width,
                    y: block.normalizedRect.minY * size.height,
                    width: block.normalizedRect.width * size.width,
                    height: block.normalizedRect.height * size.height
                ).insetBy(dx: -2, dy: -1.5)

                guard rect.width >= 10, rect.height >= 8 else { continue }
                let (bgColor, fgColor) = sampleBackgroundAndTextColors(in: rect, imageSize: size, bitmap: bitmapRep)
                let bgPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                bgColor.setFill()
                bgPath.fill()
                drawFittedText(textToDraw, in: rect.insetBy(dx: 2, dy: 1), textColor: fgColor)
            }
        } ?? baseImage
    }

    private static func sampleBackgroundAndTextColors(
        in rect: CGRect,
        imageSize: NSSize,
        bitmap: NSBitmapImageRep
    ) -> (NSColor, NSColor) {
        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, imageSize.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, imageSize.height)

        // Sample 8 border points around the perimeter of `rect`
        let samplePoints: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY)
        ]

        var rSum: CGFloat = 0
        var gSum: CGFloat = 0
        var bSum: CGFloat = 0
        var count: CGFloat = 0

        for pt in samplePoints {
            let px = max(0, min(bitmap.pixelsWide - 1, Int(round(pt.x * scaleX))))
            let py = max(0, min(bitmap.pixelsHigh - 1, Int(round((imageSize.height - pt.y) * scaleY))))
            if let c = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) {
                rSum += c.redComponent
                gSum += c.greenComponent
                bSum += c.blueComponent
                count += 1
            }
        }

        guard count > 0 else {
            return (.white, NSColor(calibratedWhite: 0.12, alpha: 1.0))
        }

        let r = rSum / count
        let g = gSum / count
        let b = bSum / count
        let bgColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 0.97)

        // Calculate perceived luminance to pick crisp dark or light text color
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let fgColor = luminance > 0.52
            ? NSColor(calibratedWhite: 0.10, alpha: 0.96)
            : NSColor(calibratedWhite: 0.96, alpha: 0.96)

        return (bgColor, fgColor)
    }

    private static func drawFittedText(_ text: String, in rect: CGRect, textColor: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5

        // Estimate starting font size from box height & character length
        let maxFontSize = min(28.0, max(10.0, rect.height * 0.78))
        let minFontSize: CGFloat = 9.0
        var chosenAttributes: [NSAttributedString.Key: Any] = [:]

        var fontSize = maxFontSize
        while fontSize >= minFontSize {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
            let bound = (text as NSString).boundingRect(
                with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            chosenAttributes = attrs
            if bound.height <= rect.height * 1.12 {
                break
            }
            fontSize -= 1.0
        }

        let bound = (text as NSString).boundingRect(
            with: NSSize(width: rect.width, height: rect.height * 1.25),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: chosenAttributes
        )
        // Vertically center if single-line
        let drawY = rect.minY + max(0, (rect.height - bound.height) / 2.0)
        let drawRect = CGRect(x: rect.minX, y: drawY, width: rect.width, height: min(rect.height * 1.2, bound.height + 4))
        (text as NSString).draw(in: drawRect, withAttributes: chosenAttributes)
    }

    private static func shouldJoinWithSpace(_ left: String, _ right: String) -> Bool {
        guard let lastLeft = left.unicodeScalars.last,
              let firstRight = right.unicodeScalars.first else {
            return false
        }
        return lastLeft.isASCII && firstRight.isASCII
    }
}
