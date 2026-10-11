import XCTest
import AppKit
@testable import LidEffort

/// Hold fn in the reply field to speak, by the Mac's own dictation: only the
/// fn key on its own turns it on.
final class SystemDictationTests: XCTestCase {
    func testOnlyFnOnItsOwnStartsListening() {
        let fn = SystemDictation.fnKeyCode
        XCTAssertEqual(SystemDictation.fnChange(keyCode: fn, flags: [.function]), true, "fn down")
        XCTAssertEqual(SystemDictation.fnChange(keyCode: fn, flags: []), false, "fn up")
        XCTAssertEqual(SystemDictation.fnChange(keyCode: fn, flags: [.function, .command]), false, "⌘fn is something else")
        XCTAssertNil(SystemDictation.fnChange(keyCode: 56, flags: [.shift]), "shift is not fn")
        XCTAssertNil(SystemDictation.fnChange(keyCode: 123, flags: [.function, .numericPad]), "an arrow key carries the fn flag but isn't fn")
    }

    func testWhatIsHeardFollowsWhatWasTyped() {
        XCTAssertEqual(SystemDictation.merge(typed: "", heard: "chạy lại test"), "chạy lại test")
        XCTAssertEqual(SystemDictation.merge(typed: "please", heard: "run the tests"), "please run the tests")
        XCTAssertEqual(SystemDictation.merge(typed: "please ", heard: "run the tests"), "please run the tests")
        XCTAssertEqual(SystemDictation.merge(typed: "please", heard: "  "), "please")
    }

    /// The languages and mode set for the keyboard's dictation, in order.
    func testTheKeyboardsDictationLanguagesComeFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dictation-\(UUID().uuidString)"))
        defaults.set(["vi_VN", "zh_CN"], forKey: "DictationIMPreferredLanguageIdentifiers")
        defaults.set(false, forKey: "DictationIMUseOnlyOfflineDictation")
        let settings = SystemDictation.dictationSettings(defaults: defaults, preferred: ["en-US", "vi-VN"])
        XCTAssertEqual(settings.languages.prefix(2), ["vi-VN", "zh-CN"])
        XCTAssertTrue(settings.languages.contains("en-US"), "the Mac's other languages after")
        XCTAssertFalse(settings.offlineOnly, "on Apple's servers, as the keyboard's dictation is set")
        let none = try XCTUnwrap(UserDefaults(suiteName: "dictation-\(UUID().uuidString)"))
        XCTAssertEqual(SystemDictation.dictationSettings(defaults: none, preferred: ["fr-FR"]).languages, ["fr-FR"])
    }
}
