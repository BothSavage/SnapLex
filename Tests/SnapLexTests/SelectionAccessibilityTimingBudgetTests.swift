import XCTest
@testable import SnapLex

final class SelectionAccessibilityTimingBudgetTests: XCTestCase {
    func testQueueWaitAndWorkerBudgetRemainIndependentAcross300BoundaryScenarios() {
        let queueBudgets: [UInt64] = [1_000_000, 10_000_000, 300_000_000, 600_000_000]
        let workerBudgets: [UInt64] = [1_000_000, 60_000_000, 280_000_000]
        let enqueuedAt: UInt64 = 4_000_000_000
        var scenarios = 0

        for queueBudget in queueBudgets {
            let queueWaits: [UInt64] = [
                0,
                queueBudget / 2,
                queueBudget - 1,
                queueBudget,
                queueBudget + 1
            ]
            for queueWait in queueWaits {
                for workerBudget in workerBudgets {
                    let timing = SelectionAccessibilityTimingBudget(
                        enqueuedAtNanoseconds: enqueuedAt,
                        maximumQueueWaitNanoseconds: queueBudget,
                        workerBudgetNanoseconds: workerBudget
                    )
                    let startedAt = enqueuedAt + queueWait
                    XCTAssertEqual(
                        timing.shouldStartWorker(at: startedAt),
                        queueWait <= queueBudget,
                        "scenario=\(scenarios + 1) queueBudget=\(queueBudget) queueWait=\(queueWait)"
                    )

                    let workerElapsedValues: [UInt64] = [
                        0,
                        workerBudget / 2,
                        workerBudget - 1,
                        workerBudget,
                        workerBudget + 1
                    ]
                    for workerElapsed in workerElapsedValues {
                        scenarios += 1
                        XCTAssertEqual(
                            timing.hasWorkerTime(startedAt: startedAt, now: startedAt + workerElapsed),
                            workerElapsed < workerBudget,
                            "scenario=\(scenarios) queueWait=\(queueWait) workerBudget=\(workerBudget) workerElapsed=\(workerElapsed)"
                        )
                        XCTAssertEqual(
                            timing.workerDeadline(startedAt: startedAt),
                            startedAt + workerBudget,
                            "worker deadline must start when the worker begins, scenario=\(scenarios)"
                        )
                    }
                }
            }
        }

        XCTAssertEqual(scenarios, 300)
    }

    func testClockMovingBeforeEnqueueFailsClosedAndDeadlineSaturatesOnOverflow() {
        let beforeEnqueue = SelectionAccessibilityTimingBudget(
            enqueuedAtNanoseconds: 100,
            maximumQueueWaitNanoseconds: 50,
            workerBudgetNanoseconds: 20
        )
        XCTAssertFalse(beforeEnqueue.shouldStartWorker(at: 99))

        let nearMaximum = SelectionAccessibilityTimingBudget(
            enqueuedAtNanoseconds: UInt64.max - 5,
            maximumQueueWaitNanoseconds: 5,
            workerBudgetNanoseconds: 10
        )
        XCTAssertEqual(nearMaximum.workerDeadline(startedAt: UInt64.max - 2), .max)
    }
}
