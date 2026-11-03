import XCTest
@testable import SnapLex

final class SnapPreferencesTests: XCTestCase {
    func testSanitizingClampsCapturePinAndUpdateValues() {
        var preferences = SnapPreferences.standard
        preferences.borderWidth = 0
        preferences.pinOpacityPercent = 1
        preferences.pinMaxSide = 10
        preferences.thumbnailSize = 1
        preferences.updateDelaySeconds = -5
        preferences.updateIntervalHours = 0
        preferences.maskAlpha = 2
        preferences.anchorBorderRed = -1
        preferences.fileNamePattern = "   "

        let clean = preferences.sanitized()
        XCTAssertEqual(clean.borderWidth, 1)
        XCTAssertEqual(clean.pinOpacityPercent, 15)
        XCTAssertEqual(clean.pinMaxSide, 200)
        XCTAssertEqual(clean.thumbnailSize, 24)
        XCTAssertEqual(clean.updateDelaySeconds, 0)
        XCTAssertEqual(clean.updateIntervalHours, 1)
        XCTAssertEqual(clean.maskAlpha, 1)
        XCTAssertEqual(clean.anchorBorderRed, 0)
        XCTAssertEqual(clean.fileNamePattern, SnapPreferences.defaultPattern)
    }

    func testFileNameReplacesDateTokensAndRemovesPathSeparators() {
        let date = Date(timeIntervalSince1970: 1_762_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let expected = "SnapLex_\(formatter.string(from: date)).png"
        XCTAssertEqual(
            SnapPreferences.fileName(pattern: "SnapLex_$yyyy-MM-dd_HH-mm-ss$.png", at: date),
            expected
        )

        let unsafe = SnapPreferences.fileName(pattern: "a/b_$yyyy$.png", at: date)
        XCTAssertFalse(unsafe.contains("/"))
        XCTAssertFalse(unsafe.contains("$"))
        XCTAssertTrue(SnapPreferences.fileName(pattern: "plain", at: date).hasSuffix(".png"))
    }

    func testUniqueFileURLAppendsASuffixWhenTheNameExists() {
        let preferences = SnapPreferences.standard
        let directory = URL(fileURLWithPath: "/tmp/snaplex-names", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_762_000_000)
        var existing = Set<String>()
        let first = preferences.uniqueFileURL(in: directory, at: date) { existing.contains($0) }
        existing.insert(first.path)
        let second = preferences.uniqueFileURL(in: directory, at: date) { existing.contains($0) }
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.deletingPathExtension().lastPathComponent.hasSuffix("-2"))
        XCTAssertEqual(first.deletingLastPathComponent().path, directory.path)
    }

    func testEmptyDirectoriesUseDesktopAndPictures() {
        let preferences = SnapPreferences.standard
        XCTAssertFalse(preferences.quickSaveDirectoryURL().path.isEmpty)
        XCTAssertFalse(preferences.autoSaveDirectoryURL().path.isEmpty)
        XCTAssertNotEqual(preferences.quickSaveDirectoryURL().path, preferences.autoSaveDirectoryURL().path)
    }

    func testUnboundShortcutIsNotTreatedAsTextEditing() {
        let unbound = ShortcutBinding(keyCode: 0, modifiers: 0, keyLabel: "")
        XCTAssertTrue(unbound.isUnbound)
        XCTAssertFalse(unbound.isReservedForTextEditing)
        XCTAssertTrue(GlobalShortcut.toggleClickThrough.defaultBinding.isUnbound)
        XCTAssertFalse(GlobalShortcut.quickSave.defaultBinding.isReservedForTextEditing)
        XCTAssertFalse(GlobalShortcut.screenshotCopy.defaultBinding.isReservedForTextEditing)
    }

    @MainActor
    func testStoredPreferencesKeepMissingKeysAndUnboundShortcuts() throws {
        let suite = "SnapLexPreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: ["borderWidth": 9, "showCrossLines": true]),
            forKey: "SnapLex.capturePreferences"
        )
        let reservedCopy = ShortcutBinding(
            keyCode: 0,
            modifiers: NSEvent.ModifierFlags.command.rawValue,
            keyLabel: "A"
        )
        let storedBindings: [String: ShortcutBinding] = [
            GlobalShortcut.screenshotCopy.rawValue: reservedCopy,
            GlobalShortcut.toggleClickThrough.rawValue: ShortcutBinding(keyCode: 0, modifiers: 0, keyLabel: "")
        ]
        defaults.set(try JSONEncoder().encode(storedBindings), forKey: "SnapLex.shortcutBindings")

        let settings = AppSettings(defaults: defaults, screenshotRetentionChanged: {})
        XCTAssertEqual(settings.capturePreferences.borderWidth, 9)
        XCTAssertTrue(settings.capturePreferences.showCrossLines)
        XCTAssertEqual(settings.capturePreferences.maskAlpha, SnapPreferences.standard.maskAlpha)
        XCTAssertEqual(settings.capturePreferences.fileNamePattern, SnapPreferences.defaultPattern)
        XCTAssertTrue(settings.capturePreferences.periodicUpdatesEnabled)
        XCTAssertEqual(
            settings.shortcutBinding(for: .screenshotCopy),
            GlobalShortcut.screenshotCopy.defaultBinding
        )
        XCTAssertTrue(settings.shortcutBinding(for: .toggleClickThrough).isUnbound)

        var edited = settings.capturePreferences
        edited.borderWidth = 40
        edited.pinOpacityPercent = 4
        settings.capturePreferences = edited
        XCTAssertEqual(settings.capturePreferences.borderWidth, 12)
        XCTAssertEqual(settings.capturePreferences.pinOpacityPercent, 15)

        settings.setShortcutBinding(
            ShortcutBinding(keyCode: 0, modifiers: 0, keyLabel: ""),
            for: .quickSave
        )
        let reopened = AppSettings(defaults: defaults, screenshotRetentionChanged: {})
        XCTAssertEqual(reopened.capturePreferences.borderWidth, 12)
        XCTAssertEqual(reopened.capturePreferences.pinOpacityPercent, 15)
        XCTAssertTrue(reopened.shortcutBinding(for: .quickSave).isUnbound)
        XCTAssertTrue(reopened.capturePreferences.showCrossLines)
    }
}
