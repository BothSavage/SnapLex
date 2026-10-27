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
    public var rotationDegrees: CGFloat

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
        isItalic: Bool = false,
        rotationDegrees: CGFloat = 0
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
        self.rotationDegrees = rotationDegrees
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

    public var transformCenter: CGPoint {
        CGPoint(x: unrotatedVisualBounds.midX, y: unrotatedVisualBounds.midY)
    }

    /// Bounds used for selection, hit testing, and transform handles.
    public var selectionBounds: CGRect {
        let visual = unrotatedVisualBounds.insetBy(dx: -selectionPadding, dy: -selectionPadding)
        guard abs(rotationDegrees.truncatingRemainder(dividingBy: 360)) > 0.001 else { return visual }
        let corners = [
            CGPoint(x: visual.minX, y: visual.minY),
            CGPoint(x: visual.maxX, y: visual.minY),
            CGPoint(x: visual.maxX, y: visual.maxY),
            CGPoint(x: visual.minX, y: visual.maxY)
        ].map { Self.rotate($0, around: transformCenter, by: rotationDegrees) }
        return Self.bounds(of: corners)
    }

    public func contains(_ point: CGPoint, tolerance: CGFloat = 8) -> Bool {
        let localPoint = Self.rotate(point, around: transformCenter, by: -rotationDegrees)
        let bounds = unrotatedVisualBounds
        let slop = max(tolerance, lineWidth / 2 + 3)

        switch tool {
        case .selectMove:
            return false
        case .ellipse:
            let expanded = bounds.insetBy(dx: -slop, dy: -slop)
            guard expanded.width > 0, expanded.height > 0 else { return false }
            let dx = (localPoint.x - expanded.midX) / (expanded.width / 2)
            let dy = (localPoint.y - expanded.midY) / (expanded.height / 2)
            return dx * dx + dy * dy <= 1
        case .line:
            return Self.distance(localPoint, toSegmentFrom: startPoint, to: endPoint) <= slop
        case .arrow:
            let shaftHit = Self.distance(localPoint, toSegmentFrom: startPoint, to: endPoint) <= slop + lineWidth
            let headRadius = max(12, lineWidth * 3.8) + slop
            return shaftHit || hypot(localPoint.x - endPoint.x, localPoint.y - endPoint.y) <= headRadius
        case .pencil, .marker:
            let path = points.count > 1 ? points : [startPoint, endPoint]
            return zip(path, path.dropFirst()).contains {
                Self.distance(localPoint, toSegmentFrom: $0.0, to: $0.1) <= slop + (tool == .marker ? max(7, lineWidth * 1.25) : 0)
            }
        case .counter:
            let radius = max(13, lineWidth * 3)
            return hypot(localPoint.x - startPoint.x, localPoint.y - startPoint.y) <= radius + slop
        case .text:
            return bounds.insetBy(dx: -slop, dy: -slop).contains(localPoint)
        case .rectangle, .mosaic, .blur:
            return bounds.insetBy(dx: -slop, dy: -slop).contains(localPoint)
        }
    }

    public func translated(by delta: CGPoint) -> SnipAnnotationItem {
        var copy = self
        copy.startPoint = CGPoint(x: startPoint.x + delta.x, y: startPoint.y + delta.y)
        copy.endPoint = CGPoint(x: endPoint.x + delta.x, y: endPoint.y + delta.y)
        copy.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return copy
    }

    public func scaled(by factor: CGFloat, around anchor: CGPoint) -> SnipAnnotationItem {
        let safeFactor = min(10, max(0.1, factor))
        var copy = self
        copy.startPoint = Self.scale(startPoint, around: anchor, by: safeFactor)
        copy.endPoint = Self.scale(endPoint, around: anchor, by: safeFactor)
        copy.points = points.map { Self.scale($0, around: anchor, by: safeFactor) }
        copy.lineWidth = max(0.5, min(160, lineWidth * safeFactor))
        copy.fontSize = max(6, min(600, fontSize * safeFactor))
        return copy
    }

    public func rotated(by deltaDegrees: CGFloat) -> SnipAnnotationItem {
        var copy = self
        copy.rotationDegrees = (rotationDegrees + deltaDegrees).truncatingRemainder(dividingBy: 360)
        return copy
    }

    private var unrotatedVisualBounds: CGRect {
        switch tool {
        case .pencil, .marker:
            return Self.bounds(of: points.count > 1 ? points : [startPoint, endPoint])
        case .counter:
            let radius = max(13, lineWidth * 3)
            return CGRect(x: startPoint.x - radius, y: startPoint.y - radius, width: radius * 2, height: radius * 2)
        case .text:
            let size = (text as NSString).size(withAttributes: [.font: textFont])
            let height = max(fontSize, size.height)
            return CGRect(
                x: startPoint.x,
                y: startPoint.y - height / 2,
                width: max(10, size.width),
                height: height
            )
        default:
            return boundingRect
        }
    }

    private var selectionPadding: CGFloat {
        if tool == .marker {
            return max(7, lineWidth * 1.75)
        }
        return max(5, lineWidth / 2)
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        let minX = points.dropFirst().reduce(first.x) { min($0, $1.x) }
        let maxX = points.dropFirst().reduce(first.x) { max($0, $1.x) }
        let minY = points.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxY = points.dropFirst().reduce(first.y) { max($0, $1.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rotate(_ point: CGPoint, around center: CGPoint, by degrees: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cos(radians) - dy * sin(radians),
            y: center.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    private static func scale(_ point: CGPoint, around anchor: CGPoint, by factor: CGFloat) -> CGPoint {
        CGPoint(
            x: anchor.x + (point.x - anchor.x) * factor,
            y: anchor.y + (point.y - anchor.y) * factor
        )
    }

    private static func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.001 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }
}

public enum AnnotationTransformHandle: Equatable {
    case resize(ResizeHandlePosition)
    case rotate
}

public enum AnnotationGeometry {
    public static func point(
        for handle: ResizeHandlePosition,
        in rect: CGRect,
        yAxisDown: Bool
    ) -> CGPoint {
        let top = yAxisDown ? rect.minY : rect.maxY
        let bottom = yAxisDown ? rect.maxY : rect.minY
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: top)
        case .top: return CGPoint(x: rect.midX, y: top)
        case .topRight: return CGPoint(x: rect.maxX, y: top)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: bottom)
        case .bottom: return CGPoint(x: rect.midX, y: bottom)
        case .bottomLeft: return CGPoint(x: rect.minX, y: bottom)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    public static func oppositeAnchor(
        for handle: ResizeHandlePosition,
        in rect: CGRect,
        yAxisDown: Bool
    ) -> CGPoint {
        let opposite: ResizeHandlePosition
        switch handle {
        case .topLeft: opposite = .bottomRight
        case .top: opposite = .bottom
        case .topRight: opposite = .bottomLeft
        case .right: opposite = .left
        case .bottomRight: opposite = .topLeft
        case .bottom: opposite = .top
        case .bottomLeft: opposite = .topRight
        case .left: opposite = .right
        }
        return point(for: opposite, in: rect, yAxisDown: yAxisDown)
    }

    public static func rotateHandlePoint(for item: SnipAnnotationItem, yAxisDown: Bool) -> CGPoint {
        let bounds = item.selectionBounds
        return CGPoint(
            x: bounds.midX,
            y: yAxisDown ? bounds.minY - 24 : bounds.maxY + 24
        )
    }

    public static func hitTestHandle(
        at point: CGPoint,
        for item: SnipAnnotationItem,
        yAxisDown: Bool,
        radius: CGFloat = 11
    ) -> AnnotationTransformHandle? {
        let rotatePoint = rotateHandlePoint(for: item, yAxisDown: yAxisDown)
        if hypot(point.x - rotatePoint.x, point.y - rotatePoint.y) <= radius + 2 {
            return .rotate
        }
        for handle in ResizeHandlePosition.allCases {
            let handlePoint = Self.point(for: handle, in: item.selectionBounds, yAxisDown: yAxisDown)
            if hypot(point.x - handlePoint.x, point.y - handlePoint.y) <= radius {
                return .resize(handle)
            }
        }
        return nil
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

public enum ResizeHandlePosition: CaseIterable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}
