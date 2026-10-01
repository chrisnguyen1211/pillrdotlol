import XCTest
@testable import LidEffort

/// Path normalisation and AppleScript escaping behind exact-tab focus.
final class TerminalTabFocusTests: XCTestCase {
    /// The kernel can report `/private/tmp/…` where the terminal's own title
    /// says `/tmp/…` — both spellings have to be tried.
    func testPathCandidatesCoverThePrivatePrefix() {
        let fromPrivate = TerminalTabFocus.cmuxPathCandidates("/private/tmp/x")
        XCTAssertTrue(fromPrivate.contains("/tmp/x"))
        let plain = TerminalTabFocus.cmuxPathCandidates("/tmp/x")
        XCTAssertTrue(plain.contains("/private/tmp/x"))
    }

    func testPathCandidatesAreUniqueAndStartWithTheOriginal() {
        let candidates = TerminalTabFocus.cmuxPathCandidates("/tmp/x")
        XCTAssertEqual(candidates.first, "/tmp/x")
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }

    /// A quote or backslash in a folder name must not break the script.
    func testAppleScriptEscaping() {
        XCTAssertEqual(TerminalTabFocus.appleScriptEscaped(#"a\b "q""#), #"a\\b \"q\""#)
    }

    func testAnUnsupportedTerminalIsNotSelected() {
        XCTAssertFalse(TerminalTabFocus.selectTab(bundleID: "dev.warp.Warp-Stable",
                                                  pid: getpid(), tty: "ttys014", cwd: "/tmp"))
        XCTAssertFalse(TerminalTabFocus.selectTab(bundleID: nil,
                                                  pid: getpid(), tty: "ttys014", cwd: "/tmp"))
    }

    func testNoSurfaceAndNoCwdMeansNoCmuxTab() {
        // A pid whose tree carries no CMUX_SURFACE_ID and no fallback cwd.
        XCTAssertFalse(TerminalTabFocus.selectTab(bundleID: "com.cmuxterm.app",
                                                  pid: 1, tty: nil, cwd: nil))
    }

    /// The runner's own environment block is readable and NUL-parsed.
    func testReadsAProcessEnvironment() {
        let entries = TerminalTabFocus.environment(of: getpid())
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains { $0.hasPrefix("PATH=") })
    }

    /// The test runner's own tty and cwd, when they exist, read like ps
    /// prints them.
    func testReadsTheControllingTerminalName() {
        if let tty = SessionFocus.tty(of: getpid()) {
            XCTAssertTrue(tty.hasPrefix("ttys"), "unexpected tty name \(tty)")
        }
    }

    func testReadsAProcessWorkingDirectory() {
        let cwd = SessionFocus.currentDirectory(of: getpid())
        XCTAssertEqual(cwd?.hasPrefix("/"), true)
    }
}
