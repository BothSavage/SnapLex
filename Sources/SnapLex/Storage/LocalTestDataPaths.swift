import Foundation

/// Opt-in storage redirection for a separately launched local UI-test copy.
/// The override is accepted only inside the current user's temporary directory
/// so a typo cannot redirect the app into or out of production history.
enum LocalTestDataPaths {
    static let rootEnvironmentKey = "SNAPLEX_ISOLATED_TEST_DATA_ROOT"

    static var rootDirectory: URL? {
        directory(environment: ProcessInfo.processInfo.environment)
    }

    static func directory(environment: [String: String], temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL? {
        guard let path = environment[rootEnvironmentKey], !path.isEmpty else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let temporaryRoot = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let allowedPrefix = temporaryRoot.path.hasSuffix("/") ? temporaryRoot.path : temporaryRoot.path + "/"
        guard root.path.hasPrefix(allowedPrefix) else {
            // If isolation was requested but the path is invalid, fail closed
            // into a disposable location rather than falling back to history.
            return temporaryRoot.appendingPathComponent("SnapLex-Rejected-Test-Data", isDirectory: true)
        }
        return root
    }
}
