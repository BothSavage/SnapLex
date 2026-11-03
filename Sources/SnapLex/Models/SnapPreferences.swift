import Foundation

/// Capture, pin, save, and update preferences edited from Settings.
public struct SnapPreferences: Codable, Equatable {
    public var borderWidth: Double
    public var maskRed: Double
    public var maskGreen: Double
    public var maskBlue: Double
    public var maskAlpha: Double
    public var showAnchors: Bool
    public var anchorBorderRed: Double
    public var anchorBorderGreen: Double
    public var anchorBorderBlue: Double
    public var anchorBorderAlpha: Double
    public var magnifierShowsMask: Bool
    public var magnifierShowsBorder: Bool
    public var magnifierShowsAnchors: Bool
    public var showCrossLines: Bool
    public var showKeyTips: Bool
    public var pinShadow: Bool
    public var pinOpacityPercent: Int
    public var pinMaxSide: Int
    public var thumbnailSize: Int
    public var fileNamePattern: String
    public var quickSaveDirectory: String
    public var quickSaveNotification: Bool
    public var autoSaveEnabled: Bool
    public var autoSaveDirectory: String
    public var checkUpdatesOnStartup: Bool
    public var updateDelaySeconds: Int
    public var updateIntervalHours: Int
    public var periodicUpdatesEnabled: Bool

    public static let defaultPattern = "SnapLex_$yyyy-MM-dd_HH-mm-ss$.png"

    public static var standard: SnapPreferences {
        SnapPreferences(
            borderWidth: 2,
            maskRed: 0, maskGreen: 0, maskBlue: 0, maskAlpha: 0.45,
            showAnchors: true,
            anchorBorderRed: 1, anchorBorderGreen: 1, anchorBorderBlue: 1, anchorBorderAlpha: 1,
            magnifierShowsMask: true,
            magnifierShowsBorder: true,
            magnifierShowsAnchors: false,
            showCrossLines: false,
            showKeyTips: true,
            pinShadow: true,
            pinOpacityPercent: 100,
            pinMaxSide: 12000,
            thumbnailSize: 50,
            fileNamePattern: defaultPattern,
            quickSaveDirectory: "",
            quickSaveNotification: true,
            autoSaveEnabled: false,
            autoSaveDirectory: "",
            checkUpdatesOnStartup: true,
            updateDelaySeconds: 60,
            updateIntervalHours: 24,
            periodicUpdatesEnabled: true
        )
    }

    public func sanitized() -> SnapPreferences {
        var copy = self
        copy.borderWidth = min(12, max(1, borderWidth))
        copy.maskRed = Self.unit(maskRed)
        copy.maskGreen = Self.unit(maskGreen)
        copy.maskBlue = Self.unit(maskBlue)
        copy.maskAlpha = Self.unit(maskAlpha)
        copy.anchorBorderRed = Self.unit(anchorBorderRed)
        copy.anchorBorderGreen = Self.unit(anchorBorderGreen)
        copy.anchorBorderBlue = Self.unit(anchorBorderBlue)
        copy.anchorBorderAlpha = Self.unit(anchorBorderAlpha)
        copy.pinOpacityPercent = min(100, max(15, pinOpacityPercent))
        copy.pinMaxSide = min(20000, max(200, pinMaxSide))
        copy.thumbnailSize = min(240, max(24, thumbnailSize))
        copy.updateDelaySeconds = min(3600, max(0, updateDelaySeconds))
        copy.updateIntervalHours = min(24 * 30, max(1, updateIntervalHours))
        let pattern = fileNamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.fileNamePattern = pattern.isEmpty ? Self.defaultPattern : pattern
        return copy
    }

    public static func fileName(pattern: String, at date: Date) -> String {
        let source = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = source.isEmpty ? defaultPattern : source
        var result = ""
        var index = tokens.startIndex
        while let open = tokens[index...].firstIndex(of: "$") {
            result += tokens[index..<open]
            let after = tokens.index(after: open)
            guard after < tokens.endIndex, let close = tokens[after...].firstIndex(of: "$"), close > after else {
                result += tokens[open...]
                return sanitizeFileName(result)
            }
            let format = String(tokens[after..<close])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            result += formatter.string(from: date)
            index = tokens.index(after: close)
        }
        result += tokens[index...]
        return sanitizeFileName(result)
    }

    public func quickSaveDirectoryURL() -> URL {
        Self.directoryURL(stored: quickSaveDirectory, fallback: .desktopDirectory)
    }

    public func autoSaveDirectoryURL() -> URL {
        Self.directoryURL(stored: autoSaveDirectory, fallback: .picturesDirectory)
    }

    public func uniqueFileURL(
        in directory: URL,
        at date: Date,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let name = Self.fileName(pattern: fileNamePattern, at: date)
        let base = directory.appendingPathComponent(name)
        if !fileExists(base.path) { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index)").appendingPathExtension(ext)
            if !fileExists(candidate.path) { return candidate }
            index += 1
        }
    }

    private static func directoryURL(stored: String, fallback: FileManager.SearchPathDirectory) -> URL {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return FileManager.default.urls(for: fallback, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "SnapLex.png" }
        return (cleaned as NSString).pathExtension.isEmpty ? cleaned + ".png" : cleaned
    }

    /// Missing keys keep the current defaults, so older saved settings are not reset.
    static func stored(in defaults: UserDefaults, key: String = "SnapLex.capturePreferences") -> SnapPreferences {
        guard let data = defaults.data(forKey: key) else { return .standard }
        guard let standardData = try? JSONEncoder().encode(SnapPreferences.standard),
              var base = try? JSONSerialization.jsonObject(with: standardData) as? [String: Any],
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .standard
        }
        for (name, value) in saved where base.keys.contains(name) {
            base[name] = value
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              let decoded = try? JSONDecoder().decode(SnapPreferences.self, from: merged) else {
            return .standard
        }
        return decoded.sanitized()
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
