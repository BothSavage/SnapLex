import Foundation

/// Persists an in-progress settings visit across the quit-and-reopen action
/// that macOS can require after a privacy permission changes.
@MainActor
final class PermissionGuideSession {
    static let shared = PermissionGuideSession()
    private static let key = "SnapLex.permissionGuidePending"
    private let defaults: UserDefaults
    private let now: () -> Date
    private let maximumAge: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    var isPending: Bool {
        guard let date = defaults.object(forKey: Self.key) as? Date else { return false }
        let age = now().timeIntervalSince(date)
        return age >= -60 && age <= maximumAge
    }

    func begin() {
        defaults.set(now(), forKey: Self.key)
        // The system may terminate this process immediately after the user
        // changes a permission; make the resume marker visible to the next process.
        defaults.synchronize()
    }

    func finish() {
        defaults.removeObject(forKey: Self.key)
        defaults.synchronize()
    }
}

enum AppReopenTarget: Equatable {
    case permissionGuide, waitForPermissionScan, dashboard

    static func resolve(guideVisible: Bool, permissionSessionPending: Bool, startupScanComplete: Bool) -> Self {
        if guideVisible || permissionSessionPending { return .permissionGuide }
        return startupScanComplete ? .dashboard : .waitForPermissionScan
    }
}
