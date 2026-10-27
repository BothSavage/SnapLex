import Foundation
import XCTest
@testable import SnapLex

final class LocalTestDataPathsTests: XCTestCase {
    func testOverrideResolvesInsideTemporaryRoot() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLex-isolated-test-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL

        let resolved = try XCTUnwrap(LocalTestDataPaths.directory(
            environment: [LocalTestDataPaths.rootEnvironmentKey: temporaryRoot.path]
        ))

        XCTAssertEqual(resolved, temporaryRoot)
    }

    func testOverrideOutsideTemporaryRootFailsClosedIntoTemporaryStorage() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let productionLikePath = temporaryRoot
            .deletingLastPathComponent()
            .appendingPathComponent("SnapLex-production-like", isDirectory: true)
            .path

        let resolved = try XCTUnwrap(LocalTestDataPaths.directory(
            environment: [LocalTestDataPaths.rootEnvironmentKey: productionLikePath]
        ))
        XCTAssertNotEqual(resolved.path, productionLikePath)
        XCTAssertTrue(resolved.path.hasPrefix(temporaryRoot.path))
    }

    func testMissingOverrideKeepsProductionPathResolutionDisabled() {
        XCTAssertNil(LocalTestDataPaths.directory(environment: [:]))
    }
}
