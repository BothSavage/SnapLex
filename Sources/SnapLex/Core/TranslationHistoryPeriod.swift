import Foundation

enum TranslationHistoryPeriod: String, CaseIterable, Identifiable {
    case today
    case last7Days
    case lastMonth
    case last30Days

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .today: return "今日"
        case .last7Days: return "近 7 天"
        case .lastMonth: return "近一月"
        case .last30Days: return "近 30 天"
        }
    }

    func startDate(now: Date, calendar: Calendar) -> Date {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
    }

    func includes(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        date >= startDate(now: now, calendar: calendar) && date <= now
    }

    func numberOfDays(now: Date, calendar: Calendar) -> Int {
        let firstDay = calendar.startOfDay(for: startDate(now: now, calendar: calendar))
        let today = calendar.startOfDay(for: now)
        return max(1, (calendar.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1)
    }

    func days(now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let dayCount = numberOfDays(now: now, calendar: calendar)
        return (0..<dayCount).compactMap { offset in
            calendar.date(byAdding: .day, value: -(dayCount - offset - 1), to: today)
        }
    }
}
