import Foundation
import AppKit

public enum SnipAnnotationTool: String, CaseIterable, Identifiable {
    case selectMove = "移动"
    case rectangle = "矩形"
    case ellipse = "椭圆"
    case line = "直线"
    case arrow = "箭头"
    case pencil = "画笔"
    case marker = "荧光笔"
    case mosaic = "马赛克"
    case blur = "模糊"
    case counter = "序号"
    case text = "文字"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .selectMove: return "cursorarrow.move"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .pencil: return "pencil.tip"
        case .marker: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .blur: return "drop.halffull"
        case .counter: return "1.circle.fill"
        // WeChat-style boxed [T] icon for text annotation
        case .text: return "wechat:text"
        }
    }
}

/// Shared text-annotation font factory used by both the capture canvas and pinned images.
/// Italic is implemented as an oblique font matrix so it also slants CJK glyphs (which have no italic face).
public enum SnipTextStyle {
    public static let defaultFontSize: CGFloat = 20
    public static let minFontSize: CGFloat = 10
    public static let maxFontSize: CGFloat = 120

    public static func font(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard italic else { return base }
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: 1, m12: 0, m21: 0.21, m22: 1, tX: 0, tY: 0)
        let desc = base.fontDescriptor.addingAttributes([.matrix: transform])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    /// Next size step for the `−` / `+` buttons
    public static func steppedSize(_ current: CGFloat, up: Bool) -> CGFloat {
        let steps: [CGFloat] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 80, 96, 120]
        if up {
            return steps.first(where: { $0 > current + 0.5 }) ?? maxFontSize
        }
        return steps.last(where: { $0 < current - 0.5 }) ?? minFontSize
    }
}

public enum SnipColorFormat: String, CaseIterable {
    case hex = "HEX"
    case rgb = "RGB"
    case hsl = "HSL"

    public func next() -> SnipColorFormat {
        switch self {
        case .hex: return .rgb
        case .rgb: return .hsl
        case .hsl: return .hex
        }
    }

    public func format(r: Int, g: Int, b: Int) -> String {
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let rf = Double(r) / 255.0
            let gf = Double(g) / 255.0
            let bf = Double(b) / 255.0
            let maxC = max(rf, gf, bf)
            let minC = min(rf, gf, bf)
            var h = 0.0
            var s = 0.0
            let l = (maxC + minC) / 2.0
            if maxC != minC {
                let d = maxC - minC
                s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
                if maxC == rf {
                    h = (gf - bf) / d + (gf < bf ? 6.0 : 0.0)
                } else if maxC == gf {
                    h = (bf - rf) / d + 2.0
                } else {
                    h = (rf - gf) / d + 4.0
                }
                h /= 6.0
            }
            return String(format: "hsl(%d, %d%%, %d%%)", Int(round(h * 360)), Int(round(s * 100)), Int(round(l * 100)))
        }
    }
}

public struct SnipAnnotationItem: Identifiable {
    public let id = UUID()
    public var tool: SnipAnnotationTool
    public var startPoint: CGPoint
    public var endPoint: CGPoint
    public var points: [CGPoint]
    public var color: NSColor
    public var lineWidth: CGFloat
    public var isFilled: Bool
    public var text: String
    public var counterNumber: Int
    public var fontSize: CGFloat
    public var isBold: Bool
    public var isItalic: Bool

    public init(
        tool: SnipAnnotationTool,
        startPoint: CGPoint,
        endPoint: CGPoint,
        points: [CGPoint] = [],
        color: NSColor,
        lineWidth: CGFloat,
        isFilled: Bool = false,
        text: String = "",
        counterNumber: Int = 1,
        fontSize: CGFloat = SnipTextStyle.defaultFontSize,
        isBold: Bool = false,
        isItalic: Bool = false
    ) {
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.isFilled = isFilled
        self.text = text
        self.counterNumber = counterNumber
        self.fontSize = fontSize
        self.isBold = isBold
        self.isItalic = isItalic
    }

    public var textFont: NSFont {
        SnipTextStyle.font(size: fontSize, bold: isBold, italic: isItalic)
    }

    public var boundingRect: CGRect {
        let minX = min(startPoint.x, endPoint.x)
        let minY = min(startPoint.y, endPoint.y)
        let maxX = max(startPoint.x, endPoint.x)
        let maxY = max(startPoint.y, endPoint.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public struct DetectedWindowInfo: Identifiable, Equatable {
    public let id: String
    public let frameInScreen: CGRect // Cocoa screen coordinates
    public let appName: String
    public let title: String

    public init(id: String = UUID().uuidString, frameInScreen: CGRect, appName: String, title: String) {
        self.id = id
        self.frameInScreen = frameInScreen
        self.appName = appName
        self.title = title
    }

    public var displayLabel: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty || cleanTitle == appName {
            return "\(appName) (\(Int(frameInScreen.width))×\(Int(frameInScreen.height)))"
        }
        let shortTitle = cleanTitle.count > 18 ? String(cleanTitle.prefix(18)) + "…" : cleanTitle
        return "\(appName) · \(shortTitle)"
    }
}

public enum ResizeHandlePosition: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}
