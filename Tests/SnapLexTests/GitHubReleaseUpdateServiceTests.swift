import XCTest
@testable import SnapLex

@MainActor
final class GitHubReleaseUpdateServiceTests: XCTestCase {
    override func tearDown() {
        GitHubReleaseURLProtocol.handler = nil
        GitHubReleaseURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testReleaseTagsNormalizeOptionalVPrefixAndBuildMetadata() throws {
        let version = try XCTUnwrap(GitHubReleaseVersion(tag: "v1.2.3+build.42"))

        XCTAssertEqual(version.normalized, "1.2.3")
        XCTAssertEqual(GitHubReleaseVersion(tag: "V2.0.0")?.normalized, "2.0.0")
    }

    func testStableReleaseIsNewerThanOlderCoreVersions() throws {
        let candidate = try XCTUnwrap(GitHubReleaseVersion(tag: "v2.0.0"))

        for installed in ["1.9.9", "1.10.0", "0.99.99"] {
            XCTAssertGreaterThan(candidate, try XCTUnwrap(GitHubReleaseVersion(tag: installed)), installed)
        }
    }

    func testStableReleaseIsNewerThanPrereleaseOfSameVersion() throws {
        let stable = try XCTUnwrap(GitHubReleaseVersion(tag: "1.4.0"))
        let releaseCandidate = try XCTUnwrap(GitHubReleaseVersion(tag: "1.4.0-rc.1"))

        XCTAssertGreaterThan(stable, releaseCandidate)
        XCTAssertLessThan(releaseCandidate, stable)
    }

    func testPrereleaseIdentifiersFollowSemanticVersionOrdering() throws {
        let cases: [(String, String)] = [
            ("1.0.0-alpha", "1.0.0-beta"),
            ("1.0.0-beta.2", "1.0.0-beta.11"),
            ("1.0.0-rc.1", "1.0.0-rc.1.1"),
            ("1.0.0-1", "1.0.0-alpha"),
        ]

        for (lower, higher) in cases {
            XCTAssertLessThan(
                try XCTUnwrap(GitHubReleaseVersion(tag: lower)),
                try XCTUnwrap(GitHubReleaseVersion(tag: higher)),
                "Expected \(lower) to precede \(higher)"
            )
        }
    }

    func testBuildMetadataDoesNotChangeVersionPrecedence() throws {
        let plain = try XCTUnwrap(GitHubReleaseVersion(tag: "1.2.3"))
        let withMetadata = try XCTUnwrap(GitHubReleaseVersion(tag: "1.2.3+ci.7"))

        XCTAssertEqual(plain, withMetadata)
        XCTAssertFalse(withMetadata > plain)
    }

    func testMalformedReleaseTagsAreRejected() {
        for tag in ["", "v1.2", "1.2.3.4", "1.02.3", "1.2.03", "1.2.3-", "1.2.3-01", "1.2.3+", "1.2.3+bad+metadata"] {
            XCTAssertNil(GitHubReleaseVersion(tag: tag), "Expected malformed version \(tag) to be rejected")
        }
    }

    func testUpdateCheckShowsNewerStableReleaseAndItsNotes() async throws {
        GitHubReleaseURLProtocol.handler = { request in
            let payload: [String: Any] = [
                "tag_name": "v0.2.0",
                "html_url": "https://github.com/BothSavage/SnapLex/releases/tag/v0.2.0",
                "body": "Faster capture\n\nBug fixes"
            ]
            return try Self.response(for: request, status: 200, payload: payload)
        }
        let service = Self.makeService(currentVersion: "0.1.0")

        await service.checkForUpdates()

        guard case let .updateAvailable(version, notes, releaseURL, downloadURL, hasUpdateFeed) = service.state else {
            return XCTFail("Expected an update to be available, received \(service.state)")
        }
        XCTAssertEqual(version, "0.2.0")
        XCTAssertEqual(notes, "Faster capture\n\nBug fixes")
        XCTAssertEqual(releaseURL.absoluteString, "https://github.com/BothSavage/SnapLex/releases/tag/v0.2.0")
        XCTAssertNil(downloadURL)
        XCTAssertFalse(hasUpdateFeed)
        XCTAssertEqual(GitHubReleaseURLProtocol.lastRequest?.url?.path, "/repos/BothSavage/SnapLex/releases/latest")
        XCTAssertEqual(GitHubReleaseURLProtocol.lastRequest?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testUpdateSelectsCompatibleInstallerAndPrefersSignedPackage() async throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let base = "SnapLex-1.0.1-macOS-\(architecture)"
        let prefix = "https://github.com/BothSavage/SnapLex/releases/download/v1.0.1/"
        GitHubReleaseURLProtocol.handler = { request in
            try Self.response(for: request, status: 200, payload: [
                "tag_name": "v1.0.1",
                "html_url": "https://github.com/BothSavage/SnapLex/releases/tag/v1.0.1",
                "assets": [
                    ["name": "\(base)-unnotarized.dmg", "browser_download_url": prefix + "\(base)-unnotarized.dmg"],
                    ["name": "\(base).dmg", "browser_download_url": prefix + "\(base).dmg"]
                ]
            ])
        }
        let service = Self.makeService(currentVersion: "0.1.0")
        await service.checkForUpdates()
        guard case let .updateAvailable(_, _, _, downloadURL, _) = service.state else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(downloadURL?.absoluteString, prefix + "\(base).dmg")
    }

    func testUpdateSelectsUnnotarizedInstallerWhenItIsTheOnlyCompatiblePackage() async throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let name = "SnapLex-1.0.1-macOS-\(architecture)-unnotarized.dmg"
        let download = "https://github.com/BothSavage/SnapLex/releases/download/v1.0.1/\(name)"
        GitHubReleaseURLProtocol.handler = { request in
            try Self.response(for: request, status: 200, payload: [
                "tag_name": "v1.0.1",
                "html_url": "https://github.com/BothSavage/SnapLex/releases/tag/v1.0.1",
                "assets": [["name": name, "browser_download_url": download]]
            ])
        }
        let service = Self.makeService(currentVersion: "0.1.0")
        await service.checkForUpdates()
        guard case let .updateAvailable(_, _, _, downloadURL, _) = service.state else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(downloadURL?.absoluteString, download)
    }

    func testUpdateDoesNotOfferMismatchedOrUntrustedInstaller() async throws {
        #if arch(arm64)
        let architecture = "arm64"
        let otherArchitecture = "x86_64"
        #else
        let architecture = "x86_64"
        let otherArchitecture = "arm64"
        #endif
        let name = "SnapLex-1.0.1-macOS-\(architecture).dmg"
        let otherName = "SnapLex-1.0.1-macOS-\(otherArchitecture).dmg"
        GitHubReleaseURLProtocol.handler = { request in
            try Self.response(for: request, status: 200, payload: [
                "tag_name": "v1.0.1",
                "html_url": "https://github.com/BothSavage/SnapLex/releases/tag/v1.0.1",
                "assets": [
                    ["name": name, "browser_download_url": "https://example.com/\(name)"],
                    ["name": otherName, "browser_download_url": "https://github.com/BothSavage/SnapLex/releases/download/v1.0.1/\(otherName)"]
                ]
            ])
        }
        let service = Self.makeService(currentVersion: "0.1.0")
        await service.checkForUpdates()
        guard case let .updateAvailable(_, _, _, downloadURL, _) = service.state else {
            return XCTFail("Expected an available update")
        }
        XCTAssertNil(downloadURL)
    }

    func testUpdateOnlyEnablesInstallerForTheReleaseFeedOnGitHub() async {
        for (url, expected) in [
            ("https://github.com/BothSavage/SnapLex/releases/download/v1.0.1/appcast.xml", true),
            ("https://example.com/appcast.xml", false),
            ("https://github.com/BothSavage/SnapLex/releases/download/v1.0.0/appcast.xml", false)
        ] {
            GitHubReleaseURLProtocol.handler = { request in
                try Self.response(for: request, status: 200, payload: [
                    "tag_name": "v1.0.1",
                    "html_url": "https://github.com/BothSavage/SnapLex/releases/tag/v1.0.1",
                    "assets": [["name": "appcast.xml", "browser_download_url": url]]
                ])
            }
            let service = Self.makeService(currentVersion: "0.1.0")
            await service.checkForUpdates()
            guard case let .updateAvailable(_, _, _, _, hasUpdateFeed) = service.state else {
                XCTFail("Expected an available update")
                continue
            }
            XCTAssertEqual(hasUpdateFeed, expected, url)
        }
    }

    func testUpdateCheckReportsNoReleaseWhenGitHubHasNoPublishedRelease() async throws {
        GitHubReleaseURLProtocol.handler = { request in
            try Self.response(for: request, status: 404, payload: ["message": "Not Found"])
        }
        let service = Self.makeService(currentVersion: "0.1.0")

        await service.checkForUpdates()

        XCTAssertEqual(service.state, .noRelease)
    }

    func testUpdateCheckReportsLatestWhenInstalledVersionMatchesRelease() async throws {
        GitHubReleaseURLProtocol.handler = { request in
            let payload: [String: Any] = [
                "tag_name": "v0.1.0",
                "html_url": "https://github.com/BothSavage/SnapLex/releases/tag/v0.1.0",
                "body": ""
            ]
            return try Self.response(for: request, status: 200, payload: payload)
        }
        let service = Self.makeService(currentVersion: "0.1.0")

        await service.checkForUpdates()

        XCTAssertEqual(service.state, .upToDate)
    }

    func testUpdateCheckRejectsNonGitHubReleaseLinks() async throws {
        GitHubReleaseURLProtocol.handler = { request in
            let payload: [String: Any] = [
                "tag_name": "v0.2.0",
                "html_url": "https://example.com/release",
                "body": ""
            ]
            return try Self.response(for: request, status: 200, payload: payload)
        }
        let service = Self.makeService(currentVersion: "0.1.0")

        await service.checkForUpdates()

        XCTAssertEqual(service.state, .failed(L10n.string("GitHub 返回了无效响应")))
    }

    private static func makeService(currentVersion: String) -> GitHubReleaseUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubReleaseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return GitHubReleaseUpdateService(session: session, currentVersion: currentVersion)
    }

    private static func response(
        for request: URLRequest,
        status: Int,
        payload: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        return (
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)),
            try JSONSerialization.data(withJSONObject: payload)
        )
    }
}

private final class GitHubReleaseURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
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
