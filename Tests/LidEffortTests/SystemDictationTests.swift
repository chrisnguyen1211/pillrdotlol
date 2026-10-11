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
}
