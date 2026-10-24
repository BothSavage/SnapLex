import Foundation
import Combine

@MainActor
public final class GitHubReleaseUpdateService: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case noRelease
        case updateAvailable(version: String, notes: String, releaseURL: URL)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }

    private let owner = "BothSavage"
    private let repository = "SnapLex"

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
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
            let (data, response) = try await URLSession.shared.data(for: request)
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
            let version = Self.displayVersion(release.tagName)
            if Self.isNewer(version, than: currentVersion) {
                state = .updateAvailable(
                    version: version,
                    notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    releaseURL: release.htmlURL
                )
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(L10n.format("检查更新失败：%@", error.localizedDescription))
        }
    }

    private static func displayVersion(_ tag: String) -> String {
        tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = numericVersionParts(candidate)
        let currentParts = numericVersionParts(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func numericVersionParts(_ version: String) -> [Int] {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = core.split(separator: ".")
        guard !parts.isEmpty else { return [] }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return [] }
            values.append(value)
        }
        return values
    }
}
