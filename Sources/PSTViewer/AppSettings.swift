import AppKit
import PSTKit
import SwiftUI

enum LanguageSetting: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case dutch = "nl"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("System default", "Systeemstandaard")
        // Language names are shown in their own language, as in System Settings.
        case .english: return "English"
        case .dutch: return "Nederlands"
        }
    }
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("System default", "Systeemstandaard")
        case .light: return tr("Light", "Licht")
        case .dark: return tr("Dark", "Donker")
        }
    }
}

enum AppSettings {
    static let languageKey = "language"
    static let appearanceKey = "appearance"
    static let darkMessagesKey = "darkMessages"

    static var language: LanguageSetting {
        LanguageSetting(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system
    }

    static var appearance: AppearanceSetting {
        AppearanceSetting(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }

    /// The user's languages from System Settings, ignoring this app's own `AppleLanguages` override.
    static var systemLanguages: [String] {
        if let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String],
           !global.isEmpty {
            return global
        }
        return Locale.preferredLanguages
    }

    /// "System default" follows the system language when the app has it, and falls back to English.
    static func resolve(_ setting: LanguageSetting) -> AppLanguage {
        switch setting {
        case .system: return AppLanguage.best(for: systemLanguages)
        case .english: return .english
        case .dutch: return .dutch
        }
    }

    /// Switches the app's own texts immediately. Menu items provided by macOS itself
    /// (Edit, Window, …) follow `AppleLanguages`, which takes effect at the next launch.
    static func applyLanguage(_ setting: LanguageSetting) {
        Localization.current = resolve(setting)
        if setting == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([setting.rawValue], forKey: "AppleLanguages")
        }
    }

    @MainActor
    static func applyAppearance(_ setting: AppearanceSetting) {
        switch setting {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Rebuilds a window's content when the language changes, so every `tr()` call is re-evaluated.
struct LocalizedRoot: ViewModifier {
    @AppStorage(AppSettings.languageKey) private var language = LanguageSetting.system.rawValue

    func body(content: Content) -> some View {
        content
            .id(language)
            .environment(\.locale, Localization.locale)
    }
}

extension View {
    func localizedRoot() -> some View { modifier(LocalizedRoot()) }
}
