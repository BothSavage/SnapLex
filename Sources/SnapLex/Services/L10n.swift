import Foundation

public enum L10n {
    private struct Catalog: Decodable {
        let defaultLanguage: String
        let translations: [String: [String: String]]
    }

    private static let catalog: Catalog = {
        guard let url = Bundle.module.url(forResource: "i18n", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(defaultLanguage: "zh-Hans", translations: [:])
        }
        return decoded
    }()

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
