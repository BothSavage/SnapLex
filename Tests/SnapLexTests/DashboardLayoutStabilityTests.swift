import AppKit
import SwiftUI
import XCTest
@testable import SnapLex

@MainActor
final class DashboardLayoutStabilityTests: XCTestCase {
    func testEveryDashboardRouteKeepsAppKitFramesFiniteAndNonnegative() async {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLex-DashboardLayout-\(UUID().uuidString)", isDirectory: true)
        let translationStore = TranslationHistoryStore(
            databaseURL: temporaryRoot.appendingPathComponent("translation-history.sqlite3"),
            shouldRecordSelection: { true },
            shouldRecordScreenshot: { true }
        )
        let screenshotStore = ScreenshotHistoryStore(
            directoryURL: temporaryRoot.appendingPathComponent("screenshots", isDirectory: true),
            retentionLimit: { 10 }
        )
        await translationStore.waitForPendingWrites()
        let navigation = DashboardNavigation()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let host = NSHostingView(rootView: DashboardView(
            navigation: navigation,
            translationStore: translationStore,
            screenshotStore: screenshotStore
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 820)
        host.layoutSubtreeIfNeeded()

        for section in DashboardSection.allCases {
            navigation.select(section)

            // Let SwiftUI's short section-selection animation and deferred
            // layout work settle before auditing the native view tree.
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            let invalidFrames = Self.invalidFrames(in: host)
            XCTAssertTrue(
                invalidFrames.isEmpty,
                "Dashboard route \(section.rawValue) produced non-finite or negative AppKit frames: \(invalidFrames.joined(separator: "; "))"
            )
        }
    }

    private static func invalidFrames(in root: NSView) -> [String] {
        var invalid: [String] = []
        var pending = [root]

        while let view = pending.popLast() {
            let frame = view.frame
            if !frame.width.isFinite || !frame.height.isFinite || frame.width < 0 || frame.height < 0 {
                invalid.append("\(type(of: view)) frame=\(NSStringFromRect(frame))")
            }
            pending.append(contentsOf: view.subviews)
        }

        return invalid
    }
}
