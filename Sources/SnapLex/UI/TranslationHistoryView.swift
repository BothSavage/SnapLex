import Charts
import SwiftUI

private enum TranslationHistoryPeriod: String, CaseIterable, Identifiable {
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

    func includes(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
        case .last7Days:
            start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .lastMonth:
            start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .last30Days:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
        return date >= start && date <= now
    }

    var numberOfDays: Int {
        switch self {
        case .today: return 1
        case .last7Days: return 7
        case .lastMonth: return 31
        case .last30Days: return 30
        }
    }
}

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

public struct TranslationHistoryView: View {
    @ObservedObject private var store = TranslationHistoryStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var period: TranslationHistoryPeriod = .today
    @State private var mode: TranslationHistoryMode = .terms
    @State private var showingIgnoredWords = false
    @State private var showingClearConfirmation = false

    private var filteredEntries: [TranslationHistoryEntry] {
        store.entries.filter { period.includes($0.createdAt) }
    }

    private var termStatistics: [TranslationTermStatistic] {
        store.termStatistics(for: filteredEntries)
    }

    private var dailyCounts: [TranslationHistoryDay] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let entriesByDay = Dictionary(grouping: filteredEntries) { calendar.startOfDay(for: $0.createdAt) }
        return (0..<period.numberOfDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -(period.numberOfDays - offset - 1), to: today) else {
                return nil
            }
            return TranslationHistoryDay(day: date, count: entriesByDay[date]?.count ?? 0)
        }
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            HStack(spacing: 12) {
                metricCard(title: L10n.string("翻译次数"), value: "\(filteredEntries.count)", icon: "character.book.closed")
                metricCard(title: L10n.string("词汇数量"), value: "\(termStatistics.count)", icon: "textformat.abc")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("翻译频率"))
                    .font(.system(size: 13, weight: .semibold))
                Chart(dailyCounts) { item in
                    BarMark(
                        x: .value(L10n.string("日期"), item.day, unit: .day),
                        y: .value(L10n.string("翻译次数"), item.count)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(7, period.numberOfDays))) { value in
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
                    recordsList
                } else {
                    termsList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 650)
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
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

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        L10n.string("没有翻译记录"),
                        systemImage: "text.book.closed",
                        description: Text(L10n.string("完成划词翻译或截图翻译后，记录会显示在这里。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(store.learningText(for: entry))
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
                                Text(store.contextText(for: entry))
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
                }
            }
        }
    }

    private var termsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if termStatistics.isEmpty {
                    ContentUnavailableView(
                        L10n.string("没有词频数据"),
                        systemImage: "textformat.abc",
                        description: Text(L10n.string("被加入忽略词的单词不会计入词频统计。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(Array(termStatistics.prefix(100).enumerated()), id: \.element.id) { index, item in
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
                        if index < min(termStatistics.count, 100) - 1 {
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
