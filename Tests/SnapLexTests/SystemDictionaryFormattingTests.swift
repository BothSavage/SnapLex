import XCTest
@testable import SnapLex

final class SystemDictionaryFormattingTests: XCTestCase {
    func testCircledDictionarySensesBecomeSeparateRows() {
        let raw = "翻译 |fānyì| ①动 第一条释义。 ②动 第二条释义。 ③名 第三条释义。"

        let formatted = SystemDictionaryService.formatRawDefinition(raw)

        XCTAssertEqual(
            formatted,
            "翻译 |fānyì|\n①动 第一条释义。\n②动 第二条释义。\n③名 第三条释义。"
        )
    }

    func testArabicDictionaryNumberingBecomesSeparateRows() {
        let raw = "term 1. first meaning 2. second meaning"

        let formatted = SystemDictionaryService.formatRawDefinition(raw)

        XCTAssertEqual(formatted, "term\n1. first meaning\n2. second meaning")
    }
}
