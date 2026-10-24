import AppKit
import XCTest
@testable import SnapLex

final class AnnotationTransformTests: XCTestCase {
    func testEveryDrawableAnnotationToolCanBeHitAndMoved() {
        let drawableTools = SnipAnnotationTool.allCases.filter { $0 != .selectMove }

        for tool in drawableTools {
            let item = SnipAnnotationItem(
                tool: tool,
                startPoint: CGPoint(x: 20, y: 30),
                endPoint: CGPoint(x: 100, y: 80),
                points: [CGPoint(x: 20, y: 30), CGPoint(x: 60, y: 80), CGPoint(x: 100, y: 30)],
                color: .systemRed,
                lineWidth: 4,
                text: tool == .text ? "sample" : "",
                counterNumber: 2
            )

            let hitPoint: CGPoint
            switch tool {
            case .text, .counter: hitPoint = item.startPoint
            case .pencil, .marker: hitPoint = item.points[1]
            default: hitPoint = CGPoint(x: 60, y: 55)
            }
            XCTAssertTrue(item.contains(hitPoint, tolerance: 12), "\(tool) should be selectable")

            let moved = item.translated(by: CGPoint(x: 12, y: -7))
            XCTAssertEqual(moved.startPoint, CGPoint(x: 32, y: 23), "\(tool) start point should move")
            XCTAssertEqual(moved.endPoint, CGPoint(x: 112, y: 73), "\(tool) end point should move")
            XCTAssertEqual(moved.points.first, CGPoint(x: 32, y: 23), "\(tool) path should move")
            XCTAssertTrue(
                moved.contains(CGPoint(x: hitPoint.x + 12, y: hitPoint.y - 7), tolerance: 16),
                "\(tool) should remain selectable after moving"
            )

            let center = item.transformCenter
            let scaled = item.scaled(by: 1.5, around: center)
            let scaledHit = CGPoint(
                x: center.x + (hitPoint.x - center.x) * 1.5,
                y: center.y + (hitPoint.y - center.y) * 1.5
            )
            let rotated = scaled.rotated(by: 37)
            let radians = CGFloat(37) * .pi / 180
            let dx = scaledHit.x - center.x
            let dy = scaledHit.y - center.y
            let rotatedHit = CGPoint(
                x: center.x + dx * cos(radians) - dy * sin(radians),
                y: center.y + dx * sin(radians) + dy * cos(radians)
            )
            XCTAssertEqual(rotated.rotationDegrees, 37, accuracy: 0.01, "\(tool) should rotate")
            XCTAssertTrue(rotated.contains(rotatedHit, tolerance: 20), "\(tool) should remain selectable after scale and rotation")
        }
    }

    func testScalingAndRotationUpdateSelectionGeometryForTextAndShapes() {
        let rectangle = SnipAnnotationItem(
            tool: .rectangle,
            startPoint: CGPoint(x: 20, y: 30),
            endPoint: CGPoint(x: 100, y: 60),
            color: .systemBlue,
            lineWidth: 12
        )
        let originalBounds = rectangle.selectionBounds
        let scaled = rectangle.scaled(by: 2, around: rectangle.transformCenter)
        XCTAssertEqual(scaled.selectionBounds.width, originalBounds.width * 2, accuracy: 0.01)
        XCTAssertEqual(scaled.selectionBounds.height, originalBounds.height * 2, accuracy: 0.01)

        let rotated = rectangle.rotated(by: 90)
        XCTAssertEqual(rotated.rotationDegrees, 90, accuracy: 0.01)
        XCTAssertEqual(rotated.selectionBounds.width, originalBounds.height, accuracy: 0.01)
        XCTAssertEqual(rotated.selectionBounds.height, originalBounds.width, accuracy: 0.01)

        let text = SnipAnnotationItem(
            tool: .text,
            startPoint: CGPoint(x: 20, y: 30),
            endPoint: CGPoint(x: 20, y: 30),
            color: .systemRed,
            lineWidth: 3,
            text: "movable text",
            fontSize: 20
        )
        let enlargedText = text.scaled(by: 1.5, around: text.transformCenter)
        XCTAssertEqual(enlargedText.fontSize, 30, accuracy: 0.01)
        XCTAssertEqual(enlargedText.rotationDegrees, text.rotationDegrees)
    }

    func testTransformHandlesCanBeLocatedInBothCanvasCoordinateSystems() {
        let item = SnipAnnotationItem(
            tool: .ellipse,
            startPoint: CGPoint(x: 20, y: 30),
            endPoint: CGPoint(x: 100, y: 70),
            color: .systemGreen,
            lineWidth: 3
        )

        let swiftUIHandle = AnnotationGeometry.point(for: .bottomRight, in: item.selectionBounds, yAxisDown: true)
        XCTAssertEqual(
            AnnotationGeometry.hitTestHandle(at: swiftUIHandle, for: item, yAxisDown: true),
            .resize(.bottomRight)
        )

        let appKitHandle = AnnotationGeometry.point(for: .topLeft, in: item.selectionBounds, yAxisDown: false)
        XCTAssertEqual(
            AnnotationGeometry.hitTestHandle(at: appKitHandle, for: item, yAxisDown: false),
            .resize(.topLeft)
        )
    }
}
