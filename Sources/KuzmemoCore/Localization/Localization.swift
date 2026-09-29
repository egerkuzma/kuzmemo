import Foundation
import Synchronization

/// The language of everything the app says or shows, and the lookup of translated text.
///
/// Source text is English: `tr("Open")` returns the Russian translation from `ru.lproj/Localizable.strings` when the
/// language is Russian, and the key itself when a table has no entry (which is how English works). The language is
/// set once at launch from the settings and again when the person changes it; tests pin one for a scope with `with(_:)`.
public enum Localization {
    private static let stored = Mutex<AppLanguage>(.russian)

    /// A language pinned for the current task and the tasks it starts (used by tests and by code that must produce a
    /// particular language regardless of the interface).
    @TaskLocal private static var pinned: AppLanguage?

    /// The language in use. Until the app sets one it is Russian, the language the text logic was first written for.
    public static var current: AppLanguage { pinned ?? stored.withLock { $0 } }

    /// Sets the interface language for the whole app.
    public static func set(_ language: AppLanguage) {
        stored.withLock { $0 = language }
    }

    /// Runs `body` with `language` in force for it and for the tasks it starts.
    public static func with<T>(_ language: AppLanguage, _ body: () throws -> T) rethrows -> T {
        try $pinned.withValue(language, operation: body)
    }

    /// The async form of `with(_:_:)`.
    public static func with<T>(_ language: AppLanguage, _ body: nonisolated(nonsending) () async throws -> T) async rethrows -> T {
        try await $pinned.withValue(language, operation: body)
    }

    // MARK: - Lookup

    private static let bundles = Mutex<[AppLanguage: Bundle]>([:])

    static func bundle(for language: AppLanguage) -> Bundle {
        bundles.withLock { cache in
            if let cached = cache[language] { return cached }
            let base = resourceBundle()
            let found = base.path(forResource: language.rawValue, ofType: "lproj").flatMap { Bundle(path: $0) } ?? base
            cache[language] = found
            return found
        }
    }

    /// The bundle with the translation tables. A packaged app keeps SwiftPM's resource bundle in `Contents/Resources`,
    /// where the generated `Bundle.module` accessor does not look (it tries the folder of the app and the build folder,
    /// which only works on the machine that built it), so that place is tried first.
    private static func resourceBundle() -> Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Kuzmemo_KuzmemoCore.bundle"), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }

    /// The translation of `key` in `language`; the key itself when there is none.
    public static func text(_ key: String, in language: AppLanguage) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: nil)
    }

    /// Plural category of `count` in `language` (Russian has "one", "few" and "many"; English "one" and "other").
    static func pluralCategory(_ count: Int, in language: AppLanguage) -> String {
        let n = abs(count)
        switch language {
        case .english:
            return n == 1 ? "one" : "other"
        case .russian:
            if n % 10 == 1, n % 100 != 11 { return "one" }
            if (2 ... 4).contains(n % 10), !(12 ... 14).contains(n % 100) { return "few" }
            return "many"
        }
    }
}

/// The text for `key` in the current language, with the placeholders `%1$@`, `%2$@` … filled from `arguments`.
public func tr(_ key: String, _ arguments: String...) -> String {
    let language = Localization.current
    let format = Localization.text(key, in: language)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: language.locale, arguments: arguments.map { $0 as any CVarArg })
}

/// The same for placeholders that hold whole numbers (`%1$lld`, `%2$lld` …). At least one number is required, which is
/// what keeps a plain call with only a key from being ambiguous between the two forms.
public func tr(_ key: String, numbers first: Int, _ more: Int...) -> String {
    let language = Localization.current
    let format = Localization.text(key, in: language)
    return String(format: format, locale: language.locale, arguments: ([first] + more).map { $0 as any CVarArg })
}

/// A counted phrase in the right plural form: `trCount("%lld minutes", 5)` looks up `"%lld minutes|many"` in Russian and
/// `"%lld minutes|other"` in English (`|one`, `|few`, `|many` and `|other` are the table keys) and fills in the count.
public func trCount(_ key: String, _ count: Int) -> String {
    let language = Localization.current
    let category = Localization.pluralCategory(count, in: language)
    let table = Localization.bundle(for: language)
    for candidate in ["\(key)|\(category)", "\(key)|other", key] {
        let text = table.localizedString(forKey: candidate, value: nil, table: nil)
        if text != candidate || candidate == key {
            return String(format: text, locale: language.locale, count)
        }
    }
    return String(format: key, locale: language.locale, count)
}
