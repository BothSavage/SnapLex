import XCTest
import Foundation
@testable import SnapLex

final class LocalizationCatalogTests: XCTestCase {
    func testCatalogDefaultsToSimplifiedChineseAndTranslatesCommonActions() {
        XCTAssertTrue(L10n.hasLoadedCatalog)
        XCTAssertEqual(L10n.defaultLanguage, "zh-Hans")
        XCTAssertEqual(L10n.localizedString("翻译", language: "en"), "Translate")
        XCTAssertEqual(L10n.localizedString("翻译", language: "zh-Hans"), "翻译")
    }

    func testMissingTranslationsFallBackToTheChineseSourceText() {
        XCTAssertEqual(L10n.localizedString("未配置的中文提示", language: "en"), "未配置的中文提示")
    }

    func testFindsCatalogInPackagedAppResourcesAndHandlesMissingBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLexLocalization-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resources = root.appendingPathComponent("SnapLex.app/Contents/Resources", isDirectory: true)
        let bundle = resources.appendingPathComponent("SnapLex_SnapLex.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "io.github.snaplex.localization-fixture", "CFBundlePackageType": "BNDL"],
            format: .xml, options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Info.plist"))
        let catalog = bundle.appendingPathComponent("i18n.json")
        try Data("{}".utf8).write(to: catalog)

        XCTAssertEqual(L10n.catalogURL(in: [resources])?.resolvingSymlinksInPath(), catalog.resolvingSymlinksInPath())
        XCTAssertNil(L10n.catalogURL(in: [root.appendingPathComponent("missing", isDirectory: true)]))
    }
}
