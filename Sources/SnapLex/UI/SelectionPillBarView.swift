import SwiftUI
import AppKit

public struct SelectionPillBarView: View {
    @ObservedObject var vm = TranslatorViewModel.shared
    var onSelectAction: (TranslationTaskMode) -> Void
    var onTriggerScreenshot: () -> Void
    var onOpenVocabWindow: () -> Void
    var onOpenSettingsWindow: () -> Void
    var onDismiss: () -> Void

    @State private var copiedFeedback: Bool = false
    @State private var savedFeedback: Bool = false

    public init(
        onSelectAction: @escaping (TranslationTaskMode) -> Void,
        onTriggerScreenshot: @escaping () -> Void,
        onOpenVocabWindow: @escaping () -> Void,
        onOpenSettingsWindow: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onSelectAction = onSelectAction
        self.onTriggerScreenshot = onTriggerScreenshot
        self.onOpenVocabWindow = onOpenVocabWindow
        self.onOpenSettingsWindow = onOpenSettingsWindow
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 2) {
            // 1. AI 搜索 / 解析
            PillBarButton(icon: "magnifyingglass", title: "AI 解析") {
                onSelectAction(.explain)
            }

            // 2. 翻译 (Expands into Image 2 Translation Card!)
            PillBarButton(icon: "character.bubble", title: "翻译") {
                onSelectAction(.translate)
            }

            // 3. 总结
            PillBarButton(icon: "doc.plaintext", title: "总结") {
                onSelectAction(.summarize)
            }

            // 4. 存生词 (SQLite + Markdown dual write)
            PillBarButton(
                icon: savedFeedback ? "checkmark.circle.fill" : (vm.matchedVocabItem != nil ? "flame.fill" : "star"),
                title: savedFeedback ? "已存生词" : (vm.matchedVocabItem != nil ? "已存(\(vm.matchedVocabItem!.lookupCount))" : "生词本"),
                tintColor: savedFeedback ? Color(red: 0.08, green: 0.65, blue: 0.35) : (vm.matchedVocabItem != nil ? .orange : nil)
            ) {
                vm.saveCurrentToVocab()
                withAnimation(.easeInOut(duration: 0.15)) {
                    savedFeedback = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    savedFeedback = false
                }
            }

            // 5. 复制
            PillBarButton(
                icon: copiedFeedback ? "checkmark" : "doc.on.doc",
                title: copiedFeedback ? "已复制" : "复制",
                tintColor: copiedFeedback ? Color(red: 0.08, green: 0.65, blue: 0.35) : nil
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.inputText, forType: .string)
                copiedFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    copiedFeedback = false
                    onDismiss()
                }
            }

            // 6. 朗读
            PillBarButton(icon: "speaker.wave.2", title: "朗读") {
                SystemDictionaryService.shared.speak(vm.inputText)
            }

            // Divider
            Rectangle()
                .fill(Color.black.opacity(0.10))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)

            // 7. More Menu (...)
            Menu {
                Button("截图翻译 (⌥ + S)") {
                    onTriggerScreenshot()
                }
                Button("打开生词本 (\(VocabularyStore.shared.items.count))") {
                    onOpenVocabWindow()
                }
                Divider()
                Button("偏好设置...") {
                    onOpenSettingsWindow()
                }
                Button("关闭悬浮条 (Esc)") {
                    onDismiss()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.15, green: 0.16, blue: 0.18))
                    .frame(width: 28, height: 32)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.13), radius: 14, x: 0, y: 5)
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 0.8)
        )
        .padding(16) // Space for drop shadow inside transparent NSPanel
    }
}

private struct PillBarButton: View {
    let icon: String
    let title: String
    var tintColor: Color? = nil
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tintColor ?? Color(red: 0.12, green: 0.13, blue: 0.16))
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(tintColor ?? Color(red: 0.12, green: 0.13, blue: 0.16))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? Color.black.opacity(0.055) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
