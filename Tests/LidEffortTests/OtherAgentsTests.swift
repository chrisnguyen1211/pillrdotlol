import XCTest
import LidEffortCore
@testable import LidEffort

/// Every other agent's hook goes in and out the same way — pillr's own entry
/// only, everything else in the file kept — and its stop reads alike. The
/// shapes are the agents' documented ones.
final class OtherAgentsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testDroidStopHookSitsBesideSomeoneElses() throws {
        let url = dir.appendingPathComponent("settings.json")
        try #"{"model":"claude-opus-4-6","hooks":{"Stop":[{"hooks":[{"type":"command","command":"other.sh"}]}]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        try AgentHooks.installClaudeStyle(at: url, event: "Stop", agent: "droid", executable: "/A/pillr")
        try AgentHooks.installClaudeStyle(at: url, event: "Stop", agent: "droid", executable: "/A/pillr")
        XCTAssertTrue(AgentHooks.isClaudeStyleInstalled(at: url, event: "Stop"))
        let stops = try XCTUnwrap((try json(url)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stops.count, 2, "installed twice is still one entry, beside the other tool's")
        XCTAssertEqual(try json(url)["model"] as? String, "claude-opus-4-6")
        try AgentHooks.removeClaudeStyle(at: url, event: "Stop")
        XCTAssertFalse(AgentHooks.isClaudeStyleInstalled(at: url, event: "Stop"))
        XCTAssertEqual(((try json(url)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count, 1)
    }

    func testAFileThatIsNotJSONIsNeverReplaced() throws {
        let url = dir.appendingPathComponent("settings.json")
        let jsonc = "{ // a comment\n \"model\": \"x\" }"
        try jsonc.write(to: url, atomically: true, encoding: .utf8)
        try AgentHooks.installClaudeStyle(at: url, event: "AfterAgent", agent: "gemini-cli", executable: "/A/pillr")
        try AgentHooks.installCursor(executable: "/A/pillr", at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), jsonc)
    }

    func testGeminiCLITimesOutInMilliseconds() throws {
        let url = dir.appendingPathComponent("settings.json")
        try AgentHooks.installClaudeStyle(at: url, event: "AfterAgent", agent: "gemini-cli", executable: "/A/pillr",
                                          timeout: 5000, matcher: "*")
        let entry = try XCTUnwrap(((try json(url)["hooks"] as? [String: Any])?["AfterAgent"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["matcher"] as? String, "*")
        XCTAssertEqual((entry["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 5000)
    }

    func testAntigravityHookIsKeyedByItsOwnName() throws {
        let url = dir.appendingPathComponent("hooks.json")
        try #"{"theirs":{"enabled":true,"Stop":[]}}"#.write(to: url, atomically: true, encoding: .utf8)
        try AgentHooks.installAntigravity(executable: "/A/pillr", at: url)
        XCTAssertTrue(AgentHooks.isAntigravityInstalled(at: url))
        try AgentHooks.removeAntigravity(at: url)
        XCTAssertFalse(AgentHooks.isAntigravityInstalled(at: url))
        XCTAssertNotNil(try json(url)["theirs"])
    }

    func testCopilotHookIsAFileOfItsOwn() throws {
        let url = dir.appendingPathComponent("hooks/pillr.json")
        try AgentHooks.installCopilot(executable: "/A/pillr", at: url)
        let hook = try XCTUnwrap(((try json(url)["hooks"] as? [String: Any])?["agentStop"] as? [[String: Any]])?.first)
        XCTAssertTrue((hook["bash"] as? String)?.contains("--agent copilot") == true)
        try AgentHooks.removeCopilot(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testKimiHookBlockComesOutWhole() throws {
        let url = dir.appendingPathComponent("config.toml")
        let original = "default_model = \"kimi-k2\"\n\n[[hooks]]\nevent = \"Stop\"\ncommand = \"theirs.sh\"\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        try AgentHooks.installKimi(executable: "/A/spy\"x", at: url)
        try AgentHooks.installKimi(executable: "/A/spy\"x", at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "--agent kimi").count, 2, "one block, however often installed")
        XCTAssertTrue(text.contains(#"command = "'/A/spy\"x' --stop-hook --agent kimi""#), "quoted as a TOML string")
        XCTAssertTrue(AgentHooks.isKimiInstalled(at: url))
        try AgentHooks.removeKimi(at: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testOpenCodePluginIsOursAndOnlyOursIsRemoved() throws {
        let url = dir.appendingPathComponent("plugins/pillr.js")
        try AgentHooks.installOpenCode(executable: "/Applications/pillr.app/Contents/MacOS/pillr", at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#"const pillr = "\/Applications\/pillr.app\/Contents\/MacOS\/pillr""#)
                      || text.contains(#"const pillr = "/Applications/pillr.app/Contents/MacOS/pillr""#))
        XCTAssertTrue(text.contains("session.status"))
        try AgentHooks.removeOpenCode(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try "export const Mine = 1\n".write(to: url, atomically: true, encoding: .utf8)
        try AgentHooks.removeOpenCode(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a file pillr did not write stays")
    }

    func testEveryAgentsStopReadsAlike() {
        func stop(_ agent: String, _ payload: String) -> AgentStop? {
            AgentStop(AgentStop.envelope(agent: agent, payload: Data(payload.utf8)))
        }
        let antigravity = stop("antigravity", #"{"conversationId":"c1","workspacePaths":["/w/app"],"fullyIdle":true}"#)
        XCTAssertEqual(antigravity?.sessionID, "c1")
        XCTAssertEqual(antigravity?.cwd, "/w/app")
        XCTAssertNil(stop("antigravity", #"{"conversationId":"c1","fullyIdle":false}"#), "between steps is not done")
        XCTAssertEqual(stop("copilot", #"{"sessionId":"s9","cwd":"/w","stopReason":"end_turn"}"#)?.sessionID, "s9")
        XCTAssertEqual(stop("gemini-cli", #"{"session_id":"g1","cwd":"/w","hook_event_name":"AfterAgent"}"#)?.sessionID, "g1")
        XCTAssertNil(stop("droid", #"{"session_id":"d1","hook_event_name":"SubagentStop"}"#))
    }

    func testKimiWireNamesModelEffortAndTokens() {
        let wire = """
        {"type":"metadata","protocol_version":2}
        {"type":"llm.request","agentId":"main","modelAlias":"kimi-k2","thinkingEffort":"high","time":1}
        {"type":"usage.record","agentId":"sub1","model":"kimi-k2-mini","usage":{"output":5},"usageScope":"session"}
        {"type":"usage.record","agentId":"main","model":"kimi-k2-turbo","usage":{"inputOther":100,"output":20,"inputCacheRead":300,"inputCacheCreation":0},"usageScope":"session"}
        """
        let readings = KimiActivity.readings(inTail: Data(wire.utf8))
        XCTAssertEqual(readings.model, "kimi-k2-turbo")
        XCTAssertEqual(readings.effort, "high")
        XCTAssertEqual(readings.tokens, 420)
    }

    func testCursorHeaderFacts() {
        XCTAssertEqual(CursorActivityMonitor.facts(["totalLinesAdded": 120, "totalLinesRemoved": 30, "contextUsagePercent": 63.6]),
                       ["+120 −30", "64% context"])
        XCTAssertEqual(CursorActivityMonitor.facts(["totalLinesAdded": 0, "totalLinesRemoved": 0]), [])
    }

    func testNewEffortTargetsFollowTheirModels() {
        XCTAssertEqual(BuiltInTargets.droid.value(for: .max, model: "claude-opus-4-6"), "max")
        XCTAssertEqual(BuiltInTargets.droid.value(for: .max, model: "claude-sonnet-4-5"), "high")
        XCTAssertEqual(BuiltInTargets.droid.value(for: .xhigh, model: "gpt-5.6"), "xhigh")
        XCTAssertEqual(BuiltInTargets.copilot.value(for: .max, model: "auto"), "xhigh")
        XCTAssertEqual(BuiltInTargets.kimi.value(for: .max, model: "kimi-k2"), "max")
        XCTAssertFalse(BuiltInTargets.droid.isPresent { _ in false }, "a settings file alone is not Droid")
        XCTAssertTrue(BuiltInTargets.hermes.isPresent { _ in false }, "no presence paths: the config is enough")
    }

    func testKimisThinkingSectionIsAddedWhenMissing() {
        let out = ConfigDocument.writeString(key: "effort", section: "thinking", value: "high", format: .toml,
                                             text: "default_model = \"kimi-k2\"\n", createSection: true)
        XCTAssertEqual(out, "default_model = \"kimi-k2\"\n\n[thinking]\neffort = \"high\"\n")
        XCTAssertNil(ConfigDocument.writeString(key: "effort", section: "thinking", value: "high", format: .toml,
                                                text: "x = 1\n"), "only a target that owns the section adds it")
    }
}

final class ClaudeSettingsSafetyTests: XCTestCase {
    func testAMidEditSettingsFileIsNeverReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let broken = "{\n  \"model\": \"opus\",\n  \"permissions\": {\"allow\": [\"Bash(ls)\"]\n"
        try broken.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeHookInstaller.install(executable: "/A/pillr", at: url))
        XCTAssertThrowsError(try ClaudeHookInstaller.installStop(executable: "/A/pillr", at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken)
    }
}
