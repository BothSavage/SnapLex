import Foundation
import XCTest
@testable import SnapLex

final class TranslationHistoryPeriodTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testTodayIncludesStartAndNowButExcludesPreviousDayAndFuture() throws {
        let calendar = calendar
        let now = try date(2026, 10, 25, hour: 12, calendar: calendar)
        let start = calendar.startOfDay(for: now)
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: start))
        let future = try XCTUnwrap(now.addingTimeInterval(1))

        XCTAssertTrue(TranslationHistoryPeriod.today.includes(start, now: now, calendar: calendar))
        XCTAssertTrue(TranslationHistoryPeriod.today.includes(now, now: now, calendar: calendar))
        XCTAssertFalse(TranslationHistoryPeriod.today.includes(previousDay, now: now, calendar: calendar))
        XCTAssertFalse(TranslationHistoryPeriod.today.includes(future, now: now, calendar: calendar))
        XCTAssertEqual(TranslationHistoryPeriod.today.numberOfDays(now: now, calendar: calendar), 1)
    }

    func testSevenAndThirtyDayPeriodsIncludeTheirExactStartBoundary() throws {
        let calendar = calendar
        let now = try date(2026, 10, 25, hour: 12, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        for (period, length) in [(TranslationHistoryPeriod.last7Days, 7), (.last30Days, 30)] {
            let firstIncludedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -(length - 1), to: today))
            let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: firstIncludedDay))
            XCTAssertTrue(period.includes(firstIncludedDay, now: now, calendar: calendar))
            XCTAssertFalse(period.includes(dayBefore, now: now, calendar: calendar))
            XCTAssertEqual(period.numberOfDays(now: now, calendar: calendar), length)
            XCTAssertEqual(period.days(now: now, calendar: calendar).count, length)
        }
    }

    func testMonthPeriodUsesCalendarMonthAndReflectsFebruaryLength() throws {
        let calendar = calendar
        let nonLeapFebruaryNow = try date(2025, 3, 28, hour: 12, calendar: calendar)
        let leapFebruaryNow = try date(2024, 3, 28, hour: 12, calendar: calendar)

        XCTAssertEqual(TranslationHistoryPeriod.lastMonth.numberOfDays(now: nonLeapFebruaryNow, calendar: calendar), 29)
        XCTAssertEqual(TranslationHistoryPeriod.lastMonth.numberOfDays(now: leapFebruaryNow, calendar: calendar), 30)
    }

    func testMonthPeriodDailyBucketsAreAscendingAndCoverBothBoundaryDates() throws {
        let calendar = calendar
        let now = try date(2025, 3, 28, hour: 12, calendar: calendar)
        let days = TranslationHistoryPeriod.lastMonth.days(now: now, calendar: calendar)
        let start = calendar.startOfDay(for: TranslationHistoryPeriod.lastMonth.startDate(now: now, calendar: calendar))

        XCTAssertEqual(days.first, start)
        XCTAssertEqual(days.last, calendar.startOfDay(for: now))
        XCTAssertEqual(days.count, 29)
        XCTAssertEqual(days, days.sorted())
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }
}
