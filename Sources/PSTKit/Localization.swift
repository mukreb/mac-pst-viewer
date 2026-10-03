import Foundation

/// The languages the app and its user-visible library strings are available in.
public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case dutch = "nl"

    /// Picks the first supported language from a list of preferred language codes
    /// (e.g. `Locale.preferredLanguages`); falls back to English.
    public static func best(for preferred: [String]) -> AppLanguage {
        for code in preferred {
            let base = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if let lang = AppLanguage(rawValue: base) { return lang }
        }
        return .english
    }

    /// This language combined with the user's region, so dates keep the region's conventions
    /// (e.g. English with day-month order for a user in the Netherlands).
    public var locale: Locale {
        let id = Locale.current.identifier.split(separator: "@").first ?? ""
        let region = id.split(separator: "_").dropFirst().last.map(String.init)
        return Locale(identifier: region.map { "\(rawValue)_\($0)" } ?? rawValue)
    }
}

public enum Localization {
    private static let lock = NSLock()
    private static var _current: AppLanguage = .english

    /// The language used by `tr(_:_:)`. Set by the app at launch and when the user changes it.
    public static var current: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }

    /// Locale matching the current language, for date formatting.
    public static var locale: Locale { current.locale }
}

/// Returns the English or Dutch text, depending on `Localization.current`.
/// Both translations live side by side at the call site, so interpolated strings stay readable.
public func tr(_ english: String, _ dutch: String) -> String {
    Localization.current == .dutch ? dutch : english
}
