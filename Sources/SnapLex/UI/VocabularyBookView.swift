import SwiftUI
import AppKit

public struct VocabularyBookView: View {
    @ObservedObject var store = VocabularyStore.shared
    @ObservedObject var settings = AppSettings.shared

    @State private var searchText: String = ""
    @State private var filterMastery: Int = -1 // -1: All, 0: New, 1: Learning, 2: Mastered
    @State private var sortByFrequency: Bool = false
    @State private var selectedItemID: Int64? = nil
    @State private var exportBannerMessage: String? = nil

    public init() {}

    private var filteredItems: [VocabItem] {
        var list = store.items.filter { item in
            let matchesMastery = (filterMastery == -1) || (item.masteryLevel == filterMastery)
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesQuery = q.isEmpty
                || item.term.lowercased().contains(q)
                || item.aiTranslation.lowercased().contains(q)
                || item.systemDefinition.lowercased().contains(q)
                || item.contextSentence.lowercased().contains(q)
                || item.sourceApp.lowercased().contains(q)
            return matchesMastery && matchesQuery
        }
        if sortByFrequency {
            list.sort {
                if $0.lookupCount != $1.lookupCount {
                    return $0.lookupCount > $1.lookupCount
                }
                return $0.updatedAt > $1.updatedAt
            }
        }
        return list
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                // Search & Filter Bar
                VStack(spacing: 6) {
                    TextField("搜索单词、释义、原句或来源应用...", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 6) {
                        Picker("状态", selection: $filterMastery) {
                            Text("全部 (\(store.items.count))").tag(-1)
                            Text("🆕 新词").tag(0)
                            Text("🔄 熟悉").tag(1)
                            Text("✅ 掌握").tag(2)
                        }
                        .labelsHidden()
                        .controlSize(.small)

                        Toggle("按频次排序", isOn: $sortByFrequency)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)

                Divider()

                if filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "text.book.closed")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("暂无匹配生词")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("划词或截图翻译后点击「加入生词本」即可自动双写至 SQLite 与 Markdown")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                } else {
                    List(filteredItems, selection: $selectedItemID) { item in
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.term)
                                        .font(.system(size: 13.5, weight: .bold))
                                    if !item.phonetic.isEmpty {
                                        Text(item.phonetic)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(summaryLine(for: item))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                HStack(spacing: 2) {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(item.lookupCount >= 3 ? .orange : .secondary)
                                    Text("\(item.lookupCount)次")
                                        .font(.system(size: 10.5, weight: .semibold))
                                }
                                Text(item.sourceApp.isEmpty ? "macOS" : item.sourceApp)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(item.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                // Top Action Header
                HStack(spacing: 10) {
                    Text("双写路径：\(store.markdownFilePath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if let msg = exportBannerMessage {
                        Text(msg)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }

                    Button(action: {
                        store.syncMarkdownFile()
                        NSWorkspace.shared.selectFile(store.markdownFilePath, inFileViewerRootedAtPath: settings.markdownExportDir)
                    }) {
                        Label("定位 Vocabulary.md", systemImage: "folder")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        store.syncMarkdownFile()
                        NSWorkspace.shared.open(URL(fileURLWithPath: store.markdownFilePath))
                    }) {
                        Label("打开 Markdown", systemImage: "doc.text")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        let path = store.exportAnkiTSV()
                        exportBannerMessage = "✓ 已导出 Anki TSV"
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: settings.markdownExportDir)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            exportBannerMessage = nil
                        }
                    }) {
                        Label("导出 Anki 闪卡 (.tsv)", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                if let selectedID = selectedItemID,
                   let item = store.items.first(where: { $0.id == selectedID }) {
                    vocabDetailView(item: item)
                } else if let first = filteredItems.first {
                    vocabDetailView(item: first)
                } else {
                    Spacer()
                    Text("从左侧列表选择一个词条查看详细语境与释义")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 780, minHeight: 500)
    }

    @ViewBuilder
    private func vocabDetailView(item: VocabItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.term)
                        .font(.system(size: 26, weight: .bold))
                        .textSelection(.enabled)

                    if !item.phonetic.isEmpty {
                        Text(item.phonetic)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(.blue)
                    }

                    Button(action: {
                        SystemDictionaryService.shared.speak(item.term)
                    }) {
                        Image(systemName: "speaker.wave.2.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Picker("熟练度", selection: Binding(
                        get: { item.masteryLevel },
                        set: { store.updateMastery(id: item.id, level: $0) }
                    )) {
                        Text("🆕 新词").tag(0)
                        Text("🔄 熟悉中").tag(1)
                        Text("✅ 已掌握").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)

                    Button(role: .destructive, action: {
                        store.deleteItem(id: item.id)
                    }) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("删除词条")
                }

                HStack(spacing: 12) {
                    Label("累计遇到 \(item.lookupCount) 次", systemImage: "flame.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                    Label("来源：\(item.sourceApp.isEmpty ? "macOS" : item.sourceApp)", systemImage: "app.badge")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if !item.contextSentence.isEmpty && item.contextSentence != item.term {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("📌 捕获时的原句语境")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(item.contextSentence)
                            .font(.system(size: 13.5))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                }

                if let shotRel = item.screenshotFilename {
                    let fullShotPath = (settings.markdownExportDir as NSString).appendingPathComponent(shotRel)
                    if let nsImg = NSImage(contentsOfFile: fullShotPath) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("🖼️ 截图快照")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Image(nsImage: nsImg)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !item.aiTranslation.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("🤖 AI 语境精释")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(item.aiTranslation)
                            .font(.system(size: 13.5))
                            .lineSpacing(4)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                }

                if !item.systemDefinition.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("⚡ macOS 系统原生词典")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(item.systemDefinition)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(18)
        }
    }

    private func summaryLine(for item: VocabItem) -> String {
        let firstAI = item.aiTranslation
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let firstAI = firstAI, !firstAI.isEmpty {
            return firstAI
        }
        return item.systemDefinition.components(separatedBy: .newlines).first ?? ""
    }
}
