import Foundation
import SQLite3
import AppKit

@MainActor
public final class VocabularyStore: ObservableObject {
    public static let shared = VocabularyStore()

    @Published public private(set) var items: [VocabItem] = []

    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public var dbPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLex", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("vocab.sqlite3").path
    }

    private init() {
        openDatabase()
        createTableIfNeeded()
        reloadItems()
        syncMarkdownFile()
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[SnapLex] Failed to open SQLite database at \(dbPath)")
        }
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS vocabulary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL UNIQUE COLLATE NOCASE,
            phonetic TEXT DEFAULT '',
            ai_translation TEXT DEFAULT '',
            system_definition TEXT DEFAULT '',
            context_sentence TEXT DEFAULT '',
            source_app TEXT DEFAULT '',
            screenshot_filename TEXT,
            lookup_count INTEGER DEFAULT 1,
            mastery_level INTEGER DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_vocab_term ON vocabulary(term COLLATE NOCASE);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("[SnapLex] SQLite table creation error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    public func reloadItems() {
        let sql = """
        SELECT id, term, phonetic, ai_translation, system_definition, context_sentence,
               source_app, screenshot_filename, lookup_count, mastery_level, created_at, updated_at
        FROM vocabulary
        ORDER BY updated_at DESC;
        """
        var stmt: OpaquePointer?
        var loaded: [VocabItem] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let term = columnString(stmt, 1)
                let phonetic = columnString(stmt, 2)
                let aiTrans = columnString(stmt, 3)
                let sysDef = columnString(stmt, 4)
                let context = columnString(stmt, 5)
                let sourceApp = columnString(stmt, 6)
                let screenshot = columnOptionalString(stmt, 7)
                let lookupCount = Int(sqlite3_column_int(stmt, 8))
                let masteryLevel = Int(sqlite3_column_int(stmt, 9))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))

                loaded.append(
                    VocabItem(
                        id: id,
                        term: term,
                        phonetic: phonetic,
                        aiTranslation: aiTrans,
                        systemDefinition: sysDef,
                        contextSentence: context,
                        sourceApp: sourceApp,
                        screenshotFilename: screenshot,
                        lookupCount: lookupCount,
                        masteryLevel: masteryLevel,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        self.items = loaded
    }

    public func findExisting(term: String) -> VocabItem? {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return items.first { $0.term.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    @discardableResult
    public func saveOrUpdate(
        term: String,
        phonetic: String,
        aiTranslation: String,
        systemDefinition: String,
        contextSentence: String,
        sourceApp: String,
        screenshotImage: NSImage? = nil
    ) -> VocabItem? {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return nil }

        var savedScreenshotName: String? = nil
        if let image = screenshotImage {
            savedScreenshotName = saveScreenshotAsset(image: image, term: cleanTerm)
        }

        let now = Date().timeIntervalSince1970

        if let existing = findExisting(term: cleanTerm) {
            let newCount = existing.lookupCount + 1
            let mergedPhonetic = phonetic.isEmpty ? existing.phonetic : phonetic
            let mergedAI = aiTranslation.isEmpty ? existing.aiTranslation : aiTranslation
            let mergedSys = systemDefinition.isEmpty ? existing.systemDefinition : systemDefinition
            let mergedContext = contextSentence.isEmpty ? existing.contextSentence : contextSentence
            let mergedSource = sourceApp.isEmpty ? existing.sourceApp : sourceApp
            let mergedShot = savedScreenshotName ?? existing.screenshotFilename

            let updateSQL = """
            UPDATE vocabulary
            SET phonetic = ?, ai_translation = ?, system_definition = ?, context_sentence = ?,
                source_app = ?, screenshot_filename = ?, lookup_count = ?, updated_at = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, mergedPhonetic, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, mergedAI, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, mergedSys, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, mergedContext, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, mergedSource, -1, SQLITE_TRANSIENT)
                if let mergedShot = mergedShot {
                    sqlite3_bind_text(stmt, 6, mergedShot, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_int(stmt, 7, Int32(newCount))
                sqlite3_bind_double(stmt, 8, now)
                sqlite3_bind_int64(stmt, 9, existing.id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        } else {
            let insertSQL = """
            INSERT INTO vocabulary (
                term, phonetic, ai_translation, system_definition, context_sentence,
                source_app, screenshot_filename, lookup_count, mastery_level, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, cleanTerm, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, phonetic, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, aiTranslation, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, systemDefinition, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, contextSentence, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, sourceApp, -1, SQLITE_TRANSIENT)
                if let savedScreenshotName = savedScreenshotName {
                    sqlite3_bind_text(stmt, 7, savedScreenshotName, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                sqlite3_bind_double(stmt, 8, now)
                sqlite3_bind_double(stmt, 9, now)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        reloadItems()
        syncMarkdownFile()
        return findExisting(term: cleanTerm)
    }

    public func incrementLookupIfExists(term: String) -> VocabItem? {
        guard let existing = findExisting(term: term) else { return nil }
        let sql = "UPDATE vocabulary SET lookup_count = lookup_count + 1, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, existing.id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        reloadItems()
        syncMarkdownFile()
        return findExisting(term: term)
    }

    public func updateMastery(id: Int64, level: Int) {
        let sql = "UPDATE vocabulary SET mastery_level = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(level))
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        reloadItems()
        syncMarkdownFile()
    }

    public func deleteItem(id: Int64) {
        let sql = "DELETE FROM vocabulary WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        reloadItems()
        syncMarkdownFile()
    }

    // MARK: - Markdown Dual-Write & Anki Export

    public var markdownFilePath: String {
        let dir = AppSettings.shared.markdownExportDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("Vocabulary.md")
    }

    private func saveScreenshotAsset(image: NSImage, term: String) -> String? {
        let dir = AppSettings.shared.markdownExportDir
        let assetsDir = (dir as NSString).appendingPathComponent("assets")
        try? FileManager.default.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)

        let safeTerm = term.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression).prefix(24)
        let filename = "\(Int(Date().timeIntervalSince1970))_\(safeTerm).png"
        let fullPath = (assetsDir as NSString).appendingPathComponent(filename)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        do {
            try pngData.write(to: URL(fileURLWithPath: fullPath))
            return "assets/\(filename)"
        } catch {
            return nil
        }
    }

    public func syncMarkdownFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var md = """
        ---
        title: SnapLex 生词本 (SQLite + Markdown 实时双写)
        updated: \(formatter.string(from: Date()))
        total_words: \(items.count)
        ---

        # 📚 SnapLex 语境生词本

        > 本文件由 **SnapLex** 与本地 SQLite (`\(dbPath)`) 自动双向同步，可直接放入 Obsidian 知识库检阅。

        | 词条 / 术语 | 音标 | 核心释义 | 来源应用 | 查词次数 | 状态 | 更新时间 |
        | :--- | :--- | :--- | :--- | :---: | :---: | :--- |
        """

        for item in items {
            let statusBadge: String
            switch item.masteryLevel {
            case 2: statusBadge = "✅ 已掌握"
            case 1: statusBadge = "🔄 熟悉中"
            default: statusBadge = "🆕 新收录"
            }
            let oneLineTrans = item.aiTranslation
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(2)
                .joined(separator: " ； ")
                .replacingOccurrences(of: "|", with: "\\|")
            let fallbackTrans = oneLineTrans.isEmpty
                ? item.systemDefinition.components(separatedBy: .newlines).first?.replacingOccurrences(of: "|", with: "\\|") ?? ""
                : oneLineTrans

            md += "\n| **\(item.term.replacingOccurrences(of: "|", with: "\\|"))** | \(item.phonetic) | \(fallbackTrans.prefix(90)) | `\(item.sourceApp.isEmpty ? "macOS" : item.sourceApp)` | \(item.lookupCount) | \(statusBadge) | \(formatter.string(from: item.updatedAt)) |"
        }

        md += "\n\n---\n\n## 🗂️ 详细语境卡片\n\n"

        for item in items {
            md += "### \(item.term)"
            if !item.phonetic.isEmpty {
                md += " `\(item.phonetic)`"
            }
            md += "\n"
            md += "- **累计遇到**：\(item.lookupCount) 次 | **来源**：`\(item.sourceApp.isEmpty ? "macOS" : item.sourceApp)` | **收录时间**：\(formatter.string(from: item.createdAt))\n"
            if !item.contextSentence.isEmpty && item.contextSentence != item.term {
                let cleanCtx = item.contextSentence.replacingOccurrences(of: "\n", with: " ")
                md += "- **原句语境**：\n  > \(cleanCtx)\n"
            }
            if !item.aiTranslation.isEmpty {
                let indented = item.aiTranslation
                    .components(separatedBy: .newlines)
                    .map { "  " + $0 }
                    .joined(separator: "\n")
                md += "- **AI 精解**：\n\(indented)\n"
            }
            if !item.systemDefinition.isEmpty {
                let briefSys = item.systemDefinition
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .prefix(4)
                    .joined(separator: " / ")
                md += "- **系统词典**：\(briefSys)\n"
            }
            if let shot = item.screenshotFilename {
                md += "- **截图快照**：\n  ![\(item.term)](\(shot))\n"
            }
            md += "\n"
        }

        try? md.write(toFile: markdownFilePath, atomically: true, encoding: .utf8)
    }

    public func exportAnkiTSV() -> String {
        let dir = AppSettings.shared.markdownExportDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tsvPath = (dir as NSString).appendingPathComponent("SnapLex-Anki.tsv")

        var lines: [String] = []
        for item in items {
            let front = item.term.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "<br>")
            let meaning = (!item.aiTranslation.isEmpty ? item.aiTranslation : item.systemDefinition)
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: "<br>")
            let context = item.contextSentence
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: "<br>")
            let back = "<b>\(item.phonetic)</b><br>\(meaning)<br><hr><i>Context (\(item.sourceApp)):</i> \(context)"
            lines.append("\(front)\t\(back)")
        }

        let content = lines.joined(separator: "\n")
        try? content.write(toFile: tsvPath, atomically: true, encoding: .utf8)
        return tsvPath
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private func columnOptionalString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
}
