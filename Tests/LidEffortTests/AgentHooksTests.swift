import XCTest
@testable import LidEffort

/// Every agent's turn-finished hook: spyx's own entry in, only spyx's own
/// entry out, and nobody else's hook disturbed.
final class AgentHooksTests: XCTestCase {
    private let exe = "/Applications/spyx.app/Contents/MacOS/spyx"
    private func temp(_ name: String, _ text: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    func testGrokGetsAFileOfItsOwn() throws {
        let url = try temp("spyx.json")
        try AgentHooks.installGrok(executable: exe, at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("--stop-hook --agent grok"))
        XCTAssertTrue(text.contains("\"Stop\""))
        try AgentHooks.removeGrok(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCursorKeepsItsOtherStopHooks() throws {
        let url = try temp("hooks.json", #"{"version":1,"hooks":{"stop":[{"command":"/x/cursor-hook.sh Stop"}],"sessionStart":[{"command":"/x/a"}]}}"#)
        try AgentHooks.installCursor(executable: exe, at: url)
        try AgentHooks.installCursor(executable: exe, at: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var stop = try XCTUnwrap((json["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "theirs and one of ours")
        try AgentHooks.removeCursor(at: url)
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        stop = try XCTUnwrap((json["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["command"] as? String, "/x/cursor-hook.sh Stop")
        XCTAssertNotNil((json["hooks"] as? [String: Any])?["sessionStart"])
    }

    func testCodexCallsWhoeverHadNotifyBefore() throws {
        let original = """
        model = "gpt-5.6"
        notify = [
            "/Apps/Computer Use.app/Client",
            "turn-ended",
        ]

        [features]
        x = true
        """
        let url = try temp("config.toml", original)
        try AgentHooks.installCodex(executable: exe, at: url)
        let installed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(AgentHooks.notifyArray(in: installed),
                       [exe, "--codex-notify", "--then", "/Apps/Computer Use.app/Client", "turn-ended"])
        XCTAssertTrue(installed.contains("[features]"))
        XCTAssertTrue(installed.contains("model = \"gpt-5.6\""))
        try AgentHooks.installCodex(executable: exe, at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), installed, "installing twice changes nothing")

        try AgentHooks.removeCodex(at: url)
        XCTAssertEqual(AgentHooks.notifyArray(in: try String(contentsOf: url, encoding: .utf8)),
                       ["/Apps/Computer Use.app/Client", "turn-ended"], "theirs, exactly as it was")
    }

    func testCodexWithoutNotifyGetsOneAndLosesItAgain() throws {
        let url = try temp("config.toml", "model = \"gpt\"\n\n[tui]\ntheme = \"dark\"\n")
        try AgentHooks.installCodex(executable: exe, at: url)
        let installed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(AgentHooks.notifyArray(in: installed), [exe, "--codex-notify"])
        XCTAssertLessThan(installed.range(of: "notify")!.lowerBound, installed.range(of: "[tui]")!.lowerBound,
                          "a top-level key, before the first table")
        try AgentHooks.removeCodex(at: url)
        XCTAssertNil(AgentHooks.notifyArray(in: try String(contentsOf: url, encoding: .utf8)))
    }

    func testEachAgentsPayloadNamesItsSession() {
        let grok = AgentStop(AgentStop.envelope(agent: "grok", payload: Data(#"{"hookEventName":"stop","sessionId":"01a0"}"#.utf8)))
        XCTAssertEqual(grok, AgentStop(agent: "grok", sessionID: "01a0", cwd: nil))
        let codex = AgentStop(AgentStop.envelope(agent: "codex", payload: Data(#"{"type":"agent-turn-complete","thread-id":"t9","cwd":"/w/app"}"#.utf8)))
        XCTAssertEqual(codex, AgentStop(agent: "codex", sessionID: "t9", cwd: "/w/app"))
        let cursor = AgentStop(AgentStop.envelope(agent: "cursor", payload: Data(#"{"hook_event_name":"stop","conversation_id":"c1","workspace_roots":["/w/site"]}"#.utf8)))
        XCTAssertEqual(cursor, AgentStop(agent: "cursor", sessionID: "c1", cwd: "/w/site"))
        XCTAssertNil(AgentStop(AgentStop.envelope(agent: "grok", payload: Data(#"{"hook_event_name":"SubagentStop","sessionId":"x"}"#.utf8))),
                     "a subagent finishing is not the answer's end")
    }
}
