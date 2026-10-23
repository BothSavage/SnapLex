import SwiftUI
import AppKit

public struct FloatingTranslatorView: View {
    @ObservedObject var vm = TranslatorViewModel.shared
    @ObservedObject var vocabStore = VocabularyStore.shared
    @ObservedObject var hotKeyMgr = SelectionAndHotKeyManager.shared

    var onTriggerScreenshot: () -> Void
    var onOpenVocabWindow: () -> Void
    var onOpenSettingsWindow: () -> Void
    var onClosePanel: () -> Void

    @State private var copiedFeedback: Bool = false
    @State private var savedToast: Bool = false

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
            // MARK: - Top Drag Handle (=)
            HStack {
                Spacer()
                VStack(spacing: 2.5) {
                    Capsule()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: 14, height: 1.8)
                    Capsule()
                        .fill(Color.black.opacity(0.28))
                        .frame(width: 14, height: 1.8)
                }
                Spacer()
            }
            .padding(.top, 6)
            .padding(.bottom, -4)

            // MARK: - Header Row (Avatar + "这里是我的翻译" + Pin)
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.25, green: 0.47, blue: 0.96), Color(red: 0.55, green: 0.36, blue: 0.96)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 24, height: 24)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text(vm.taskMode.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.48, blue: 0.54))

                if let existing = vm.matchedVocabItem {
                    Text("🔥 已存生词 · 第\(existing.lookupCount)次")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                // Quick Menu for Screenshot / Vocab Book / Settings
                Menu {
                    Button("截图 OCR 翻译 (⌥ + S)") { onTriggerScreenshot() }
                    Button("打开语境生词本 (\(vocabStore.items.count))") { onOpenVocabWindow() }
                    Divider()
                    Button("API 与双写偏好设置...") { onOpenSettingsWindow() }
                    Button("关闭窗口 (Esc)") { onClosePanel() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.45, green: 0.48, blue: 0.54))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                // Pin Button (Matches Image 2 top-right thumbtack)
                Button(action: { vm.isPinned.toggle() }) {
                    Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 14))
                        .foregroundStyle(vm.isPinned ? Color.blue : Color(red: 0.45, green: 0.48, blue: 0.54))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(vm.isPinned ? "取消固定" : "固定窗口")
            }

            // MARK: - Accessibility Permission Guide Banner (Only shown until granted)
            if !hotKeyMgr.isAXTrusted {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(.orange)
                    Text("开启「鼠标划词即弹」需勾选辅助功能权限")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.20, green: 0.22, blue: 0.26))
                    Spacer()
                    Button("去勾选开启") {
                        hotKeyMgr.openSystemAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                )
            }

            // MARK: - Language Selector Bar (自动检测  ->  English v)
            HStack(spacing: 12) {
                // Left Box: 自动检测
                HStack {
                    Text(vm.sourceLangLabel)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color(red: 0.52, green: 0.55, blue: 0.60))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.98, green: 0.98, blue: 0.99))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.35, green: 0.38, blue: 0.42))

                // Right Box: Target Language Dropdown
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
                    HStack {
                        Text(vm.targetLangLabel)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.45, green: 0.48, blue: 0.54))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.09), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            // MARK: - Main Translation Body (Scrollable)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Optional Screenshot Thumbnail or Editable Original Text (toggled via ⇅)
                    if vm.showOriginalText || vm.capturedImage != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let img = vm.capturedImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            if vm.showOriginalText {
                                TextField("输入或修改原文后按回车重译...", text: $vm.inputText, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(red: 0.40, green: 0.43, blue: 0.48))
                                    .lineLimit(1...5)
                                    .padding(8)
                                    .background(Color.black.opacity(0.035))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .onSubmit {
                                        vm.rerunCurrentInput()
                                    }
                            }
                        }
                    }

                    // Phonetic badge if single word
                    if !vm.phonetic.isEmpty {
                        HStack(spacing: 6) {
                            Text(vm.inputText)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))
                            Text(vm.phonetic)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.blue)
                        }
                    }

                    // Primary Translated Output (Matches Image 2 clean typography)
                    if let err = vm.errorMessage {
                        Text("⚠️ \(err)")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if vm.aiOutput.isEmpty && vm.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在翻译...")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 0.52, green: 0.55, blue: 0.60))
                        }
                        .padding(.vertical, 6)
                    } else {
                        Text(vm.aiOutput.isEmpty ? vm.systemDefinition : vm.aiOutput)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Color(red: 0.11, green: 0.13, blue: 0.16))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }

                    // Expandable macOS System Dictionary Detail (toggled via 📖 icon)
                    if vm.showSystemDictDetail && !vm.systemDefinition.isEmpty && !vm.aiOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS 系统词典释义")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color(red: 0.45, green: 0.48, blue: 0.54))
                            Text(vm.systemDefinition)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color(red: 0.25, green: 0.28, blue: 0.32))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Follow-up Answer Area (if user asked a follow-up question)
                    if !vm.followUpAnswer.isEmpty || vm.isStreamingFollowUp {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.blue)
                                Text("追问解答")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                if vm.isStreamingFollowUp {
                                    ProgressView()
                                        .controlSize(.mini)
                                }
                            }
                            Text(vm.followUpAnswer)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.20))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(minHeight: 76, maxHeight: 260)

            // MARK: - Action Icon Toolbar Row (⇅  ⮐  |  🔊  📋  🔄  +  ⭐生词本)
            HStack(spacing: 14) {
                // 1. ⇅ Toggle Original Text comparison
                ToolbarIconButton(
                    icon: "arrow.up.arrow.down",
                    isActive: vm.showOriginalText,
                    helpText: "显示/编辑原文对照"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.showOriginalText.toggle()
                    }
                }

                // 2. ⮐ Toggle macOS System Dictionary Detail
                ToolbarIconButton(
                    icon: "text.alignleft",
                    isActive: vm.showSystemDictDetail,
                    helpText: "展开/收起系统原生词典详情"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        vm.showSystemDictDetail.toggle()
                    }
                }

                // Vertical Divider
                Rectangle()
                    .fill(Color.black.opacity(0.10))
                    .frame(width: 1, height: 14)

                // 3. 🔊 Speak translation
                ToolbarIconButton(
                    icon: "speaker.wave.2",
                    helpText: "朗读译文"
                ) {
                    let textToSpeak = vm.aiOutput.isEmpty ? vm.inputText : vm.aiOutput
                    SystemDictionaryService.shared.speak(textToSpeak)
                }

                // 4. 📋 Copy translation
                ToolbarIconButton(
                    icon: copiedFeedback ? "checkmark" : "doc.on.doc",
                    isActive: copiedFeedback,
                    helpText: "复制译文"
                ) {
                    let textToCopy = vm.aiOutput.isEmpty ? vm.systemDefinition : vm.aiOutput
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToCopy, forType: .string)
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedFeedback = false
                    }
                }

                // 5. 🔄 Re-translate
                ToolbarIconButton(
                    icon: "arrow.triangle.2.circlepath",
                    helpText: "重新翻译"
                ) {
                    vm.rerunCurrentInput()
                }

                Spacer()

                // 6. ⭐ Save to Vocabulary Book (SQLite + Markdown)
                Button(action: {
                    vm.saveCurrentToVocab()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        savedToast = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        savedToast = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: savedToast ? "checkmark.circle.fill" : (vm.matchedVocabItem != nil ? "star.fill" : "star"))
                            .font(.system(size: 12))
                            .foregroundStyle(savedToast ? .green : (vm.matchedVocabItem != nil ? .orange : Color(red: 0.30, green: 0.33, blue: 0.38)))
                        Text(savedToast ? "已存入生词本" : (vm.matchedVocabItem != nil ? "已存生词" : "加生词本"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(savedToast ? .green : Color(red: 0.25, green: 0.28, blue: 0.32))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.045))
                    )
                }
                .buttonStyle(.plain)
                .help("同步保存至本地 SQLite 与 Vocabulary.md")
            }
            .padding(.top, 2)

            // MARK: - Bottom Follow-up Pill ("继续提问" + Circular Up Arrow)
            HStack(spacing: 8) {
                TextField("继续提问", text: $vm.followUpQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.20))
                    .onSubmit {
                        vm.submitFollowUp()
                    }

                Button(action: {
                    vm.submitFollowUp()
                }) {
                    let hasInput = !vm.followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ZStack {
                        Circle()
                            .fill(hasInput ? Color(red: 0.18, green: 0.42, blue: 0.96) : Color.black.opacity(0.16))
                            .frame(width: 26, height: 26)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(vm.followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.95, green: 0.955, blue: 0.965))
            )
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .padding(.top, 4)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
                .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.8)
        )
        .padding(18) // Outer margin for drop shadow in transparent NSPanel
        .environment(\.colorScheme, .light)
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Color.blue : Color(red: 0.25, green: 0.28, blue: 0.32))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.black.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
