import XCTest
@testable import SnapLex

@MainActor
final class TranslatorViewModelTests: XCTestCase {
    func testChangingTargetOnAnEmptyCardDoesNotStartATranslationRequest() {
        let viewModel = TranslatorViewModel()

        viewModel.changeTargetLanguage(to: "简体中文")

        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.translatedOutput.isEmpty)
        XCTAssertNil(viewModel.translationConfiguration)
    }

    func testSelectingTheSameSourceAndTargetReturnsTheOriginalText() {
        let viewModel = TranslatorViewModel()

        viewModel.startTranslation(text: "Hello from SnapLex", overrideTargetLang: "English")

        XCTAssertEqual(viewModel.translatedOutput, "Hello from SnapLex")
        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
    }
}
