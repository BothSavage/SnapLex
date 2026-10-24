import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = NSSize(width: 1024, height: 1024)

let image = NSImage(size: canvas, flipped: true) { rect in
    let tile = NSBezierPath(
        roundedRect: rect.insetBy(dx: 24, dy: 24),
        xRadius: 220,
        yRadius: 220
    )
    NSColor(calibratedRed: 0.955, green: 0.960, blue: 0.970, alpha: 1).setFill()
    tile.fill()
    NSColor(calibratedWhite: 0.10, alpha: 0.12).setStroke()
    tile.lineWidth = 8
    tile.stroke()

    let margin: CGFloat = 260
    let arm: CGFloat = 150
    let lineWidth: CGFloat = 66
    let edge = NSBezierPath()
    edge.lineWidth = lineWidth
    edge.lineCapStyle = .round
    edge.lineJoinStyle = .round

    edge.move(to: NSPoint(x: margin, y: margin + arm))
    edge.line(to: NSPoint(x: margin, y: margin))
    edge.line(to: NSPoint(x: margin + arm, y: margin))

    edge.move(to: NSPoint(x: canvas.width - margin - arm, y: margin))
    edge.line(to: NSPoint(x: canvas.width - margin, y: margin))
    edge.line(to: NSPoint(x: canvas.width - margin, y: margin + arm))

    edge.move(to: NSPoint(x: margin, y: canvas.height - margin - arm))
    edge.line(to: NSPoint(x: margin, y: canvas.height - margin))
    edge.line(to: NSPoint(x: margin + arm, y: canvas.height - margin))

    edge.move(to: NSPoint(x: canvas.width - margin - arm, y: canvas.height - margin))
    edge.line(to: NSPoint(x: canvas.width - margin, y: canvas.height - margin))
    edge.line(to: NSPoint(x: canvas.width - margin, y: canvas.height - margin - arm))

    edge.move(to: NSPoint(x: 640, y: 365))
    edge.line(to: NSPoint(x: 385, y: 365))
    edge.line(to: NSPoint(x: 640, y: 660))
    edge.line(to: NSPoint(x: 385, y: 660))

    NSColor(calibratedWhite: 0.075, alpha: 1).setStroke()
    edge.stroke()
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render the SnapLex app icon")
}

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: outputURL, options: .atomic)
