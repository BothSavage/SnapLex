import SwiftUI
import AppKit
import Translation

public struct FloatingTranslatorView: View {
    @ObservedObject var vm = TranslatorViewModel.shared
    @ObservedObject var hotKeyMgr = SelectionAndHotKeyManager.shared
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var onTriggerScreenshot: () -> Void
    var onOpenSettingsWindow: () -> Void
    var onClosePanel: () -> Void

    @State private var copiedFeedback: Bool = false

    public init(
        onTriggerScreenshot: @escaping () -> Void,
        onOpenSettingsWindow: @escaping () -> Void,
        onClosePanel: @escaping () -> Void
    ) {
        self.onTriggerScreenshot = onTriggerScreenshot
        self.onOpenSettingsWindow = onOpenSettingsWindow
        self.onClosePanel = onClosePanel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: - Top Drag Handle
            HStack {
                Spacer()
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 30, height: 3)
                Spacer()
            }
            .padding(.top, 6)
            .padding(.bottom, -2)

            // MARK: - Top Header Bar: Language Selector + Pin & Close
            HStack(spacing: 8) {
                // Source Language Pill
                HStack(spacing: 6) {
                    Text(L10n.string(vm.sourceLangLabel))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                )

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.42))

                // Target Language Dropdown Pill (wrapped outside Menu so border & background always render)
                Menu {
                    ForEach(AppSettings.targetLanguages, id: \.label) { lang in
                        Button(action: {
                            vm.changeTargetLanguage(to: lang.label)
                        }) {
                            HStack {
                                Text(L10n.string(lang.label))
                                if vm.targetLangLabel == lang.label {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.string(vm.targetLangLabel))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(0.92))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.48))
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
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
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
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Text(L10n.string("开启「鼠标划词即弹」需授予辅助功能权限"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.82))
                    Spacer()
                    Button(action: {
                        hotKeyMgr.openSystemAccessibilitySettings()
                    }) {
                        Text(L10n.string("去开启"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(SnapLexTheme.toolbarForeground(for: colorScheme)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
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
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 13)

                ToolbarIconButton(
                    icon: "speaker.wave.2",
                    helpText: "朗读"
                ) {
                    // Pronounce the selected source term (for example, “Pitch”),
                    // rather than its Chinese translation.
                    let textToSpeak = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? vm.translatedOutput
                        : vm.inputText
                    SystemDictionaryService.shared.speak(textToSpeak)
                }

                ToolbarIconButton(
                    icon: copiedFeedback ? "checkmark" : "doc.on.doc",
                    isActive: copiedFeedback,
                    helpText: "复制"
                ) {
                    let textToCopy = vm.translatedOutput.isEmpty ? vm.systemDefinition : vm.translatedOutput
                    SelectionAndHotKeyManager.shared.noteInternalClipboardWrite()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToCopy, forType: .string)
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        copiedFeedback = false
                    }
                }

                ToolbarTranslationEngineMenu(settings: settings) { engine in
                    TranslationEngineSelectionAction.select(
                        engine,
                        currentEngine: settings.translationEngine,
                        updateSetting: { settings.translationEngine = engine },
                        rerunCurrentInput: { vm.rerunCurrentInput() }
                    )
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
                .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
        )
        .padding(16)
        .snapLexAppearance()
        .onChange(of: vm.translatedOutput) { _, _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.systemDefinition) { _, _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.googleDictionaryEntries) { _, _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.showOriginalText) { _, _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.showSystemDictDetail) { _, _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .onChange(of: vm.isTranslating) { _, _ in
            WindowManager.shared.resizeCardPanelToFitContent()
        }
        .translationTask(vm.translationConfiguration) { session in
            await vm.translatePending(using: session)
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
                                    .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                            )
                    }
                    if vm.showOriginalText {
                        TextField(L10n.string("输入或修改原文后按回车重译..."), text: $vm.inputText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(1...6)
                            .padding(9)
                            .background(Color.primary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
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
                        .foregroundStyle(Color.primary.opacity(0.92))
                    Text(vm.phonetic)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.56))
                }
            }

            // Primary Translated Output
            if let err = vm.errorMessage {
                Text("⚠️ \(err)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.red.opacity(0.82))
                    .textSelection(.enabled)
            } else if vm.translatedOutput.isEmpty && vm.isTranslating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("正在翻译..."))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.58))
                }
                .padding(.vertical, 8)
            } else if vm.translatedOutput.isEmpty && !vm.systemDefinition.isEmpty {
                dictionaryDefinitionList(
                    fontSize: 15,
                    foreground: Color.primary.opacity(0.94),
                    lineSpacing: 5.5
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else {
                Text(vm.translatedOutput.isEmpty ? vm.systemDefinition : vm.translatedOutput)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.94))
                    .lineSpacing(5.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }

            if !vm.googleDictionaryEntries.isEmpty {
                googleDictionaryList
                    .padding(.top, 2)
            }

            // Expandable macOS System Dictionary Detail
            if vm.showSystemDictDetail && !vm.systemDefinition.isEmpty && !vm.translatedOutput.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("系统词典释义"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.52))
                    dictionaryDefinitionList(
                        fontSize: 13,
                        foreground: Color.primary.opacity(0.82),
                        lineSpacing: 4
                    )
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
                )
            }
        }
    }

    private var dictionaryDefinitionLines: [String] {
        vm.systemDefinition
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    @ViewBuilder
    private var googleDictionaryList: some View {
        if vm.googleDictionaryEntries.count > 10 {
            ScrollView(.vertical, showsIndicators: true) {
                googleDictionaryRows
            }
            .frame(height: 13 * 18.0)
        } else {
            googleDictionaryRows
        }
    }

    private var googleDictionaryRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(vm.googleDictionaryEntries.enumerated()), id: \.offset) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(row.element)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.primary.opacity(0.84))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dictionaryDefinitionList(fontSize: CGFloat, foreground: Color, lineSpacing: CGFloat) -> some View {
        if dictionaryDefinitionLines.count > 10 {
            ScrollView(.vertical, showsIndicators: true) {
                dictionaryDefinitionRows(fontSize: fontSize, foreground: foreground, lineSpacing: lineSpacing)
            }
            .frame(height: fontSize * 18)
        } else {
            dictionaryDefinitionRows(fontSize: fontSize, foreground: foreground, lineSpacing: lineSpacing)
        }
    }

    private func dictionaryDefinitionRows(fontSize: CGFloat, foreground: Color, lineSpacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(dictionaryDefinitionLines.enumerated()), id: \.offset) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(foreground.opacity(0.62))
                        .frame(width: 4, height: 4)
                        .padding(.top, fontSize * 0.48)
                    Text(row.element)
                        .font(.system(size: fontSize))
                        .foregroundStyle(foreground)
                        .lineSpacing(lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isActive || isHovered ? 0.92 : 0.62))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isActive
                                ? SnapLexTheme.toolbarSelection(for: colorScheme)
                                : (isHovered ? SnapLexTheme.toolbarHover(for: colorScheme) : Color.clear)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(L10n.string(helpText))
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ToolbarTranslationEngineMenu: View {
    @ObservedObject var settings: AppSettings
    let onSelect: (TranslationEngine) -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var selectedEngineLabel: String {
        settings.translationEngine == .google ? "Google" : "Apple"
    }

    var body: some View {
        Menu {
            engineOption(.google, title: L10n.string("Google 翻译"))
            engineOption(.apple, title: L10n.string("Apple 原生翻译"))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 11.5, weight: .medium))
                Text(selectedEngineLabel)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(isHovered ? 0.92 : 0.68))
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? SnapLexTheme.toolbarHover(for: colorScheme) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(L10n.string("翻译引擎"))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func engineOption(_ engine: TranslationEngine, title: String) -> some View {
        Button {
            onSelect(engine)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                if settings.translationEngine == engine {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
