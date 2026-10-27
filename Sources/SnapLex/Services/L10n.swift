import Foundation

private final class LocalizationBundleAnchor: NSObject {}

public enum L10n {
    private struct Catalog: Decodable {
        let defaultLanguage: String
        let translations: [String: [String: String]]
    }

    private static let catalogResult: (catalog: Catalog, loaded: Bool) = {
        let mainBundle = Bundle.main
        let roots: [URL]
        if mainBundle.bundleURL.pathExtension.lowercased() == "app" {
            // A packaged app must use its own sealed resources, never a build-machine path.
            roots = [mainBundle.resourceURL].compactMap { $0 }
        } else {
            // SwiftPM executables and XCTest bundles keep resources next to the build product.
            let moduleBundle = Bundle(for: LocalizationBundleAnchor.self)
            roots = [
                mainBundle.resourceURL,
                mainBundle.bundleURL,
                mainBundle.bundleURL.deletingLastPathComponent(),
                mainBundle.executableURL?.deletingLastPathComponent(),
                moduleBundle.resourceURL,
                moduleBundle.bundleURL,
                moduleBundle.bundleURL.deletingLastPathComponent()
            ].compactMap { $0 }
        }

        guard let url = catalogURL(in: roots),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return (Catalog(defaultLanguage: "zh-Hans", translations: [:]), false)
        }
        return (decoded, true)
    }()

    private static var catalog: Catalog { catalogResult.catalog }
    static var hasLoadedCatalog: Bool { catalogResult.loaded }

    static func catalogURL(in resourceRoots: [URL]) -> URL? {
        for root in resourceRoots {
            let bundleURL = root.appendingPathComponent("SnapLex_SnapLex.bundle", isDirectory: true)
            if let url = Bundle(url: bundleURL)?.url(forResource: "i18n", withExtension: "json") {
                return url
            }
        }
        return nil
    }

    public static var language: String {
        let configured = UserDefaults.standard.string(forKey: "SnapLex.appLanguage")
        return configured ?? catalog.defaultLanguage
    }

    public static var locale: Locale {
        Locale(identifier: language)
    }

    public static func formattedDate(
        _ date: Date,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .short
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    static var defaultLanguage: String { catalog.defaultLanguage }
    static var supportedLanguages: Set<String> { Set(catalog.translations.keys) }

    static func catalogKeys(in language: String) -> Set<String> {
        Set(catalog.translations[language]?.keys ?? Dictionary<String, String>().keys)
    }

    public static func string(_ source: String) -> String {
        localizedString(source, language: language)
    }

    static func localizedString(_ source: String, language: String) -> String {
        catalog.translations[language]?[source]
            ?? catalog.translations[catalog.defaultLanguage]?[source]
            ?? source
    }

    public static func format(_ sourceTemplate: String, _ arguments: CVarArg...) -> String {
        String(format: string(sourceTemplate), locale: Locale(identifier: language), arguments: arguments)
    }
}
