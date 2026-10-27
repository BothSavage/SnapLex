import AppKit
import Charts
import SwiftUI

public struct ControlPanelPopoverView: View {
    let onScreenshot: () -> Void
    let onRecord: () -> Void
    let onPinClipboard: () -> Void
    let onPinScreenshot: (URL) -> Void
    let onOpenDashboard: (DashboardSection) -> Void
    let onQuit: () -> Void
    let onRestart: () -> Void

    @ObservedObject private var translations = TranslationHistoryStore.shared
    @ObservedObject private var screenshots = ScreenshotHistoryStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var actionHandlers: ControlPanelActionHandlers {
        ControlPanelActionHandlers(
            onScreenshot: onScreenshot,
            onRecord: onRecord,
            onPinClipboard: onPinClipboard,
            onOpenDashboard: onOpenDashboard,
            onQuit: onQuit,
            onRestart: onRestart
        )
    }

    private var lastDayEntries: [TranslationHistoryEntry] {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        return translations.entries.filter { $0.createdAt >= cutoff }
    }

    private var recentDailyCounts: [DashboardDayCount] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
        let recent = translations.entries.filter { $0.createdAt >= cutoff }
        let grouped = Dictionary(grouping: recent) { calendar.startOfDay(for: $0.createdAt) }
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 6, to: today) else { return nil }
            return DashboardDayCount(date: date, count: grouped[date]?.count ?? 0)
        }
    }

    private var frequentTerms: [TranslationTermStatistic] {
        Array(translations.termStatistics(for: lastDayEntries).prefix(3))
    }

    public init(
        onScreenshot: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onPinClipboard: @escaping () -> Void,
        onPinScreenshot: @escaping (URL) -> Void,
        onOpenDashboard: @escaping (DashboardSection) -> Void,
        onQuit: @escaping () -> Void,
        onRestart: @escaping () -> Void
    ) {
        self.onScreenshot = onScreenshot
        self.onRecord = onRecord
        self.onPinClipboard = onPinClipboard
        self.onPinScreenshot = onPinScreenshot
        self.onOpenDashboard = onOpenDashboard
        self.onQuit = onQuit
        self.onRestart = onRestart
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SnapLexBrandLogoView(
                    size: 32,
                    showBadgeBackground: true,
                    foregroundColor: SnapLexTheme.toolbarForeground(for: colorScheme),
                    badgeBackgroundColor: SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.045),
                    badgeStrokeColor: SnapLexTheme.toolbarBorder(for: colorScheme)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("SnapLex")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(L10n.string("截图、翻译与记录"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    actionHandlers.perform(.openDashboard(.home))
                } label: {
                    Label(L10n.string("打开控制台"), systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(SnapLexPressButtonStyle())
                .help(L10n.string("打开控制台"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            HStack(spacing: 10) {
                Button { actionHandlers.perform(.restart) } label: {
                    Label(L10n.string("重启 SnapLex"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                Button { actionHandlers.perform(.quit) } label: {
                    Label(L10n.string("退出 SnapLex"), systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            // Keep the primary capture actions anchored in the popover. The
            // history below can scroll, but these controls should remain
            // visible whenever the menu-bar panel is open.
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.string("常用截图操作"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ControlPanelActionButton(title: L10n.string("截图"), icon: "viewfinder") {
                        actionHandlers.perform(.screenshot)
                    }
                    ControlPanelActionButton(title: L10n.string("录屏"), icon: "record.circle") {
                        actionHandlers.perform(.recording)
                    }
                    ControlPanelActionButton(title: L10n.string("贴图"), icon: "pin") {
                        actionHandlers.perform(.pinClipboard)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(L10n.string("最近截图"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.string("查看全部")) {
                                actionHandlers.perform(.openDashboard(.screenshots))
                            }
                                .font(.system(size: 10.5, weight: .medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }

                        VStack(spacing: 0) {
                            if screenshots.records.isEmpty {
                                Label(L10n.string("还没有截图记录"), systemImage: "photo.on.rectangle")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 70)
                            } else {
                                ForEach(Array(screenshots.records.prefix(3).enumerated()), id: \.element.id) { index, record in
                                    ControlPanelScreenshotRow(record: record) {
                                        onPinScreenshot(record.fileURL)
                                    }
                                    if index < min(3, screenshots.records.count) - 1 { Divider() }
                                }
                            }
                        }
                        .padding(.horizontal, 9)
                        .background(popoverCardBackground)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.string("翻译频率"))
                                    .font(.system(size: 12, weight: .semibold))
                                Text(L10n.string("最近 24 小时"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(lastDayEntries.count)")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                            Text(L10n.string("次"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }

                        Chart(recentDailyCounts) { item in
                            BarMark(
                                x: .value(L10n.string("日期"), item.date, unit: .day),
                                y: .value(L10n.string("翻译次数"), item.count)
                            )
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(3)
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 7)) { value in
                                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(L10n.locale))
                            }
                        }
                        .chartYAxis(.hidden)
                        .frame(height: 54)

                        if !frequentTerms.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(frequentTerms) { term in
                                    HStack(spacing: 4) {
                                        Text(term.term).lineLimit(1)
                                        Text("· \(term.count)").foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.primary.opacity(0.055), in: Capsule())
                                }
                            }
                        }

                        Button {
                            actionHandlers.perform(.openDashboard(.translations))
                        } label: {
                            HStack {
                                Text(L10n.string("查看翻译记录"))
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(popoverCardBackground)
                }
                .padding(14)
            }

        }
        .frame(width: 360, height: 600)
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
        .onAppear { screenshots.reload() }
    }

    private var popoverCardBackground: some ShapeStyle {
        Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.04)
    }
}

private struct ControlPanelActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .foregroundStyle(Color.primary.opacity(0.86))
            .background(Color.primary.opacity(isHovered ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapLexPressButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

private struct ControlPanelScreenshotRow: View {
    let record: ScreenshotHistoryRecord
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.05))
                    }
                }
                .frame(width: 58, height: 42)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.formattedDate(record.createdAt))
                        .font(.system(size: 10.5, weight: .medium))
                    Text("\(record.pixelWidth) × \(record.pixelHeight)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(SnapLexPressButtonStyle())
        .task(id: record.id) {
            image = await ScreenshotThumbnailLoader.load(for: record.fileURL, maxPixelSize: 480)
        }
    }
}
