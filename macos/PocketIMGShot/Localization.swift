import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    fileprivate var resolvedIdentifier: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        case .simplifiedChinese, .english:
            return rawValue
        }
    }

    func displayName(in language: AppLanguage) -> String {
        switch self {
        case .system:
            return L10n.text("language.system", language: language)
        case .simplifiedChinese:
            return L10n.text("language.simplified_chinese", language: language)
        case .english:
            return L10n.text("language.english", language: language)
        }
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    static func format(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: text(key, language: language),
            locale: Locale(identifier: language.resolvedIdentifier),
            arguments: arguments
        )
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.main.path(
            forResource: language.resolvedIdentifier,
            ofType: "lproj"
        ), let localized = Bundle(path: path) else {
            return .main
        }
        return localized
    }
}

protocol AppLocalizedError: Error {
    func localizedMessage(language: AppLanguage) -> String
}
