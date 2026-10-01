import XCTest
@testable import LidEffort

/// Strings added with spyx's own features — the lid, approvals, Settings —
/// are translated, and are looked up under the same keys the code asks for:
/// with interpolations, and with a literal percent sign written as `%%`.
final class LocalizationCoverageTests: XCTestCase {
    private let languages = ["fr", "ja", "pt-BR", "ru", "zh-Hans"]

    func testNewStringsAreTranslatedEverywhere() {
        for code in languages {
            let locale = Locale(identifier: code)
            XCTAssertNotEqual(L10n.t("Crash reports", locale: locale), "Crash reports", code)
            XCTAssertNotEqual(L10n.t("Hold ⌘ to change effort", locale: locale), "Hold ⌘ to change effort", code)
            XCTAssertNotEqual(L10n.t("Switch to dark mode", locale: locale), "Switch to dark mode", code)
            XCTAssertNotEqual(L10n.t("No session in view · applies next session", locale: locale),
                              "No session in view · applies next session", code)
        }
    }

    func testInterpolatedAndPercentKeysMatch() {
        let locale = Locale(identifier: "fr")
        let version = "1.2.0"
        let available = L10n.t("Version \(version) is available.", locale: locale)
        XCTAssertNotEqual(available, "Version 1.2.0 is available.")
        XCTAssertTrue(available.contains("1.2.0"), available)
        // A literal % beside an interpolation is `%%` in the key.
        let reading = L10n.t("Context \(42)%", locale: locale)
        XCTAssertTrue(reading.contains("42"), reading)
        XCTAssertFalse(reading.contains("%%"), reading)
        XCTAssertNotEqual(L10n.t("At 80% and 100%", locale: locale), "At 80% and 100%")
    }
}
