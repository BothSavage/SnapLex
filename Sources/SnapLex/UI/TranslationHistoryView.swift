import Charts
import SwiftUI

private enum TranslationHistoryMode: String, CaseIterable, Identifiable {
    case terms
    case records

    var id: String { rawValue }
    var titleKey: String { self == .records ? "翻译记录" : "词频统计" }
}

private struct TranslationHistoryDay: Identifiable {
    let day: Date
    let count: Int
    var id: Date { day }
}

private struct QueryRequest: Hashable {
    let period: TranslationHistoryPeriod
    let search: String
    let revision: UInt64
    let retry: Int
    let includeTerms: Bool
}

public struct TranslationHistoryView: View {
    @ObservedObject private var store: TranslationHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var period: TranslationHistoryPeriod = .today
    @State private var mode: TranslationHistoryMode = .terms
    @State private var showingIgnoredWords = false
    @State private var showingClearConfirmation = false
    @State private var search = ""
    @State private var retry = 0
    @StateObject private var query = TranslationHistoryQueryModel()

    private func dailyCounts() -> [TranslationHistoryDay] {
        let calendar = Calendar.current
        let now = Date()
        return period.days(now: now, calendar: calendar).map { date in
            TranslationHistoryDay(day: date, count: query.summary.dailyCounts[date] ?? 0)
        }
    }

    @MainActor
    public init(store: TranslationHistoryStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? .shared)
    }

    public var body: some View {
        let entries = query.entries
        let statistics = query.summary.terms
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("翻译记录与统计"))
                        .font(.system(size: 21, weight: .semibold))
                    Text(L10n.string("自动汇总划词翻译和截图翻译"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingIgnoredWords = true
                } label: {
                    Label(L10n.string("忽略词"), systemImage: "text.badge.minus")
                }
                .help(L10n.string("管理不计入词频的单词"))
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .help(L10n.string("清空翻译记录"))
                .disabled(store.entries.isEmpty)
            }

            Picker(L10n.string("时间范围"), selection: $period) {
                ForEach(TranslationHistoryPeriod.allCases) { value in
                    Text(L10n.string(value.titleKey)).tag(value)
                }
            }
            .pickerStyle(.segmented)

            TextField(L10n.string("搜索翻译记录"), text: $search)
                .textFieldStyle(.roundedBorder)
                .help(L10n.string("搜索当前时间范围内的原文、译文和来源应用"))

            if query.failed {
                HStack {
                    Text(L10n.string("加载翻译记录失败"))
                        .foregroundStyle(.secondary)
                    Button(L10n.string("重试")) { retry += 1 }
                }
                .font(.system(size: 11.5))
            }

            HStack(spacing: 12) {
                metricCard(title: L10n.string("翻译次数"), value: query.isLoading ? "…" : "\(query.summary.count)", icon: "character.book.closed")
                metricCard(title: L10n.string("词汇数量"), value: query.isLoading || query.isLoadingTerms ? "…" : mode == .records ? "—" : "\(query.summary.distinctTermCount)", icon: "textformat.abc")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("翻译频率"))
                    .font(.system(size: 13, weight: .semibold))
                Chart(dailyCounts()) { item in
                    BarMark(
                        x: .value(L10n.string("日期"), item.day, unit: .day),
                        y: .value(L10n.string("翻译次数"), item.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(7, period.numberOfDays(now: Date(), calendar: Calendar.current)))) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day().locale(L10n.locale))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 112)
            }
            .padding(14)
            .background(cardBackground)

            Picker(L10n.string("记录视图"), selection: $mode) {
                ForEach(TranslationHistoryMode.allCases) { value in
                    Text(L10n.string(value.titleKey)).tag(value)
                }
            }
            .pickerStyle(.segmented)

            Group {
                if mode == .records {
                    recordsList(entries)
                } else {
                    termsList(statistics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 650)
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
        .task(id: QueryRequest(period: period, search: search, revision: store.revision, retry: retry, includeTerms: mode == .terms)) {
            if !search.isEmpty {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
            await query.load(store: store, period: period, search: search, includeTerms: mode == .terms)
        }
        .sheet(isPresented: $showingIgnoredWords) {
            IgnoredTranslationWordsView(store: store)
        }
        .confirmationDialog(
            L10n.string("清空全部翻译记录？"),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("清空翻译记录"), role: .destructive) {
                store.deleteAllEntries()
            }
            Button(L10n.string("取消"), role: .cancel) {}
        }
    }

    private func recordsList(_ entries: [TranslationHistoryEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if entries.isEmpty && query.isLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        L10n.string("没有翻译记录"),
                        systemImage: "text.book.closed",
                        description: Text(L10n.string("完成划词翻译或截图翻译后，记录会显示在这里。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(query.learningText(for: entry))
                                        .font(.system(size: 14, weight: .medium))
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(L10n.string(entry.sourceKind == "screenshot" ? "截图翻译" : "划词翻译"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.055), in: Capsule())
                                }
                                Text(query.contextText(for: entry))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                HStack(spacing: 8) {
                                    Text(entry.sourceApp)
                                    Text("·")
                                    Text(L10n.formattedDate(entry.createdAt))
                                }
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            }
                            Button(role: .destructive) {
                                store.deleteEntry(id: entry.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.string("删除此记录"))
                        }
                        .padding(12)
                        .background(cardBackground)
                    }
                    if query.hasMore {
                        ProgressView()
                            .padding()
                            .id(entries.last?.id)
                            .onAppear {
                                Task { await query.loadMore(store: store) }
                            }
                    }
                }
            }
        }
    }

    private func termsList(_ statistics: [TranslationTermStatistic]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if query.isLoading || query.isLoadingTerms {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if statistics.isEmpty {
                    ContentUnavailableView(
                        L10n.string("没有词频数据"),
                        systemImage: "textformat.abc",
                        description: Text(L10n.string("被加入忽略词的单词不会计入词频统计。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(Array(statistics.prefix(100).enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 26, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.term)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(item.latestTranslation)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(L10n.format("%d 次", item.count))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.055), in: Capsule())
                            Button {
                                store.addIgnoredWord(item.term)
                            } label: {
                                Image(systemName: "text.badge.minus")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.string("加入忽略词"))
                        }
                        .padding(.vertical, 9)
                        if index < min(statistics.count, 100) - 1 {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(cardBackground)
        }
    }

    private func metricCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some ShapeStyle {
        Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.035)
    }
}

private struct IgnoredTranslationWordsView: View {
    @ObservedObject var store: TranslationHistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("忽略词"))
                        .font(.system(size: 18, weight: .semibold))
                    Text(L10n.string("这些词仍保留在原始记录中，但不会计入词频统计。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("完成")) { dismiss() }
            }

            HStack(spacing: 8) {
                TextField(L10n.string("输入单词，例如 you"), text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button(action: addWord) {
                    Image(systemName: "plus")
                }
                .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                ForEach(store.ignoredWords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button(role: .destructive) {
                            store.removeIgnoredWord(word)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(18)
        .frame(width: 420, height: 400)
    }

    private func addWord() {
        store.addIgnoredWord(newWord)
        newWord = ""
    }
}
