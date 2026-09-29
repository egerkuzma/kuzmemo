import Foundation

/// A language the interface and the spoken output can use.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case russian = "ru"

    public var locale: Locale { Locale(identifier: rawValue) }

    /// The language's own name, as shown in a language picker.
    public var nativeName: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }

    /// The first supported language among the person's preferred languages (English when none is).
    public static func best(for preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferred {
            let code = identifier.lowercased().prefix(2)
            if let match = AppLanguage(rawValue: String(code)) { return match }
        }
        return .english
    }
}

/// What the person chose in the settings: follow the system or force a language.
public enum LanguagePreference: String, CaseIterable, Codable, Sendable {
    case system, english, russian

    /// The language to use now.
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .system: AppLanguage.best(for: preferred)
        case .english: .english
        case .russian: .russian
        }
    }
}
