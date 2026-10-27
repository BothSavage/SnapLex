import AppKit

/// Copies only in response to a verified selection gesture in a supported app.
/// A private pasteboard can be injected for tests; production uses .general.
@MainActor
enum SelectionClipboardCapture {
    static func readSelection(
        from pasteboard: NSPasteboard,
        maximumSnapshotBytes: Int = 32 * 1024 * 1024,
        canContinue: () -> Bool,
        sendCopy: () -> Void,
        waitForPasteboard: () async -> Void = { try? await Task.sleep(nanoseconds: 25_000_000) }
    ) async -> String? {
        guard canContinue(), !Task.isCancelled else { return nil }
        let initialChangeCount = pasteboard.changeCount
        guard let original = snapshot(pasteboard, maximumBytes: maximumSnapshotBytes),
              pasteboard.changeCount == initialChangeCount, canContinue() else { return nil }

        var observedCopyChangeCount: Int?
        defer {
            // Never overwrite a newer user/app clipboard write. Reconstruct
            // every original item/type, including images and file references.
            if let observedCopyChangeCount, pasteboard.changeCount == observedCopyChangeCount {
                restore(original, to: pasteboard)
            }
        }
        sendCopy()
        for _ in 0..<12 {
            await waitForPasteboard()
            guard canContinue(), !Task.isCancelled else { return nil }
            let changeCount = pasteboard.changeCount
            guard changeCount != initialChangeCount else { continue }
            // A clear-then-write copy commonly advances the count twice. A
            // larger jump can include another writer; leave its data alone.
            guard (1...2).contains(changeCount - initialChangeCount) else { return nil }
            observedCopyChangeCount = changeCount
            guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            guard pasteboard.changeCount == changeCount, canContinue(), !Task.isCancelled,
                  SelectionTriggerPolicy.isValidSelectedText(text) else { return nil }
            return text
        }
        return nil
    }

    private typealias Item = [(NSPasteboard.PasteboardType, Data)]

    private static func snapshot(_ pasteboard: NSPasteboard, maximumBytes: Int) -> [Item]? {
        var bytes = 0
        var items: [Item] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: Item = []
            for type in item.types {
                guard let data = item.data(forType: type), data.count <= maximumBytes - bytes else { return nil }
                bytes += data.count
                representations.append((type, data))
            }
            items.append(representations)
        }
        return items
    }

    private static func restore(_ snapshot: [Item], to pasteboard: NSPasteboard) {
        let items = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
