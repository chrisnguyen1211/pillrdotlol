import XCTest
@testable import LidEffort

/// A Claude Code session that says idle while a shell it started is still
/// alive has work running in the background: not finished.
final class BackgroundShellsTests: XCTestCase {
    func testALiveChildShellIsCountedAndAFinishedOneIsNot() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let before = BackgroundShells.count(under: me)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-c", "sleep 3; true"]   // compound, as Claude Code's are: zsh stays
        try shell.run()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(BackgroundShells.count(under: me), before + 1, "a running background shell")
        shell.terminate()
        shell.waitUntilExit()
        XCTAssertEqual(BackgroundShells.count(under: me), before, "gone once it ends")
    }

    func testAProcessWithoutChildrenHasNone() {
        XCTAssertEqual(BackgroundShells.count(under: 1_999_999), 0)
    }

    /// This Mac, read-only: `PILLR_LIVE=1 swift test --filter BackgroundShellsTests`.
    func testLiveSessions() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PILLR_LIVE"] == "1")
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".json") {
            guard let pid = pid_t(file.dropLast(5)), kill(pid, 0) == 0 else { continue }
            print("SHELLS pid \(pid): \(BackgroundShells.count(under: pid)) background shell(s)")
        }
    }
}
