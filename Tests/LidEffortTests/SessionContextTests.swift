import XCTest
@testable import LidEffort

/// Each agent's own record, read for what you asked a session and what it
/// said at the end. The shapes are the ones seen in real files.
final class SessionContextTests: XCTestCase {
    private func lines(_ json: [String]) -> [[String: Any]] {
        json.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func testCodexReadsYourMessageAndItsLastWords() {
        let context = SessionContext.codex(lines: lines([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"an older ask"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"older reply"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"add a dark mode toggle"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"x"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Working on it"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Added the toggle in Settings."}}"#,
        ]), title: "Theme work")
        XCTAssertEqual(context, PromptContext(title: "Theme work", ask: "add a dark mode toggle", lead: "Added the toggle in Settings."))
    }

    func testCodexFindsTheRolloutUnderItsDay() throws {
        let sessions = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "rollout-2026-10-02T00-53-12-01a0f899-517f-7371-82d9-ea0d9eb2f2b5.jsonl"
        let day = sessions.appendingPathComponent("2026/10/02")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data().write(to: day.appendingPathComponent(name))
        defer { try? FileManager.default.removeItem(at: sessions) }
        XCTAssertEqual(SessionContext.codexRollout(named: name, under: sessions)?.lastPathComponent, name)
    }

    func testGrokLeavesOutTheMessagesItWritesItself() {
        let context = SessionContext.grok(lines: lines([
            #"{"type":"user","content":[{"type":"text","text":"context Grok adds"}],"synthetic_reason":"prompt_context"}"#,
            #"{"type":"user","content":[{"type":"text","text":"fix the symlink on the NAS"}]}"#,
            #"{"type":"assistant","content":"Looking.","tool_calls":[{"id":"1"}]}"#,
            #"{"type":"tool_result","content":"ok"}"#,
            #"{"type":"assistant","content":"The link points at the new share now."}"#,
            #"{"type":"user","content":[{"type":"text","text":"more context"}],"synthetic_reason":"reminder"}"#,
        ]), title: "NAS symlink fix")
        XCTAssertEqual(context, PromptContext(title: "NAS symlink fix", ask: "fix the symlink on the NAS",
                                              lead: "The link points at the new share now."))
    }

    func testKimiTakesItsTitleAndPromptFromStateAndTheReplyFromTheWire() {
        let context = SessionContext.kimi(state: ["title": "Login bug", "lastPrompt": "why does login loop"], wire: lines([
            #"{"type":"turn.prompt","agentId":"main","input":[{"type":"text","text":"why does login loop"}]}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","agentId":"main","part":{"type":"think","text":"hmm"}}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","agentId":"main","part":{"type":"text","text":"The cookie "}}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","agentId":"main","part":{"type":"text","text":"was never cleared."}}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","agentId":"agent-0","part":{"type":"text","text":"a subagent"}}}"#,
            #"{"type":"turn.ended","agentId":"main"}"#,
        ]))
        XCTAssertEqual(context, PromptContext(title: "Login bug", ask: "why does login loop", lead: "The cookie was never cleared."))
    }

    func testGeminiCLIReadsUserAndGeminiRecords() {
        let context = SessionContext.geminiCLI(lines: lines([
            #"{"sessionId":"s","kind":"main"}"#,
            #"{"id":"1","type":"user","content":[{"text":"summarise the README"}]}"#,
            #"{"id":"2","type":"gemini","content":"It explains the install steps."}"#,
        ]))
        XCTAssertEqual(context.ask, "summarise the README")
        XCTAssertEqual(context.lead, "It explains the install steps.")
    }

    func testGeminiCLIReplaysItsPatchesRewindsAndSummary() {
        let context = SessionContext.geminiCLI(lines: lines([
            #"{"sessionId":"s","projectHash":"p","kind":"main"}"#,
            #"{"id":"u1","type":"user","content":[{"text":"first ask"}]}"#,
            #"{"id":"g1","type":"gemini","content":"first answer"}"#,
            #"{"id":"u2","type":"user","content":[{"text":"a wrong turn"}]}"#,
            #"{"id":"g2","type":"gemini","content":"wrong answer"}"#,
            #"{"$rewindTo":"u2"}"#,
            #"{"id":"u3","type":"user","content":"rename the button"}"#,
            #"{"id":"g3","type":"gemini","content":""}"#,
            #"{"$patch":{"id":"g3","content":"Renamed it to Save."}}"#,
            #"{"$set":{"summary":"Button copy"}}"#,
        ]))
        XCTAssertEqual(context, PromptContext(title: "Button copy", ask: "rename the button", lead: "Renamed it to Save."))
    }

    func testKimiCountsOnlyThePromptsYouTyped() {
        let context = SessionContext.kimi(state: [:], wire: lines([
            #"{"type":"turn.prompt","input":[{"type":"text","text":"deploy it"}],"origin":{"kind":"user"}}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"Deployed."}}}"#,
            #"{"type":"turn.prompt","input":[{"type":"text","text":"compaction summary"}],"origin":{"kind":"compaction_summary"}}"#,
        ]))
        XCTAssertEqual(context.ask, "deploy it")
        XCTAssertEqual(context.lead, "Deployed.")
    }

    func testDroidReadsMessagesInClaudesShape() {
        let context = SessionContext.droid(lines: lines([
            #"{"type":"session_start","id":"s","title":"ignored here","cwd":"/x"}"#,
            #"{"type":"message","id":"1","message":{"role":"user","content":[{"type":"text","text":"bump the version"}]}}"#,
            #"{"type":"message","id":"2","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit"}]}}"#,
            #"{"type":"message","id":"3","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"message","id":"4","message":{"role":"assistant","content":[{"type":"text","text":"Bumped to 1.1.3."}]}}"#,
        ]), title: "Release prep")
        XCTAssertEqual(context, PromptContext(title: "Release prep", ask: "bump the version", lead: "Bumped to 1.1.3."))
    }

    @MainActor
    func testCopilotReadsItsSessionStore() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home); unsetenv("COPILOT_HOME") }
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [home.appendingPathComponent("session-store.db").path, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, summary TEXT);
            CREATE TABLE turns (id INTEGER PRIMARY KEY, session_id TEXT, turn_index INTEGER, user_message TEXT, assistant_response TEXT);
            INSERT INTO sessions VALUES ('abc-123', '/x', 'Fix flaky test');
            INSERT INTO turns VALUES (1, 'abc-123', 0, 'old ask', 'old answer');
            INSERT INTO turns VALUES (2, 'abc-123', 1, 'make the test stable', 'Added a retry with a fixed seed.');
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        setenv("COPILOT_HOME", home.path, 1)
        let session = AgentSession(id: "copilot.abc-123", name: "x", detail: "", state: .success, waitingFor: nil, since: Date())
        XCTAssertEqual(SessionContext.load(for: session),
                       PromptContext(title: "Fix flaky test", ask: "make the test stable", lead: "Added a retry with a fixed seed."))
    }

    func testAntigravityTriesOnlyTheUsualFields() {
        let context = SessionContext.antigravity(lines: lines([
            #"{"type":"USER_INPUT","content":"build the landing page"}"#,
            #"{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"write_to_file"}]}"#,
            #"{"type":"PLANNER_RESPONSE","content":"The landing page is up."}"#,
        ]))
        XCTAssertEqual(context.ask, "build the landing page")
        XCTAssertEqual(context.lead, "The landing page is up.")
        XCTAssertEqual(SessionContext.antigravity(lines: lines([#"{"type":"USER_INPUT","unknown":"x"}"#])), PromptContext())
        XCTAssertNil(SessionContext.antigravity(lines: lines([#"{"type":"USER_INPUT","source":"SYSTEM","content":"injected"}"#])).ask)
    }

    func testTheFoldStopsAtYourNewestMessage() {
        let context = SessionContext.fold(newestFirst: [
            .init(fromYou: false, text: "Final **answer**."),
            .init(fromYou: false, text: "Earlier step."),
            .init(fromYou: true, text: "the ask"),
            .init(fromYou: false, text: "a reply to an older ask"),
            .init(fromYou: true, text: "an older ask"),
        ])
        XCTAssertEqual(context, PromptContext(ask: "the ask", lead: "Final answer."))
    }

    func testAnIDOnlyGoesIntoAQueryWhenItIsPlain() {
        XCTAssertTrue(SessionContext.isPlainID("ses_01J9-abc"))
        XCTAssertFalse(SessionContext.isPlainID("x' OR 1=1 --"))
        XCTAssertFalse(SessionContext.isPlainID(""))
    }

    @MainActor
    func testAnAgentWithNoReaderGivesNothing() {
        let session = AgentSession(id: "droid.abc", name: "x", detail: "", state: .success, waitingFor: nil, since: Date())
        XCTAssertNil(SessionContext.load(for: session))
    }
}
