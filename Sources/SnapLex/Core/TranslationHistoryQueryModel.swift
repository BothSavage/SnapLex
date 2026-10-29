import Combine
import Foundation

@MainActor
final class TranslationHistoryQueryModel: ObservableObject {
    @Published private(set) var summary = TranslationHistorySummary()
    @Published private(set) var entries: [TranslationHistoryEntry] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingTerms = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var failed = false

    private struct CacheKey: Hashable {
        let period: TranslationHistoryPeriod
        let search: String
        let revision: UInt64
        let start: Date
        let calendar: Calendar
    }
    private struct CachedResult {
        let range: TranslationHistoryRange
        var summary: TranslationHistorySummary
        var page: TranslationHistoryPage
        var termsRevision: UInt64?
    }
    private var cache: [CacheKey: CachedResult] = [:]
    private var currentKey: CacheKey?
    private var completedRecordsKey: CacheKey?
    private var currentRange: TranslationHistoryRange?
    private var learningTranslation: [Int64: Bool] = [:]
    private var termsRevision: UInt64?
    private var generation = 0

    func learningText(for entry: TranslationHistoryEntry) -> String {
        learningTranslation[entry.id] == true ? entry.translatedText : entry.inputText
    }

    func contextText(for entry: TranslationHistoryEntry) -> String {
        learningTranslation[entry.id] == true ? entry.inputText : entry.translatedText
    }

    func load(store: TranslationHistoryStore, period: TranslationHistoryPeriod, search: String, now: Date = Date(), calendar: Calendar = .current, includeTerms: Bool = true) async {
        generation += 1
        let request = generation
        await store.waitForPendingWrites()
        guard !Task.isCancelled, generation == request else { return }
        let cleanSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = TranslationHistoryRange(start: period.startDate(now: now, calendar: calendar), end: now, search: cleanSearch)
        let key = CacheKey(period: period, search: cleanSearch, revision: store.recordsRevision, start: range.start, calendar: calendar)
        // Remove all old record revisions immediately, including their large
        // strings. Ignored-word changes only invalidate vocabulary results.
        cache = cache.filter { $0.key.revision == key.revision }
        let vocabularyRevision = store.revision
        let recordsRevision = store.recordsRevision
        let url = store.databaseURL
        let ignored = store.ignoredWords
        let sameRecords = completedRecordsKey == key && currentRange != nil && !failed
        failed = false
        isLoadingPage = false
        isLoadingTerms = includeTerms
        do {
            if !sameRecords {
                currentKey = key
                completedRecordsKey = nil
                currentRange = range
                entries = []
                learningTranslation = [:]
                summary = TranslationHistorySummary()
                termsRevision = nil
                hasMore = false
                isLoading = true
                if period != .lastMonth, let cached = cache[key], now.timeIntervalSince(cached.range.end) >= 0, now.timeIntervalSince(cached.range.end) < 30 {
                    currentRange = cached.range
                    summary = cached.summary
                    entries = cached.page.entries
                    learningTranslation = cached.page.learningTranslation
                    hasMore = cached.page.hasMore
                    termsRevision = cached.termsRevision
                } else {
                    async let pageResult = TranslationHistoryQuery.page(databaseURL: url, range: range)
                    async let countsResult = TranslationHistoryQuery.summary(databaseURL: url, range: range, ignoredWords: [], calendar: calendar, includeTerms: false, revision: recordsRevision)
                    let page = try await pageResult
                    guard !Task.isCancelled, generation == request else { return }
                    entries = page.entries
                    learningTranslation = page.learningTranslation
                    hasMore = page.hasMore
                    let counts = try await countsResult
                    guard !Task.isCancelled, generation == request else { return }
                    summary = counts
                }
                completedRecordsKey = key
            }
            isLoading = false
            if termsRevision != vocabularyRevision {
                summary.terms = []
                summary.distinctTermCount = 0
                termsRevision = nil
            }
            if includeTerms, termsRevision != vocabularyRevision, let currentRange {
                let calculated = try await TranslationHistoryQuery.summary(databaseURL: url, range: currentRange, ignoredWords: ignored, calendar: calendar, termLimit: 100, revision: recordsRevision)
                guard !Task.isCancelled, generation == request else { return }
                summary = calculated
                termsRevision = vocabularyRevision
            }
            isLoadingTerms = false
            if let currentRange, period != .lastMonth {
                if cache.count >= 8 { cache.removeAll(keepingCapacity: true) }
                let firstEntries = Array(entries.prefix(50))
                let firstIDs = Set(firstEntries.map(\.id))
                let firstLanguages = learningTranslation.filter { firstIDs.contains($0.key) }
                cache[key] = CachedResult(range: currentRange, summary: summary, page: TranslationHistoryPage(entries: firstEntries, hasMore: hasMore || entries.count > 50, learningTranslation: firstLanguages), termsRevision: termsRevision)
            }
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            isLoading = false
            isLoadingTerms = false
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
            learningTranslation.merge(page.learningTranslation) { _, new in new }
            hasMore = page.hasMore
        } catch {
            guard !Task.isCancelled, generation == request else { return }
            failed = true
        }
    }
}

@MainActor
final class TranslationHistoryOverviewModel: ObservableObject {
    enum Scope { case dashboard, popover }

    @Published private(set) var today = TranslationHistorySummary()
    @Published private(set) var week = TranslationHistorySummary()
    @Published private(set) var lastDay = TranslationHistorySummary()
    @Published private(set) var failed = false
    @Published private(set) var isLoading = false
    private var generation = 0

    func load(store: TranslationHistoryStore, scope: Scope = .dashboard, now: Date = Date(), calendar: Calendar = .current) async {
        generation += 1
        let request = generation
        isLoading = true
        await store.waitForPendingWrites()
        guard !Task.isCancelled, request == generation else { return }
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let url = store.databaseURL
        let ignored = store.ignoredWords
        let revision = store.recordsRevision
        do {
            async let weekResult = TranslationHistoryQuery.summary(databaseURL: url, range: .init(start: weekStart, end: now, search: ""), ignoredWords: [], calendar: calendar, includeTerms: false, revision: revision)
            // Each screen requests only the vocabulary window it renders.
            let start = scope == .dashboard ? todayStart : now.addingTimeInterval(-86_400)
            async let vocabularyResult = TranslationHistoryQuery.summary(databaseURL: url, range: .init(start: start, end: now, search: ""), ignoredWords: ignored, calendar: calendar, termLimit: scope == .dashboard ? 5 : 3, revision: revision)
            let results = try await (weekResult, vocabularyResult)
            guard !Task.isCancelled, request == generation else { return }
            week = results.0
            if scope == .dashboard { today = results.1 } else { lastDay = results.1 }
            isLoading = false
            failed = false
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            isLoading = false
            failed = true
        }
    }
}
