import AppKit
import SwiftUI

public struct ScreenshotHistoryView: View {
    @ObservedObject private var store = ScreenshotHistoryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingClearConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)]

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("截图记录"))
                        .font(.system(size: 21, weight: .semibold))
                    Text(L10n.format("保留最近 %d 张截图 · 当前 %d 张", settings.screenshotHistoryLimit, store.records.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.string("刷新截图记录"))
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(store.records.isEmpty)
                .help(L10n.string("清空截图记录"))
            }

            if store.records.isEmpty {
                ContentUnavailableView(
                    L10n.string("还没有截图记录"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(L10n.string("完成截图、贴图或截图翻译后，图片会自动保存在这里。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.records) { record in
                            ScreenshotHistoryTile(record: record, store: store)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 540)
        .background(SnapLexTheme.toolbarBackground(for: colorScheme))
        .snapLexAppearance()
        .confirmationDialog(
            L10n.string("清空全部截图记录？"),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("清空截图记录"), role: .destructive) { store.deleteAll() }
            Button(L10n.string("取消"), role: .cancel) {}
        }
    }
}

private struct ScreenshotHistoryTile: View {
    let record: ScreenshotHistoryRecord
    @ObservedObject var store: ScreenshotHistoryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 142)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(record.fileURL) }
            .contextMenu {
                Button(L10n.string("打开图片")) { NSWorkspace.shared.open(record.fileURL) }
                Button(L10n.string("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
                }
                Divider()
                Button(L10n.string("删除截图"), role: .destructive) { store.delete(record) }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.formattedDate(record.createdAt))
                        .font(.system(size: 11.5, weight: .medium))
                    Text("\(record.pixelWidth) × \(record.pixelHeight)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(role: .destructive) {
                    store.delete(record)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .help(L10n.string("删除截图"))
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.7)
        )
        .task(id: record.id) {
            image = NSImage(contentsOf: record.fileURL)
        }
    }
}
