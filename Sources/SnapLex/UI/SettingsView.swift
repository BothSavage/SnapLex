import SwiftUI
import AppKit

public enum SettingsViewSection: Equatable {
    case all
    case shortcuts
    case preferences
}

public struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var shortcutRecorder = ShortcutRecorderController.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @StateObject private var releaseUpdateChecker = GitHubReleaseUpdateService()
    @Environment(\.colorScheme) private var colorScheme
    @State private var axTrusted: Bool = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)
    @State private var isPinned: Bool = WindowManager.shared.isSettingsPinned
    private let section: SettingsViewSection

    public init(section: SettingsViewSection = .all) {
        self.section = section
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Top Fixed Header Bar (Below macOS Traffic Lights + Right Pin Button)
            if section == .all {
                HStack(alignment: .center, spacing: 14) {
                    SnapLexBrandLogoView(
                        size: 38,
                        showBadgeBackground: true,
                        foregroundColor: SnapLexTheme.toolbarForeground(for: colorScheme),
                        badgeBackgroundColor: SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.045),
                        badgeStrokeColor: SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.14)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("SnapLex")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.primary.opacity(0.96))

                            Text("PRO")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(SnapLexTheme.toolbarForeground(for: colorScheme)))
                        }

                        Text(L10n.string("极简屏幕捕捉 · 滚动长截图 · 贴图 · 划词翻译"))
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Color.primary.opacity(0.52))
                    }

                    Spacer()

                    SettingsPinButton(isPinned: isPinned) {
                        isPinned.toggle()
                        WindowManager.shared.setSettingsPinned(isPinned)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 0.8)
            }

            // MARK: - Scrollable Settings Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    if section == .all || section == .preferences {
                        VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderLabel(title: L10n.string("主题与语言"))
                        VStack(spacing: 0) {
                            SettingsChoiceRow(title: L10n.string("外观模式")) {
                                Picker("", selection: $settings.appearanceMode) {
                                    Text(L10n.string("跟随系统")).tag(SnapLexAppearanceMode.system)
                                    Text(L10n.string("浅色")).tag(SnapLexAppearanceMode.light)
                                    Text(L10n.string("深色")).tag(SnapLexAppearanceMode.dark)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                                .labelsHidden()
                                .accessibilityLabel(L10n.string("外观模式"))
                                .onChange(of: settings.appearanceMode) { _, _ in
                                    WindowManager.shared.applyAppearance()
                                }
                            }

                            DividerLine()

                            SettingsChoiceRow(title: L10n.string("应用语言")) {
                                Picker("", selection: $settings.appLanguage) {
                                    Text(L10n.string("English")).tag(AppLanguage.english)
                                    Text(L10n.string("简体中文")).tag(AppLanguage.chinese)
                                    Text(L10n.string("繁體中文")).tag(AppLanguage.traditionalChinese)
                                    Text(L10n.string("日本語")).tag(AppLanguage.japanese)
                                    Text(L10n.string("한국어")).tag(AppLanguage.korean)
                                    Text(L10n.string("Français")).tag(AppLanguage.french)
                                    Text(L10n.string("Deutsch")).tag(AppLanguage.german)
                                }
                                .pickerStyle(.menu)
                                .frame(width: 210, alignment: .trailing)
                                .labelsHidden()
                                .accessibilityLabel(L10n.string("应用语言"))
                            }

                            DividerLine()

                            SettingsChoiceRow(title: L10n.string("翻译引擎"), subtitle: L10n.string("Google 翻译需要网络；Apple 原生翻译由 macOS 提供。")) {
                                Picker("", selection: $settings.translationEngine) {
                                    Text(L10n.string("Google 翻译（默认）")).tag(TranslationEngine.google)
                                    Text(L10n.string("Apple 原生翻译")).tag(TranslationEngine.apple)
                                }
                                .pickerStyle(.menu)
                                .frame(width: 210, alignment: .trailing)
                                .labelsHidden()
                                .accessibilityLabel(L10n.string("翻译引擎"))
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.025))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
                        )
                        }
                    }

                    // Section 1: 划词触发与权限
                    if section == .all || section == .preferences {
                        VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderLabel(title: L10n.string("划词与权限"))

                        VStack(spacing: 0) {
                            MonochromeToggleRow(
                                title: L10n.string("鼠标划词自动弹出控制栏"),
                                subtitle: L10n.string("选中文本松开鼠标后，在光标旁呼出 [翻译 · 复制 · 朗读] 胶囊"),
                                isOn: $settings.enableMouseHoverBar
                            )

                            DividerLine()

                            MonochromeToggleRow(
                                title: L10n.string("双击 ⌘C 呼出划词控制栏"),
                                subtitle: L10n.string("需要辅助功能权限以安全识别输入框；连续按两次 ⌘C 呼出控制栏"),
                                isOn: $settings.enableDoubleCmdC
                            )

                            DividerLine()

                            // Accessibility Status Row
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.string("macOS 辅助功能权限"))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.primary.opacity(0.92))
                                    Text(L10n.string(axTrusted ? "已授权，支持全局鼠标划词即弹" : "未授权，开启后可支持鼠标拖拽划词自动触发"))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.primary.opacity(0.48))
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(axTrusted ? Color.primary : Color.primary.opacity(0.28))
                                            .frame(width: 6, height: 6)
                                        Text(L10n.string(axTrusted ? "已就绪" : "未开启"))
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(Color.primary.opacity(axTrusted ? 0.90 : 0.58))
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.primary.opacity(0.045))
                                            .overlay(
                                                Capsule().stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                                            )
                                    )

                                    if !axTrusted {
                                        MonochromeActionPillButton(title: L10n.string("去授权")) {
                                            axTrusted = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: true)
                                        }
                                    }

                                    MonochromeIconPillButton(icon: "arrow.clockwise") {
                                        axTrusted = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)

                            DividerLine()

                            MonochromeToggleRow(
                                title: L10n.string("登录时启动 SnapLex"),
                                subtitle: L10n.string("登录 macOS 后自动启动 SnapLex"),
                                isOn: Binding(
                                    get: { launchAtLogin.isEnabled },
                                    set: { launchAtLogin.setEnabled($0) }
                                )
                            )
                            if let error = launchAtLogin.errorMessage {
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 8)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                        )
                        }
                    }

                    // Section 2: 全局快捷键一览
                    if section == .all || section == .shortcuts {
                        VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionHeaderLabel(title: L10n.string("快捷键"))
                            Spacer()
                            Button(L10n.string("恢复默认快捷键")) {
                                settings.resetShortcutBindings()
                                shortcutRecorder.cancelCapture()
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .buttonStyle(.plain)
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(GlobalShortcut.allCases.enumerated()), id: \.element.id) { index, shortcut in
                                ShortcutRecorderRow(shortcut: shortcut)
                                if index < GlobalShortcut.allCases.count - 1 {
                                    DividerLine()
                                }
                            }
                            if let error = shortcutRecorder.errorMessage {
                                Text(error)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                        )
                        }
                        .onDisappear { shortcutRecorder.cancelCapture() }
                    }

                    if section == .all || section == .preferences {
                        VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderLabel(title: L10n.string("翻译记录与截图"))
                        VStack(spacing: 0) {
                            MonochromeToggleRow(
                                title: L10n.string("自动记录划词翻译"),
                                subtitle: L10n.string("将鼠标划词、快捷键和双击复制触发的翻译加入记录"),
                                isOn: $settings.recordSelectionTranslations
                            )
                            DividerLine()
                            MonochromeToggleRow(
                                title: L10n.string("自动记录截图翻译"),
                                subtitle: L10n.string("将截图识别并翻译的内容加入记录"),
                                isOn: $settings.recordScreenshotTranslations
                            )
                            DividerLine()
                            ScreenshotRetentionRow(limit: $settings.screenshotHistoryLimit)
                            DividerLine()
                            HStack(spacing: 8) {
                                Button {
                                    WindowManager.shared.showTranslationHistoryWindow()
                                } label: {
                                    Label(L10n.string("查看翻译记录"), systemImage: "chart.bar.xaxis")
                                }
                                Button {
                                    WindowManager.shared.showScreenshotHistoryWindow()
                                } label: {
                                    Label(L10n.string("管理截图记录"), systemImage: "photo.on.rectangle")
                                }
                                Spacer(minLength: 0)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.025))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                        )
                        }
                    }

                    if section == .all || section == .preferences {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeaderLabel(title: L10n.string("软件更新"))
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(L10n.format("当前版本 %@", releaseUpdateChecker.currentVersion))
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(.primary)
                                        updateStatus
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        Task { await releaseUpdateChecker.checkForUpdates() }
                                    } label: {
                                        Label(
                                            L10n.string(releaseUpdateChecker.state == .checking ? "检查中…" : "检查更新"),
                                            systemImage: "arrow.clockwise"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(releaseUpdateChecker.state == .checking)
                                }

                                if case let .updateAvailable(version, notes, releaseURL, downloadURL) = releaseUpdateChecker.state {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(L10n.format("发现新版本 %@", version))
                                            .font(.system(size: 12, weight: .semibold))
                                        if !notes.isEmpty {
                                            Text(notes)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(6)
                                                .textSelection(.enabled)
                                        }
                                        if let downloadURL {
                                            Link(destination: downloadURL) {
                                                Label(L10n.string("下载安装包"), systemImage: "arrow.down.circle")
                                            }
                                            .buttonStyle(.borderedProminent)
                                            Text(L10n.string("将通过浏览器下载安装包"))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Link(destination: releaseURL) {
                                                Label(L10n.string("查看 GitHub 发布页面"), systemImage: "arrow.up.right.square")
                                            }
                                            .font(.system(size: 11.5, weight: .medium))
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.025))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
        }
        .frame(
            minWidth: section == .all ? 520 : 760,
            idealWidth: section == .all ? 520 : 900,
            maxWidth: .infinity,
            minHeight: section == .all ? 540 : 620,
            idealHeight: section == .all ? 560 : 720,
            maxHeight: .infinity
        )
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
        .onAppear {
            isPinned = WindowManager.shared.isSettingsPinned
            axTrusted = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)
            launchAtLogin.refreshStatus()
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch releaseUpdateChecker.state {
        case .idle:
            Text(L10n.string("通过 GitHub Releases 检查最新正式版本"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        case .checking:
            Text(L10n.string("正在连接 GitHub…"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        case .upToDate:
            Text(L10n.string("当前已是最新正式版本"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        case .noRelease:
            Text(L10n.string("GitHub 上还没有正式版发布"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .updateAvailable:
            Text(L10n.string("发现可用更新"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

private struct SettingsChoiceRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                labelContent
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                control()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            VStack(alignment: .leading, spacing: 10) {
                labelContent
                control()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsPinButton: View {
    let isPinned: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isPinned ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary.opacity(isHovered ? 0.92 : 0.72))
                Text(L10n.string(isPinned ? "已置顶" : "置顶"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isPinned ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary.opacity(isHovered ? 0.92 : 0.72))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isPinned
                            ? SnapLexTheme.toolbarForeground(for: colorScheme)
                            : Color.primary.opacity(isHovered ? 0.08 : 0.045)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(SnapLexTheme.toolbarBorder(for: colorScheme).opacity(isPinned ? 0 : 1), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SectionHeaderLabel: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.52))
            .tracking(0.6)
            .padding(.leading, 2)
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.085))
            .frame(height: 0.8)
            .padding(.horizontal, 14)
    }
}

private struct MonochromeToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.primary.opacity(0.50))
            }

            Spacer()

            MonochromeSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct MonochromeSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? SnapLexTheme.toolbarForeground(for: colorScheme) : Color.primary.opacity(0.12))
                    .frame(width: 36, height: 20)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SnapLexTheme.toolbarBorder(for: colorScheme).opacity(isOn ? 0 : 1), lineWidth: 0.8)
                    )

                Circle()
                    .fill(isOn ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary.opacity(0.45))
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutRecorderRow: View {
    let shortcut: GlobalShortcut
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = ShortcutRecorderController.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(shortcut.titleKey))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.86))
                if shortcut == .screenshotOptionS || shortcut == .pinOptionP {
                    Text(L10n.string("备用快捷键"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                if recorder.activeShortcut == shortcut {
                    recorder.cancelCapture()
                } else {
                    recorder.beginCapturing(shortcut)
                }
            } label: {
                Text(recorder.activeShortcut == shortcut
                    ? L10n.string("按下新快捷键…")
                    : settings.shortcutBinding(for: shortcut).displayString)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(recorder.activeShortcut == shortcut
                                ? Color.accentColor.opacity(0.16)
                                : Color.primary.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .help(L10n.string("点击后按下新的快捷键；按 Esc 取消"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct ScreenshotRetentionRow: View {
    @Binding var limit: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("截图记录保留数量"))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.string("自动保存最近截图，超出数量后删除最旧图片"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Stepper(value: $limit, in: 1...1000, step: 10) {
                Text("\(limit)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(minWidth: 38, alignment: .trailing)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct MonochromeActionPillButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isHovered ? 1 : 0.88))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct MonochromeIconPillButton: View {
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(isHovered ? 0.88 : 0.66))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.085 : 0.045))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
