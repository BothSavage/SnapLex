import Combine
import Foundation

@MainActor
final class TranslationHistoryQueryModel: ObservableObject {
    @Published private(set) var summary = TranslationHistorySummary()
    @Published private(set) var entries: [TranslationHistoryEntry] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var failed = false

    private struct CacheKey: Hashable {
        let period: TranslationHistoryPeriod
        let search: String
        let revision: UInt64
        let start: Date
        let timeZone: String
    }
    private var cache: [CacheKey: (range: TranslationHistoryRange, summary: TranslationHistorySummary, page: TranslationHistoryPage)] = [:]
    private var currentRange: TranslationHistoryRange?
    private var generation = 0

    func load(store: TranslationHistoryStore, period: TranslationHistoryPeriod, search: String, now: Date = Date(), calendar: Calendar = .current) async {
        generation += 1
        let request = generation
        let cleanSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = TranslationHistoryRange(start: period.startDate(now: now, calendar: calendar), end: now, search: cleanSearch)
        // Calendar-day ranges can reuse a recent result. The rolling-month
        // boundary changes continuously, so it is always queried afresh.
        let cacheStart = period == .lastMonth ? calendar.startOfDay(for: range.start) : range.start
        let key = CacheKey(period: period, search: cleanSearch, revision: store.revision, start: cacheStart, timeZone: calendar.timeZone.identifier)
        currentRange = range
        entries = []
        summary = TranslationHistorySummary()
        hasMore = false
        failed = false
        isLoading = true
        isLoadingPage = false
        if period != .lastMonth, let cached = cache[key], now.timeIntervalSince(cached.range.end) >= 0, now.timeIntervalSince(cached.range.end) < 30 {
            summary = cached.summary
            entries = cached.page.entries
            hasMore = cached.page.hasMore
            // Use the same boundary as the cached page for subsequent pages.
            currentRange = cached.range
            isLoading = false
            return
        }
        let url = store.databaseURL
        let ignored = store.ignoredWords
        do {
            async let pageResult = TranslationHistoryQuery.page(databaseURL: url, range: range)
            async let summaryResult = TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: ignored, calendar: calendar)
            let page = try await pageResult
            guard !Task.isCancelled, generation == request else { return }
            entries = page.entries
            hasMore = page.hasMore
            let calculated = try await summaryResult
            guard !Task.isCancelled, generation == request else { return }
            summary = calculated
            isLoading = false
            if period != .lastMonth {
                if cache.count >= 8 { cache.removeAll() }
                cache[key] = (range, calculated, page)
            }
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            isLoading = false
            failed = true
        }
    }

    func loadMore(store: TranslationHistoryStore) async {
        guard !isLoadingPage, hasMore, let range = currentRange, let last = entries.last else { return }
        let request = generation
        isLoadingPage = true
        defer { if generation == request { isLoadingPage = false } }
        do {
            let page = try await TranslationHistoryQuery.page(databaseURL: store.databaseURL, range: range, after: last)
            guard !Task.isCancelled, generation == request else { return }
            entries.append(contentsOf: page.entries)
            hasMore = page.hasMore
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            failed = true
        }
    }
}

@MainActor
final class TranslationHistoryOverviewModel: ObservableObject {
    @Published private(set) var today = TranslationHistorySummary()
    @Published private(set) var week = TranslationHistorySummary()
    @Published private(set) var lastDay = TranslationHistorySummary()
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false

    func load(store: TranslationHistoryStore, now: Date = Date(), calendar: Calendar = .current) async {
        isLoading = true
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let url = store.databaseURL
        let ignored = store.ignoredWords
        do {
            async let today = TranslationHistoryQuery.summary(databaseURL: url, range: .init(start: todayStart, end: now, search: ""), ignoredWords: ignored, calendar: calendar)
            async let week = TranslationHistoryQuery.summary(databaseURL: url, range: .init(start: weekStart, end: now, search: ""), ignoredWords: ignored, calendar: calendar, includeTerms: false)
            async let lastDay = TranslationHistoryQuery.summary(databaseURL: url, range: .init(start: now.addingTimeInterval(-86_400), end: now, search: ""), ignoredWords: ignored, calendar: calendar)
            let results = try await (today, week, lastDay)
            guard !Task.isCancelled else { return }
            self.today = results.0
            self.week = results.1
            self.lastDay = results.2
            isLoading = false
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            isLoading = false
            failed = true
        }
    }
}
