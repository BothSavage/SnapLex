import AppKit
import Charts
import SwiftUI

public enum DashboardSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case home
    case translations
    case screenshots
    case shortcuts
    case preferences

    public var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .home: return "首页"
        case .translations: return "翻译记录"
        case .screenshots: return "截图记录"
        case .shortcuts: return "快捷键设置"
        case .preferences: return "偏好设置"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .translations: return "character.book.closed"
        case .screenshots: return "photo.on.rectangle"
        case .shortcuts: return "keyboard"
        case .preferences: return "slider.horizontal.3"
        }
    }
}

@MainActor
public final class DashboardNavigation: ObservableObject {
    public static let shared = DashboardNavigation()
    @Published public var selectedSection: DashboardSection

    public init(initialSection: DashboardSection = .home) {
        selectedSection = initialSection
    }

    public func select(_ section: DashboardSection) {
        guard selectedSection != section else { return }
        selectedSection = section
    }
}

public struct DashboardView: View {
    @ObservedObject private var navigation: DashboardNavigation
    private let translationStore: TranslationHistoryStore
    private let screenshotStore: ScreenshotHistoryStore
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    public init(
        navigation: DashboardNavigation? = nil,
        translationStore: TranslationHistoryStore? = nil,
        screenshotStore: ScreenshotHistoryStore? = nil
    ) {
        _navigation = ObservedObject(wrappedValue: navigation ?? .shared)
        self.translationStore = translationStore ?? .shared
        self.screenshotStore = screenshotStore ?? .shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                HStack(spacing: 10) {
                    SnapLexBrandLogoView(
                        size: 34,
                        showBadgeBackground: true,
                        foregroundColor: SnapLexTheme.toolbarForeground(for: colorScheme),
                        badgeBackgroundColor: SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.045),
                        badgeStrokeColor: SnapLexTheme.toolbarBorder(for: colorScheme)
                    )
                    Text("SnapLex")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }

                Spacer(minLength: 14)

                HStack(spacing: 4) {
                    ForEach(DashboardSection.allCases) { section in
                        Button {
                            navigation.select(section)
                        } label: {
                            Label(L10n.string(section.titleKey), systemImage: section.symbol)
                                .font(.system(size: 12, weight: navigation.selectedSection == section ? .semibold : .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                                .foregroundStyle(navigation.selectedSection == section ? Color.primary : Color.secondary)
                                .background {
                                    if navigation.selectedSection == section {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.075))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: navigation.selectedSection)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.8)

            Group {
                switch navigation.selectedSection {
                case .home:
                    DashboardHomeView(
                        navigation: navigation,
                        translations: translationStore,
                        screenshots: screenshotStore
                    )
                case .translations:
                    TranslationHistoryView(store: translationStore)
                case .screenshots:
                    ScreenshotHistoryView(store: screenshotStore)
                case .shortcuts:
                    SettingsView(section: .shortcuts)
                case .preferences:
                    SettingsView(section: .preferences)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
    }
}

struct DashboardDayCount: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

private struct DashboardHomeView: View {
    @ObservedObject private var navigation: DashboardNavigation
    @ObservedObject private var translations: TranslationHistoryStore
    @ObservedObject private var screenshots: ScreenshotHistoryStore
    @Environment(\.colorScheme) private var colorScheme

    init(navigation: DashboardNavigation, translations: TranslationHistoryStore, screenshots: ScreenshotHistoryStore) {
        _navigation = ObservedObject(wrappedValue: navigation)
        _translations = ObservedObject(wrappedValue: translations)
        _screenshots = ObservedObject(wrappedValue: screenshots)
    }

    private var todayEntries: [TranslationHistoryEntry] {
        let start = Calendar.current.startOfDay(for: Date())
        return translations.entries.filter { $0.createdAt >= start }
    }

    private var weekEntries: [TranslationHistoryEntry] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return translations.entries.filter { $0.createdAt >= start }
    }

    private var dailyCounts: [DashboardDayCount] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: weekEntries) { calendar.startOfDay(for: $0.createdAt) }
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: today) else { return nil }
            return DashboardDayCount(date: date, count: grouped[date]?.count ?? 0)
        }
    }

    private var topTerms: [TranslationTermStatistic] {
        translations.termStatistics(for: todayEntries).prefix(5).map { $0 }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.string("SnapLex 控制台"))
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text(L10n.formattedDate(Date.now, dateStyle: .full, timeStyle: .none))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DashboardPrimaryButton(title: L10n.string("立即截图"), icon: "viewfinder") {
                        WindowManager.shared.triggerScreenshotFlow()
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    DashboardMetricCard(
                        title: L10n.string("今日翻译次数"),
                        value: "\(todayEntries.count)",
                        detail: L10n.string("划词翻译和截图翻译"),
                        icon: "character.book.closed"
                    )
                    DashboardMetricCard(
                        title: L10n.string("近 7 天翻译次数"),
                        value: "\(weekEntries.count)",
                        detail: L10n.string("每日翻译频率"),
                        icon: "chart.bar.xaxis"
                    )
                    DashboardMetricCard(
                        title: L10n.string("截图记录"),
                        value: "\(screenshots.records.count)",
                        detail: L10n.format("保留最近 %d 张截图", AppSettings.shared.screenshotHistoryLimit),
                        icon: "photo.on.rectangle"
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        DashboardSectionTitle(title: L10n.string("快捷操作"))
                        HStack(spacing: 10) {
                            DashboardActionTile(title: L10n.string("截图"), subtitle: L10n.string("框选并标注"), icon: "viewfinder") {
                                WindowManager.shared.triggerScreenshotFlow()
                            }
                            DashboardActionTile(title: L10n.string("录屏"), subtitle: L10n.string("区域或窗口"), icon: "record.circle") {
                                ScreenRecorderManager.shared.showAssistant()
                            }
                            DashboardActionTile(title: L10n.string("贴图"), subtitle: L10n.string("来自剪贴板"), icon: "pin") {
                                WindowManager.shared.triggerPinFlow()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        DashboardSectionTitle(title: L10n.string("今日翻译频率"))
                        Chart(dailyCounts) { item in
                            BarMark(
                                x: .value(L10n.string("日期"), item.date, unit: .day),
                                y: .value(L10n.string("翻译次数"), item.count)
                            )
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(4)
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(L10n.locale))
                            }
                        }
                        .chartYAxis(.hidden)
                        .frame(height: 92)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(dashboardCardBackground)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            DashboardSectionTitle(title: L10n.string("最近截图"))
                            Spacer()
                            DashboardTextButton(title: L10n.string("查看全部")) {
                                navigation.select(.screenshots)
                            }
                        }
                        if screenshots.records.isEmpty {
                            DashboardEmptyCard(title: L10n.string("还没有截图记录"), icon: "photo.on.rectangle")
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(minimum: 0), spacing: 12),
                                    GridItem(.flexible(minimum: 0), spacing: 12)
                                ],
                                spacing: 12
                            ) {
                                ForEach(Array(screenshots.records.prefix(4))) { record in
                                    DashboardScreenshotTile(record: record) {
                                        NSWorkspace.shared.open(record.fileURL)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            DashboardSectionTitle(title: L10n.string("今日高频词"))
                            Spacer()
                            DashboardTextButton(title: L10n.string("查看记录")) {
                                navigation.select(.translations)
                            }
                        }
                        if topTerms.isEmpty {
                            DashboardEmptyCard(title: L10n.string("今天还没有翻译记录"), icon: "textformat.abc")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(topTerms.enumerated()), id: \.element.id) { index, item in
                                    HStack(spacing: 10) {
                                        Text(item.term)
                                            .font(.system(size: 14, weight: .semibold))
                                        Text(item.latestTranslation)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(L10n.format("%d 次", item.count))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 10)
                                    if index < topTerms.count - 1 { Divider() }
                                }
                            }
                            .padding(.horizontal, 14)
                            .background(dashboardCardBackground)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        DashboardSectionTitle(title: L10n.string("最近翻译"))
                        Spacer()
                        DashboardTextButton(title: L10n.string("查看全部")) {
                            navigation.select(.translations)
                        }
                    }
                    if todayEntries.isEmpty {
                        DashboardEmptyCard(title: L10n.string("今天还没有翻译记录"), icon: "character.book.closed")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(todayEntries.prefix(5))) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: entry.sourceKind == "screenshot" ? "viewfinder" : "text.cursor")
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(translations.learningText(for: entry))
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text(translations.contextText(for: entry))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(L10n.formattedDate(entry.createdAt, dateStyle: .none, timeStyle: .short))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                if entry.id != todayEntries.prefix(5).last?.id { Divider() }
                            }
                        }
                        .background(dashboardCardBackground)
                    }
                }
            }
            .padding(26)
        }
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
    }

    private var dashboardCardBackground: some ShapeStyle {
        Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.035)
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.7))
    }
}

private struct DashboardActionTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardPrimaryButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 11.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
    }
}

private struct DashboardSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
    }
}

private struct DashboardEmptyCard: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DashboardScreenshotTile: View {
    let record: ScreenshotHistoryRecord
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                DashboardScreenshotPreview(image: image, height: 104)
                Text(L10n.formattedDate(record.createdAt))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .clipped()
        }
        .buttonStyle(.plain)
        .task(id: record.id) {
            image = await ScreenshotThumbnailLoader.load(for: record.fileURL)
        }
    }
}

/// Keeps dashboard thumbnails inside their grid cell even when the source
/// screenshot is much larger or has a very different aspect ratio.
struct DashboardScreenshotPreview: View {
    let image: NSImage?
    let height: CGFloat

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
