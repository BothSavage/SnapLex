import Foundation
import Combine

/// A SemVer 2.0 version used for comparing the app bundle version with GitHub release tags.
/// Release workflow tags are restricted to MAJOR.MINOR.PATCH, but parsing prereleases here
/// keeps local development builds and future release channels well-defined.
struct GitHubReleaseVersion: Equatable, Comparable {
    private struct Identifier: Equatable {
        let value: String
        var isNumeric: Bool { value.allSatisfy(\.isNumber) }
    }

    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    private let prerelease: [Identifier]?

    var normalized: String {
        let core = "\(major).\(minor).\(patch)"
        guard let prerelease else { return core }
        return core + "-" + prerelease.map(\.value).joined(separator: ".")
    }

    init?(tag: String) {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        if buildParts.count == 2 {
            guard !buildParts[1].isEmpty,
                  Self.isValidIdentifierList(String(buildParts[1]), separator: ".") else { return nil }
        }

        let semanticVersion = String(buildParts[0])
        let versionParts = semanticVersion.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count == 3,
              let major = Self.numericCoreComponent(coreParts[0]),
              let minor = Self.numericCoreComponent(coreParts[1]),
              let patch = Self.numericCoreComponent(coreParts[2]) else { return nil }

        var parsedPrerelease: [Identifier]?
        if versionParts.count == 2 {
            guard !versionParts[1].isEmpty else { return nil }
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { return nil }
            var values: [Identifier] = []
            for identifier in identifiers {
                let text = String(identifier)
                guard Self.isValidIdentifier(text),
                      !(text.count > 1 && text.first == "0" && text.allSatisfy(\.isNumber)) else { return nil }
                values.append(Identifier(value: text))
            }
            parsedPrerelease = values
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = parsedPrerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false // A stable version has higher precedence than its prerelease.
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            for index in 0..<min(left.count, right.count) {
                let leftIdentifier = left[index]
                let rightIdentifier = right[index]
                if leftIdentifier == rightIdentifier { continue }
                switch (leftIdentifier.isNumeric, rightIdentifier.isNumeric) {
                case (true, true):
                    if leftIdentifier.value.count != rightIdentifier.value.count {
                        return leftIdentifier.value.count < rightIdentifier.value.count
                    }
                    return leftIdentifier.value < rightIdentifier.value
                case (true, false):
                    return true
                case (false, true):
                    return false
                case (false, false):
                    return leftIdentifier.value < rightIdentifier.value
                }
            }
            return left.count < right.count
        }
    }

    private static func numericCoreComponent(_ value: Substring) -> UInt64? {
        guard !value.isEmpty,
              !(value.count > 1 && value.first == "0"),
              value.allSatisfy(\.isNumber) else { return nil }
        return UInt64(value)
    }

    private static func isValidIdentifierList(_ value: String, separator: Character) -> Bool {
        let identifiers = value.split(separator: separator, omittingEmptySubsequences: false)
        return !identifiers.isEmpty && identifiers.allSatisfy { isValidIdentifier(String($0)) }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) ||
            (97...122).contains($0.value) || $0.value == 45
        }
    }
}

@MainActor
public final class GitHubReleaseUpdateService: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case noRelease
        case updateAvailable(version: String, notes: String, releaseURL: URL, downloadURL: URL?, hasUpdateFeed: Bool)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let body: String?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    private let owner = "BothSavage"
    private let repository = "SnapLex"
    private let session: URLSession
    private let currentVersionOverride: String?

    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func downloadURL(for release: Release, version: GitHubReleaseVersion) -> URL? {
        let base = "SnapLex-\(version.normalized)-macOS-\(architecture)"
        // Prefer a notarized package when both it and an unnotarized package exist.
        for name in ["\(base).dmg", "\(base)-unnotarized.dmg"] {
            guard let asset = release.assets?.first(where: { $0.name == name }) else { continue }
            let url = asset.browserDownloadURL
            guard url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.path == "/\(owner)/\(repository)/releases/download/\(release.tagName)/\(name)" else {
                continue
            }
            return url
        }
        return nil
    }

    private func hasUpdateFeed(_ release: Release) -> Bool {
        guard let asset = release.assets?.first(where: { $0.name == "appcast.xml" }) else { return false }
        let url = asset.browserDownloadURL
        return url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil
            && url.path == "/\(owner)/\(repository)/releases/download/\(release.tagName)/appcast.xml"
    }

    init(session: URLSession = .shared, currentVersion: String? = nil) {
        self.session = session
        self.currentVersionOverride = currentVersion
    }

    public var currentVersion: String {
        currentVersionOverride
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "1.0.4"
    }

    public func checkForUpdates() async {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest") else {
            state = .failed(L10n.string("更新服务地址无效"))
            return
        }

        state = .checking
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SnapLex macOS app", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                state = .failed(L10n.string("GitHub 返回了无效响应"))
                return
            }
            if http.statusCode == 404 {
                state = .noRelease
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                state = .failed(L10n.format("GitHub 请求失败（HTTP %d）", http.statusCode))
                return
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            guard release.htmlURL.scheme == "https",
                  release.htmlURL.host == "github.com",
                  let version = GitHubReleaseVersion(tag: release.tagName) else {
                state = .failed(L10n.string("GitHub 返回了无效响应"))
                return
            }
            if let installedVersion = GitHubReleaseVersion(tag: currentVersion), version > installedVersion {
                state = .updateAvailable(
                    version: version.normalized,
                    notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    releaseURL: release.htmlURL,
                    downloadURL: downloadURL(for: release, version: version),
                    hasUpdateFeed: hasUpdateFeed(release)
                )
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(L10n.format("检查更新失败：%@", error.localizedDescription))
        }
    }
}
