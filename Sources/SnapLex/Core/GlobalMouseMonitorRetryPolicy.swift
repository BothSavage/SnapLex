import Foundation

enum GlobalMouseMonitorRetryPolicy {
    static let retryInterval: TimeInterval = 5

    static func shouldAttempt(
        now: TimeInterval,
        lastAttempt: TimeInterval?,
        downRegistered: Bool,
        upRegistered: Bool,
        force: Bool = false
    ) -> Bool {
        guard !downRegistered || !upRegistered else { return false }
        guard !force else { return true }
        guard let lastAttempt else { return true }
        return now >= lastAttempt && now - lastAttempt >= retryInterval
    }
}

@MainActor
struct GlobalMouseMonitorRegistrationCoordinator {
    private(set) var downRegistered = false
    private(set) var upRegistered = false
    private(set) var lastAttempt: TimeInterval?

    mutating func reset() {
        downRegistered = false
        upRegistered = false
        lastAttempt = nil
    }

    @discardableResult
    mutating func ensureRegistered(
        now: TimeInterval,
        force: Bool = false,
        registerDown: @MainActor () -> Bool,
        registerUp: @MainActor () -> Bool
    ) -> Bool {
        guard GlobalMouseMonitorRetryPolicy.shouldAttempt(
            now: now,
            lastAttempt: lastAttempt,
            downRegistered: downRegistered,
            upRegistered: upRegistered,
            force: force
        ) else { return false }

        lastAttempt = now
        if !downRegistered { downRegistered = registerDown() }
        if !upRegistered { upRegistered = registerUp() }
        return true
    }
}
