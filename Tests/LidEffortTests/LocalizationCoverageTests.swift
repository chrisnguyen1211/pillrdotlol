import XCTest
@testable import LidEffort

/// Strings added with pillr's own features — the lid, approvals, Settings —
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

    // 1.1.1 shipped a whole Settings section, Sign-ins, in English under
    // every language: its strings were never added to the catalog. Every
    // literal `L10n.t("…")` in the app must have all five translations.
    func testEveryLiteralStringHasEveryLanguage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalogURL = root.appendingPathComponent("Sources/LidEffort/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])

        // A literal with no interpolation: its text is the key as written.
        let literal = try NSRegularExpression(pattern: #"L10n\.t\(\s*"((?:[^"\\]|\\.)*)""#)
        let sources = root.appendingPathComponent("Sources/LidEffort")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var missing: [String] = []
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                let raw = String(code[range])
                if raw.contains("\\(") { continue }
                let key = raw.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                checked += 1
                let have = (strings[key]?["localizations"] as? [String: Any]).map { Set($0.keys) } ?? []
                let lacking = languages.filter { !have.contains($0) }
                if !lacking.isEmpty { missing.append("\(file.lastPathComponent): \(key) [\(lacking.joined(separator: ", "))]") }
            }
        }
        XCTAssertGreaterThan(checked, 500, "the scan found the app's strings")
        XCTAssertEqual(Array(Set(missing)).sorted(), [], "add these to Localizable.xcstrings")
    }

    func testTheSignInsSectionReadsInChinese() {
        let chinese = Locale(identifier: "zh-Hans")
        for key: String.LocalizationValue in ["Sign-ins", "Read Claude Code and Antigravity sign-ins without asking",
                                              "Renew Claude's sign-in in the background"] {
            XCTAssertFalse(L10n.t(key, locale: chinese).contains("sign-in"))
        }
        XCTAssertEqual(L10n.t("Sign-ins", locale: chinese), "登录")
    }
}
