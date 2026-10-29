import XCTest
import AppKit
import Sparkle
@testable import SnapLex

final class NativeUpdateInstallerTests: XCTestCase {
    @MainActor
    func testReadyUpdateImmediatelyInstallsAndRelaunches() {
        _ = NSApplication.shared
        let installer = NativeUpdateInstaller()
        var choices: [SPUUserUpdateChoice] = []

        installer.showReady(toInstallAndRelaunch: { choices.append($0) })

        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(installer.state, .installing)
        XCTAssertFalse(installer.canCancel)
    }
}
