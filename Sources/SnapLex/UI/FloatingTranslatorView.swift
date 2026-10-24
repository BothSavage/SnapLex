import SwiftUI
import AppKit

public struct FloatingTranslatorView: View {
    @ObservedObject var vm = TranslatorViewModel.shared
    @ObservedObject var hotKeyMgr = SelectionAndHotKeyManager.shared

    var onTriggerScreenshot: () -> Void
    var onOpenVocabWindow: () -> Void
    var onOpenSettingsWindow: () -> Void
    var onClosePanel: () -> Void

    @State private var copiedFeedback: Bool = false

    public init(
        onTriggerScreenshot: @escaping () -> Void,
        onOpenVocabWindow: @escaping () -> Void,
        onOpenSettingsWindow: @escaping () -> Void,
        onClosePanel: @escaping () -> Void
    ) {
        self.onTriggerScreenshot = onTriggerScreenshot
        self.onOpenVocabWindow = onOpenVocabWindow
        self.onOpenSettingsWindow = onOpenSettingsWindow
        self.onClosePanel = onClosePanel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: - Top Drag Handle
            HStack {
                Spacer()
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 30, height: 3)
                Spacer()
            }
            .padding(.top, 6)
            .padding(.bottom, -2)

            // MARK: - Top Header Bar: Language Selector + Pin & Close
            HStack(spacing: 8) {
                // Source Language Pill
                HStack(spacing: 6) {
                    Text(vm.sourceLangLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.76))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))

                // Target Language Dropdown Pill (wrapped outside Menu so border & background always render)
                Menu {
                    ForEach(AppSettings.targetLanguages, id: \.label) { lang in
                        Button(action: {
                            vm.changeTargetLanguage(to: lang.label)
                        }) {
                            HStack {
                                Text(lang.label)
                                if vm.targetLangLabel == lang.label {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(vm.targetLangLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.94))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )

                // Pin Window Button
                ToolbarIconButton(
                    icon: vm.isPinned ? "pin.fill" : "pin",
                    isActive: vm.isPinned,
                    helpText: vm.isPinned ? "取消固定" : "固定窗口"
                ) {
                    vm.isPinned.toggle()
                }

                // Close Button
                ToolbarIconButton(
                    icon: "xmark",
                    isActive: false,
                    helpText: "关闭"
                ) {
                    onClosePanel()
                }
            }

            // MARK: - Accessibility Permission Guide Banner (Only shown if not yet trusted)
            if !hotKeyMgr.isAXTrusted {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Text("开启「鼠标划词即弹」需授予辅助功能权限")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))
                    Spacer()
                    Button(action: {
                        hotKeyMgr.openSystemAccessibilitySettings()
                    }) {
                        Text("去开启")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(Color.white.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                        )
                )
            }

            // MARK: - Full Auto-Expanding Translation Content (Displays all content without clipping!)
            ViewThatFits(in: .vertical) {
                translationContentStack
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView(.vertical, showsIndicators: true) {
                    translationContentStack
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: 500)
            }
            .frame(minHeight: 110)

            // MARK: - Bottom Action Icon Toolbar Row (⇅  ≡  |  🔊  📋  🔄)
            HStack(spacing: 10) {
                ToolbarIconButton(
                    icon: "arrow.up.arrow.down",
                    isActive: vm.showOriginalText,
                    helpText: "原文对照"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.showOriginalText.toggle()
                    }
                }

                ToolbarIconButton(
                    icon: "text.alignleft",
                    isActive: vm.showSystemDictDetail,
                    helpText: "系统词典"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.showSystemDictDetail.toggle()
                    }
                }

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 1, height: 13)

                ToolbarIconButton(
                    icon: "speaker.wave.2",
                    helpText: "朗读"
                ) {
                    let textToSpeak = vm.aiOutput.isEmpty ? vm.inputText : vm.aiOutput
                    SystemDictionaryService.shared.speak(textToSpeak)
                }

                ToolbarIconButton(
                    icon: copiedFeedback ? "checkmark" : "doc.on.doc",
                    isActive: copiedFeedback,
                    helpText: "复制"
                ) {
                    let textToCopy = vm.aiOutput.isEmpty ? vm.systemDefinition : vm.aiOutput
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToCopy, forType: .string)
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        copiedFeedback = false
                    }
                }

                ToolbarIconButton(
                    icon: "arrow.triangle.2.circlepath",
                    helpText: "重译"
                ) {
                    vm.rerunCurrentInput()
                }

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 15)
        .padding(.top, 2)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.10, opacity: 0.96))
                .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .padding(16)
        .environment(\.colorScheme, .dark)
        .onChange(of: vm.aiOutput) { _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.systemDefinition) { _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.showOriginalText) { _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.showSystemDictDetail) { _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.isStreaming) { _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
    }

    @ViewBuilder
    private var translationContentStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.showOriginalText || vm.capturedImage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let img = vm.capturedImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                            )
                    }
                    if vm.showOriginalText {
                        TextField("输入或修改原文后按回车重译...", text: $vm.inputText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineLimit(1...6)
                            .padding(9)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                            )
                            .onSubmit {
                                vm.rerunCurrentInput()
                            }
                    }
                }
            }

            // Phonetic badge if single word
            if !vm.phonetic.isEmpty {
                HStack(spacing: 8) {
                    Text(vm.inputText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.96))
                    Text(vm.phonetic)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }

            // Primary Translated Output
            if let err = vm.errorMessage {
                Text("⚠️ \(err)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .textSelection(.enabled)
            } else if vm.aiOutput.isEmpty && vm.isStreaming {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("正在翻译...")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                .padding(.vertical, 8)
            } else {
                Text(vm.aiOutput.isEmpty ? vm.systemDefinition : vm.aiOutput)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineSpacing(5.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }

            // Expandable macOS System Dictionary Detail
            if vm.showSystemDictDetail && !vm.systemDefinition.isEmpty && !vm.aiOutput.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("系统词典释义")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.52))
                    Text(vm.systemDefinition)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                )
            }
        }
    }
}

private struct ToolbarIconButton: View {
    let icon: String
    var isActive: Bool = false
    let helpText: String
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(isActive || isHovered ? 1.0 : 0.68))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? Color.white.opacity(0.20)
                                : (isHovered ? Color.white.opacity(0.12) : Color.clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
