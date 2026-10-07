import XCTest
@testable import LidEffort

/// The done card's real-time signal: Claude Code's Stop hook.
final class StopHookTests: XCTestCase {
    private func settings(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testInstallingTouchesOnlyOurOwnEntry() throws {
        let url = try settings(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#)
        try ClaudeHookInstaller.installStop(executable: "/Applications/pillr.app/Contents/MacOS/pillr", at: url)
        try ClaudeHookInstaller.installStop(executable: "/Applications/pillr.app/Contents/MacOS/pillr", at: url)
        XCTAssertTrue(ClaudeHookInstaller.isStopInstalled(at: url))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stop = try XCTUnwrap((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "theirs and one of ours, however often installed")
        XCTAssertEqual(json["model"] as? String, "opus")

        try ClaudeHookInstaller.removeStop(at: url)
        XCTAssertFalse(ClaudeHookInstaller.isStopInstalled(at: url))
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(((after["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count, 1, "theirs stays")
    }

    func testOnlyTheMainAgentsStopCounts() {
        XCTAssertEqual(PromptBroker.stoppedSession(Data(#"{"hook_event_name":"Stop","session_id":"abc"}"#.utf8)), "abc")
        XCTAssertNil(PromptBroker.stoppedSession(Data(#"{"hook_event_name":"SubagentStop","session_id":"abc"}"#.utf8)))
        XCTAssertNil(PromptBroker.stoppedSession(Data(#"{"tool_name":"Bash"}"#.utf8)))
    }

    func testAStopReachesTheAppWithoutWaitingForAnAnswer() throws {
        let path = "/tmp/pillr-stop-\(UUID().uuidString.prefix(8)).sock"
        let broker = PromptBroker(path: path)
        let got = expectation(description: "stop delivered")
        broker.onStop = { stop in
            XCTAssertEqual(stop, AgentStop(agent: "claude", sessionID: "session-42", cwd: nil))
            got.fulfill()
        }
        try broker.start()
        defer { broker.stop() }
        let started = Date()
        PromptHookClient.notify(Data(#"{"hook_event_name":"Stop","session_id":"session-42","stop_hook_active":false}"#.utf8), path: path)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the hook never waits on pillr")
        wait(for: [got], timeout: 2)
    }
}
