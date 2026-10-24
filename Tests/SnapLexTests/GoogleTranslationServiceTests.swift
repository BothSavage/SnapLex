import XCTest
@testable import SnapLex

final class GoogleTranslationServiceTests: XCTestCase {
    override func tearDown() {
        GoogleTranslationURLProtocol.handler = nil
        GoogleTranslationURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testParseResponseKeepsDictionaryPartsOnSeparateLines() throws {
        let response: [Any] = [
            [["traduire", "translate", NSNull(), NSNull(), 0]],
            [["verb", ["translate", "render"], NSNull(), NSNull(), 0], ["noun", ["translation"], NSNull(), NSNull(), 0]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        let output = try GoogleTranslationService.parseResponse(data: data, originalText: "translate")

        XCTAssertEqual(output, "traduire\n\n• [verb] translate；render\n• [noun] translation")
    }

    func testTargetLanguageLabelsMapToGoogleLanguageCodes() {
        XCTAssertEqual(GoogleTranslationService.googleLanguageCode(for: "English"), "en")
        XCTAssertEqual(GoogleTranslationService.googleLanguageCode(for: "简体中文"), "zh-CN")
        XCTAssertEqual(GoogleTranslationService.googleLanguageCode(for: "日本語"), "ja")
    }

    func testInPlaceTranslationsCanExcludeDictionarySuggestions() throws {
        let response: [Any] = [
            [["traduire", "translate", NSNull(), NSNull(), 0]],
            [["verb", ["translate", "render"], NSNull(), NSNull(), 0]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        let output = try GoogleTranslationService.parseResponse(
            data: data,
            originalText: "translate",
            includeDictionary: false
        )

        XCTAssertEqual(output, "traduire")
    }

    func testURLSessionRequestUsesSelectedTargetAndReturnsParsedTranslation() async throws {
        let response: [Any] = [
            [["你好，SnapLex", "Hello, SnapLex", NSNull(), NSNull(), 0]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        GoogleTranslationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleTranslationURLProtocol.self]
        let service = GoogleTranslationService(session: URLSession(configuration: configuration))

        let result = try await service.translateDetailed(text: "Hello, SnapLex", targetLanguage: "简体中文")

        XCTAssertEqual(result.translation, "你好，SnapLex")
        let request = try XCTUnwrap(GoogleTranslationURLProtocol.lastRequest)
        let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(queryItems.first(where: { $0.name == "tl" })?.value, "zh-CN")
        XCTAssertEqual(queryItems.first(where: { $0.name == "q" })?.value, "Hello, SnapLex")
    }

    func testURLSessionRequestReportsRejectedHTTPStatus() async {
        GoogleTranslationURLProtocol.handler = { request in
            let url = request.url!
            return (
                HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleTranslationURLProtocol.self]
        let service = GoogleTranslationService(session: URLSession(configuration: configuration))

        do {
            _ = try await service.translateDetailed(text: "Hello", targetLanguage: "简体中文")
            XCTFail("Expected the Google service to reject the HTTP response")
        } catch let error as GoogleTranslationError {
            guard case .serverRejected(503) = error else {
                return XCTFail("Unexpected Google translation error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testViewModelDeliversNonEmptyInputThroughGoogleTranslation() async throws {
        let response: [Any] = [
            [["来自 SnapLex 的问候", "Hello from SnapLex", NSNull(), NSNull(), 0]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        GoogleTranslationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleTranslationURLProtocol.self]
        let service = GoogleTranslationService(session: URLSession(configuration: configuration))
        let oldEngine = AppSettings.shared.translationEngine
        AppSettings.shared.translationEngine = .google
        defer { AppSettings.shared.translationEngine = oldEngine }

        let viewModel = TranslatorViewModel(googleTranslationService: service)
        viewModel.startTranslation(text: "Hello from SnapLex", overrideTargetLang: "简体中文")
        for _ in 0..<50 where viewModel.isTranslating {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(viewModel.isTranslating)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.translatedOutput, "来自 SnapLex 的问候")
    }
}

private final class GoogleTranslationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        do {
            guard let handler = Self.handler else {
                throw URLError(.unsupportedURL)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
