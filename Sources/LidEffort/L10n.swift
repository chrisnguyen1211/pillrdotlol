import Foundation

/// Visible copy. English source strings are the keys; `Localizable.xcstrings`
/// supplies every other language.
///
/// Looked up in SwiftPM's resource bundle for this module, where the
/// compiled catalog actually is — `LidEffort_LidEffort.bundle` inside the
/// app's Resources. The bundle holding the *code* is the app itself (or the
/// test binary), which has no `.lproj` of its own: looking there found
/// nothing, and every language quietly read as English.
enum L10n {
    static var bundle: Bundle { Bundle.module }

    /// Posted after `apply` so windows can rebuild copy. A notification
    /// rather than an observable object because `t` is called off the main
    /// actor from providers.
    static let didChange = Notification.Name("L10nDidChange")

    /// Persistence key for the in-app override. Not `AppleLanguages` — that
    /// would rewrite AppKit chrome too.
    static let languageDefaultsKey = "appLanguage"

    /// Where the override is kept. Injectable because the unit tests run
    /// inside the app as their host, so `.standard` here is the *shipping
    /// app's* preferences: without this, choosing 简体中文 in Settings would
    /// turn every copy assertion in the suite Chinese, and a test that stored
    /// a language would leave it behind in the real app.
    static var defaults: UserDefaults = .standard

    /// Tests set this to force a locale; nil means production rules.
    static var testLocale: Locale?

    static var locale: Locale {
        if let testLocale { return testLocale }

        let stored = defaults.string(forKey: languageDefaultsKey)
        let isTest = NSClassFromString("XCTestCase") != nil

        // Under XCTest the host *is* the app, so the production store here is
        // the preferences of the installed copy of spyx. Choosing 简体中文
        // in Settings would otherwise decide what a hundred copy assertions
        // compare against — which it did, twice, mid-session. A test that
        // means to exercise the override injects its own store and is
        // answered by the rules below.
        if isTest, defaults == .standard { return Locale(identifier: "en") }

        // Existing assertions stay English on a Chinese Mac. A stored
        // override still wins so a test can pin zh-Hans without testLocale.
        if isTest, stored == nil || stored == AppLanguage.system.rawValue {
            return Locale(identifier: "en")
        }

        if let stored,
           let language = AppLanguage(rawValue: stored),
           let locale = language.locale {
            return locale
        }
        return .current
    }

    static func t(_ key: String.LocalizationValue, locale: Locale = locale) -> String {
        // `String(localized:locale:)` only formats interpolated numbers; it
        // still looks the string up in the bundle's preferred language. The
        // resource carries the locale into the lookup, which is what the
        // XCTest pin needs on a Chinese Mac.
        String(localized: LocalizedStringResource(
            key, locale: locale, bundle: .atURL(bundle.bundleURL)
        ))
    }

    static func apply(_ language: AppLanguage) {
        // Absence, not the string "system": the XCTest English pin treats a
        // missing key as follow-the-Mac.
        if language == .system {
            defaults.removeObject(forKey: languageDefaultsKey)
        } else {
            defaults.set(language.rawValue, forKey: languageDefaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
