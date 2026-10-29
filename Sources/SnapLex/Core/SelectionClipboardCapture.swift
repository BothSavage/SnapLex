import AppKit

/// Copies only in response to a verified selection gesture in a supported app.
/// A private pasteboard can be injected for tests; production uses .general.
@MainActor
enum SelectionClipboardCapture {
    static func readSelection(
        from pasteboard: NSPasteboard,
        maximumSnapshotBytes: Int = 32 * 1024 * 1024,
        maximumSnapshotDuration: TimeInterval = 0.060,
        canContinue: () -> Bool,
        sendCopy: () -> Void,
        waitForPasteboard: () async -> Void = { try? await Task.sleep(nanoseconds: 25_000_000) }
    ) async -> String? {
        guard canContinue(), !Task.isCancelled else { return nil }
        let initialChangeCount = pasteboard.changeCount
        let snapshotDeadline = ProcessInfo.processInfo.systemUptime + max(0, maximumSnapshotDuration)
        guard let original = snapshot(pasteboard, maximumBytes: maximumSnapshotBytes, canContinue: {
            !Task.isCancelled
                && pasteboard.changeCount == initialChangeCount
                && ProcessInfo.processInfo.systemUptime < snapshotDeadline
        }), pasteboard.changeCount == initialChangeCount, canContinue(), !Task.isCancelled else { return nil }

        var observedCopyChangeCount: Int?
        defer {
            // Never overwrite a newer user/app clipboard write. Reconstruct
            // every snapshotted item/type; unsupported payloads skip copying.
            if let observedCopyChangeCount, pasteboard.changeCount == observedCopyChangeCount {
                restore(original, to: pasteboard)
            }
        }
        sendCopy()
        let copyDeadline = ProcessInfo.processInfo.systemUptime + 0.300
        for attempt in 0..<13 {
            // Observe first; fast applications need no mandatory settle delay.
            if attempt > 0 { await waitForPasteboard() }
            let changeCount = pasteboard.changeCount
            if changeCount == initialChangeCount {
                guard canContinue(), !Task.isCancelled,
                      ProcessInfo.processInfo.systemUptime < copyDeadline else { return nil }
                continue
            }
            // A clear-then-write copy commonly advances the count twice. A
            // larger jump can include another writer; leave its data alone.
            guard (1...2).contains(changeCount - initialChangeCount) else { return nil }
            observedCopyChangeCount = changeCount
            guard canContinue(), !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < copyDeadline else { return nil }
            guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            guard pasteboard.changeCount == changeCount, canContinue(), !Task.isCancelled,
                  SelectionTriggerPolicy.isValidSelectedText(text) else { return nil }
            return text
        }
        return nil
    }

    private typealias Item = [(NSPasteboard.PasteboardType, Data)]

    private static func snapshot(
        _ pasteboard: NSPasteboard, maximumBytes: Int, canContinue: () -> Bool
    ) -> [Item]? {
        guard canContinue(), maximumBytes >= 0 else { return nil }
        let sourceItems = pasteboard.pasteboardItems ?? []
        // Avoid asking image/file/promise providers to render expensive data on
        // the main thread. Declining the copy preserves the entire clipboard;
        // never snapshot just a convenient subset of its representations.
        let inexpensiveTypes: Set<NSPasteboard.PasteboardType> = [
            .string, .rtf, .html,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-external-plain-text")
        ]
        guard sourceItems.count <= 16,
              sourceItems.allSatisfy({ item in
                  // Private pasteboards used by callers/tests are under their
                  // control and may contain small custom binary representations.
                  item.types.count <= 16 && (pasteboard.name != .general
                      || item.types.allSatisfy(inexpensiveTypes.contains))
              }) else { return nil }
        var bytes = 0
        var items: [Item] = []
        for item in sourceItems {
            var representations: Item = []
            for type in item.types {
                // AppKit provides no size preflight or cancellation for one
                // synchronous provider call. Bound everything between calls,
                // and abandon before Cmd+C if even one call exceeds the budget.
                guard canContinue(), let data = item.data(forType: type),
                      canContinue(), data.count <= maximumBytes - bytes else { return nil }
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
