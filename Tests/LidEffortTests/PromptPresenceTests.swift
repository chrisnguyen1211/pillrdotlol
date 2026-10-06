import XCTest
@testable import LidEffort

/// A question waits in the notch for someone who stepped away: it is only
/// handed back to the session's own dialog while someone is at the Mac.
final class PromptPresenceTests: XCTestCase {
    func testSomeoneAwayIsNotLookingAtAnything() {
        XCTAssertTrue(UserPresence.isPresent(idle: 5, locked: false))
        XCTAssertFalse(UserPresence.isPresent(idle: 5, locked: true), "a locked screen is no one's view")
        XCTAssertFalse(UserPresence.isPresent(idle: 600, locked: false), "ten minutes without a key or a move: away")
    }

    func testAQuestionOutlastsAnAfternoonAway() {
        XCTAssertGreaterThanOrEqual(ClaudeHookInstaller.timeoutSeconds, 8 * 3600)
        XCTAssertLessThan(PromptBroker().patience, TimeInterval(ClaudeHookInstaller.timeoutSeconds),
                          "the broker still lets go before Claude kills the hook")
    }

    @MainActor
    func testTheHookIsWrittenWithTheLongTimeout() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        try ClaudeHookInstaller.install(executable: "/A/spyx", at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("86400"), text)
    }
}
