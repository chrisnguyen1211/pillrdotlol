import XCTest
import AppKit
@testable import LidEffort

/// Hold fn in the reply field to speak: the words join what was typed, and
/// only the fn key on its own starts it.
final class VoiceDictationTests: XCTestCase {
    func testWhatIsHeardFollowsWhatWasTyped() {
        XCTAssertEqual(VoiceDictation.merge(typed: "", heard: "run the tests"), "run the tests")
        XCTAssertEqual(VoiceDictation.merge(typed: "please", heard: "run the tests"), "please run the tests")
        XCTAssertEqual(VoiceDictation.merge(typed: "please ", heard: "run the tests"), "please run the tests")
        XCTAssertEqual(VoiceDictation.merge(typed: "please", heard: "  "), "please", "nothing heard leaves the text alone")
    }

    func testOnlyFnOnItsOwnStartsListening() {
        let fn = VoiceDictation.fnKeyCode
        XCTAssertEqual(VoiceDictation.fnChange(keyCode: fn, flags: [.function]), true, "fn down")
        XCTAssertEqual(VoiceDictation.fnChange(keyCode: fn, flags: []), false, "fn up")
        XCTAssertEqual(VoiceDictation.fnChange(keyCode: fn, flags: [.function, .command]), false, "⌘fn is something else")
        XCTAssertNil(VoiceDictation.fnChange(keyCode: 56, flags: [.shift]), "shift is not fn")
        XCTAssertNil(VoiceDictation.fnChange(keyCode: 123, flags: [.function, .numericPad]), "an arrow key carries the fn flag but isn't fn")
    }
}
