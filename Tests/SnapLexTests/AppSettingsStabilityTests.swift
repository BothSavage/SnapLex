import Combine
import XCTest
@testable import SnapLex

@MainActor
final class AppSettingsStabilityTests: XCTestCase {
    func testRetentionChangesDoNotReenterPublishedSetterAndPersistClampedValues() throws {
        let suite = "SnapLexSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var retentionUpdates = 0
        let settings = AppSettings(defaults: defaults, screenshotRetentionChanged: { retentionUpdates += 1 })
        var notifications = 0
        let observer = settings.objectWillChange.sink { notifications += 1 }
        defer { observer.cancel() }

        for value in 101...150 { settings.screenshotHistoryLimit = value }
        XCTAssertEqual(settings.screenshotHistoryLimit, 150)
        XCTAssertEqual(notifications, 50)
        XCTAssertEqual(retentionUpdates, 50)
        settings.screenshotHistoryLimit = 150
        XCTAssertEqual(notifications, 50, "Unchanged values must not retrigger history cleanup.")

        settings.screenshotHistoryLimit = Int.min
        XCTAssertEqual(settings.screenshotHistoryLimit, 1)
        settings.screenshotHistoryLimit = Int.max
        XCTAssertEqual(settings.screenshotHistoryLimit, 1000)
        XCTAssertEqual(defaults.integer(forKey: "SnapLex.screenshotHistoryLimit"), 1000)
        XCTAssertEqual(retentionUpdates, 52)
        XCTAssertEqual(notifications, 52)

        let reopened = AppSettings(defaults: defaults, screenshotRetentionChanged: {})
        XCTAssertEqual(reopened.screenshotHistoryLimit, 1000)
    }

    func testInvalidSavedLimitIsClampedOnLaunchWithoutRunningRetentionDuringInitialization() throws {
        let suite = "SnapLexSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-5, forKey: "SnapLex.screenshotHistoryLimit")
        var retentionUpdates = 0
        let settings = AppSettings(defaults: defaults, screenshotRetentionChanged: { retentionUpdates += 1 })
        XCTAssertEqual(settings.screenshotHistoryLimit, 1)
        XCTAssertEqual(retentionUpdates, 0)
    }
}
