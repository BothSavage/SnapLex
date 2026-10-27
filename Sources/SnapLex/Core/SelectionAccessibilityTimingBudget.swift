import Foundation

/// Keeps stale work bounded without charging serial-queue delay against the
/// time available for Accessibility IPC itself.
struct SelectionAccessibilityTimingBudget: Equatable, Sendable {
    let enqueuedAtNanoseconds: UInt64
    let maximumQueueWaitNanoseconds: UInt64
    let workerBudgetNanoseconds: UInt64

    func shouldStartWorker(at startedAtNanoseconds: UInt64) -> Bool {
        guard startedAtNanoseconds >= enqueuedAtNanoseconds else { return false }
        return startedAtNanoseconds - enqueuedAtNanoseconds <= maximumQueueWaitNanoseconds
    }

    func workerDeadline(startedAt startedAtNanoseconds: UInt64) -> UInt64 {
        let (deadline, overflow) = startedAtNanoseconds.addingReportingOverflow(workerBudgetNanoseconds)
        return overflow ? .max : deadline
    }

    func hasWorkerTime(startedAt startedAtNanoseconds: UInt64, now: UInt64) -> Bool {
        now >= startedAtNanoseconds && now < workerDeadline(startedAt: startedAtNanoseconds)
    }
}
