import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var axTrusted: Bool = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)
    @State private var isPinned: Bool = WindowManager.shared.isSettingsPinned

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Top Fixed Header Bar (Below macOS Traffic Lights + Right Pin Button)
            HStack(alignment: .center, spacing: 14) {
                SnapLexBrandLogoView(size: 38, showBadgeBackground: true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("SnapLex")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.96))

                        Text("PRO")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(Color.white.opacity(0.90))
                            )
                    }

                    Text("极简屏幕捕捉 · 滚动长截图 · 贴图 · 划词翻译")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.50))
                }

                Spacer()

                // Pin Settings Window Button
                SettingsPinButton(isPinned: isPinned) {
                    isPinned.toggle()
                    WindowManager.shared.setSettingsPinned(isPinned)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 16)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.8)

            // MARK: - Scrollable Settings Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    // Section 1: 划词触发与权限
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderLabel(title: "划词与权限")

                        VStack(spacing: 0) {
                            MonochromeToggleRow(
                                title: "鼠标划词自动弹出控制栏",
                                subtitle: "选中文本松开鼠标后，在光标旁呼出 [翻译 · 复制 · 朗读] 胶囊",
                                isOn: $settings.enableMouseHoverBar
                            )

                            DividerLine()

                            MonochromeToggleRow(
                                title: "双击 ⌘C 呼出划词控制栏",
                                subtitle: "无需辅助功能权限，在任意应用中连续按两次 ⌘C 即可触发",
                                isOn: $settings.enableDoubleCmdC
                            )

                            DividerLine()

                            // Accessibility Status Row
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("macOS 辅助功能权限")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.92))
                                    Text(axTrusted ? "已授权，支持全局鼠标划词即弹" : "未授权，开启后可支持鼠标拖拽划词自动触发")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.white.opacity(0.46))
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(axTrusted ? Color.white : Color.white.opacity(0.32))
                                            .frame(width: 6, height: 6)
                                        Text(axTrusted ? "已就绪" : "未开启")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(Color.white.opacity(axTrusted ? 0.90 : 0.55))
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.06))
                                            .overlay(
                                                Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                                            )
                                    )

                                    if !axTrusted {
                                        MonochromeActionPillButton(title: "去授权") {
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
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                        )
                    }

                    // Section 2: 全局快捷键一览
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeaderLabel(title: "全局快捷键")

                        VStack(spacing: 0) {
                            ShortcutRow(
                                title: "区域截图 · 标注 · 滚动长截图 · OCR",
                                keys: ["F1", "⌥ S"]
                            )
                            DividerLine()
                            ShortcutRow(
                                title: "屏幕贴图 (将选区或剪贴板钉在桌面)",
                                keys: ["F3", "⌥ P"]
                            )
                            DividerLine()
                            ShortcutRow(
                                title: "恢复上一个关闭的贴图",
                                keys: ["⇧ F3"]
                            )
                            DividerLine()
                            ShortcutRow(
                                title: "屏幕录制 (区域 / 窗口 / 全屏导出 MP4 · GIF)",
                                keys: ["⌥ R"]
                            )
                            DividerLine()
                            ShortcutRow(
                                title: "划词直接翻译",
                                keys: ["⌥ A"]
                            )
                            DividerLine()
                            ShortcutRow(
                                title: "打开 / 隐藏翻译卡片",
                                keys: ["⌥ D"]
                            )
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
        }
        .frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity, minHeight: 540, idealHeight: 560, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
        .onAppear {
            isPinned = WindowManager.shared.isSettingsPinned
            axTrusted = SelectionAndHotKeyManager.shared.isAccessibilityTrusted(prompt: false)
        }
    }
}

private struct SettingsPinButton: View {
    let isPinned: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isPinned ? Color.black : Color.white.opacity(isHovered ? 0.95 : 0.72))
                Text(isPinned ? "已置顶" : "置顶")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isPinned ? Color.black : Color.white.opacity(isHovered ? 0.95 : 0.72))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isPinned
                            ? Color.white.opacity(0.92)
                            : Color.white.opacity(isHovered ? 0.14 : 0.07)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isPinned ? 0.0 : 0.14), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SectionHeaderLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
            .tracking(0.6)
            .padding(.leading, 2)
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
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
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.46))
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

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                isOn.toggle()
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn ? Color.white.opacity(0.92) : Color.white.opacity(0.12))
                    .frame(width: 36, height: 20)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(isOn ? 0.0 : 0.18), lineWidth: 0.8)
                    )

                Circle()
                    .fill(isOn ? Color(white: 0.08) : Color.white.opacity(0.65))
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.84))

            Spacer()

            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                        )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9.5)
    }
}

private struct MonochromeActionPillButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isHovered ? 1.0 : 0.88))
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
                .foregroundStyle(Color.white.opacity(isHovered ? 0.95 : 0.65))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.14 : 0.07))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
