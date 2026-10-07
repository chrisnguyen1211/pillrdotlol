import XCTest
@testable import LidEffort

/// "What is it doing": read from the end of each agent's transcript, with
/// the moment the step began — never a value that moves every tick.
final class SessionDoingTests: XCTestCase {
    private func lines(_ objects: [[String: Any]]) -> String {
        objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }

    // MARK: Claude

    private func claudeTool(_ name: String, _ input: [String: Any], at: String = "2026-10-01T09:33:46.120Z",
                            sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain, "timestamp": at,
         "message": ["stop_reason": "tool_use", "content": [["type": "tool_use", "name": name, "input": input]]]]
    }

    func testClaudeNamesTheRunningToolFromWhenItStarted() throws {
        let tail = lines([
            ["type": "user", "timestamp": "2026-10-01T09:33:40Z", "message": ["content": "run the tests"]],
            claudeTool("Bash", ["command": "swift test --filter Foo", "description": "Run the focused tests"]),
        ])
        let doing = try XCTUnwrap(SessionDoing.claude(tail: tail))
        XCTAssertEqual(doing.text, "Run the focused tests")
        XCTAssertEqual(doing.kind, .tool)
        XCTAssertEqual(doing.since.timeIntervalSince1970, 1790847226.12, accuracy: 0.01)
    }

    func testClaudeIsThinkingOnceTheResultIsBack() throws {
        let tail = lines([
            claudeTool("Read", ["file_path": "/x/Sources/PromptPanel.swift"]),
            ["type": "user", "timestamp": "2026-10-01T09:33:47Z",
             "message": ["content": [["type": "tool_result", "content": "…"]]]],
            ["type": "attachment", "timestamp": "2026-10-01T09:33:47Z"],
        ])
        XCTAssertEqual(SessionDoing.claude(tail: tail)?.kind, .thinking)
    }

    func testClaudeSkipsSubagentWork() {
        let tail = lines([
            claudeTool("Task", ["description": "Map the architecture"]),
            claudeTool("Grep", ["pattern": "AgentSession"], sidechain: true),
        ])
        XCTAssertEqual(SessionDoing.claude(tail: tail)?.text, "Agent: Map the architecture")
    }

    func testClaudeToolsReadAsSentences() {
        XCTAssertEqual(SessionDoing.describeClaude(tool: "Edit", input: ["file_path": "/a/b/Notch.swift"]), "Editing Notch.swift")
        XCTAssertEqual(SessionDoing.describeClaude(tool: "Bash", input: ["command": "git status\necho hi"]), "$ git status")
        XCTAssertEqual(SessionDoing.describeClaude(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]), "Fetching docs.swift.org")
        XCTAssertEqual(SessionDoing.describeClaude(tool: "mcp__github__create_issue", input: [:]), "github · create_issue")
        XCTAssertEqual(SessionDoing.describeClaude(tool: "Grep", input: ["pattern": "TODO"]), "Searching for “TODO”")
    }

    // MARK: Codex

    func testCodexNamesTheCommandUntilItsOutputIsIn() throws {
        let call: [String: Any] = ["timestamp": "2026-10-01T09:03:35.000Z", "type": "response_item",
                                   "payload": ["type": "function_call", "name": "exec_command",
                                               "arguments": #"{"cmd":"npm test -- --watch=false","workdir":"/x"}"#]]
        let running = try XCTUnwrap(SessionDoing.codex(tail: lines([call])))
        XCTAssertEqual(running.text, "$ npm test -- --watch=false")
        XCTAssertEqual(running.kind, .tool)

        let output: [String: Any] = ["timestamp": "2026-10-01T09:03:36Z", "type": "response_item",
                                     "payload": ["type": "function_call_output", "output": "ok"]]
        XCTAssertEqual(SessionDoing.codex(tail: lines([call, output]))?.kind, .thinking)

        let done: [String: Any] = ["timestamp": "2026-10-01T09:03:52Z", "type": "event_msg",
                                   "payload": ["type": "task_complete"]]
        XCTAssertNil(SessionDoing.codex(tail: lines([call, output, done])))
    }

    func testCodexPatchNamesTheFile() {
        let payload: [String: Any] = ["type": "custom_tool_call", "name": "apply_patch",
                                      "input": "*** Begin Patch\n*** Update File: Sources/App/Notch.swift\n@@"]
        XCTAssertEqual(SessionDoing.describeCodex(payload), "Editing Notch.swift")
    }

    // MARK: Grok

    private func grok(_ update: [String: Any], at: String = "2026-10-01T09:10:00Z") -> [String: Any] {
        ["method": "session/update", "timestamp": at, "params": ["sessionId": "s", "update": update]]
    }

    func testGrokUsesTheCallsOwnTitle() throws {
        let call = grok(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Run swift build"])
        let doing = try XCTUnwrap(SessionDoing.grok(tail: lines([call])))
        XCTAssertEqual(doing.text, "Run swift build")
        let progress = grok(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "in_progress"])
        XCTAssertEqual(SessionDoing.grok(tail: lines([call, progress]))?.text, "Run swift build")
        let finished = grok(["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"])
        XCTAssertEqual(SessionDoing.grok(tail: lines([call, finished]))?.kind, .thinking)
        let over = grok(["sessionUpdate": "turn_completed", "stop_reason": "end_turn"])
        XCTAssertNil(SessionDoing.grok(tail: lines([call, finished, over])))
    }

    // MARK: Reading

    func testTheTailDropsItsCutFirstLineAndIsCached() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("doing-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "x", count: 70_000)
        try (filler + "\n" + lines([claudeTool("Read", ["file_path": "/a/Main.swift"])])).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(SessionDoing.tail(of: url).hasPrefix("x"))
        var parses = 0
        let parse: (String) -> AgentSession.Doing? = { parses += 1; return SessionDoing.claude(tail: $0) }
        XCTAssertEqual(SessionDoing.cached(url, parse: parse)?.text, "Reading Main.swift")
        XCTAssertEqual(SessionDoing.cached(url, parse: parse)?.text, "Reading Main.swift")
        XCTAssertEqual(parses, 1, "an unchanged file is not read again")
    }

    /// Against this Mac's real sessions, read-only: `PILLR_LIVE=1 swift test --filter SessionDoingTests`.
    @MainActor
    func testLiveSessionsSayWhatTheyAreDoing() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PILLR_LIVE"] == "1")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let reader = ClaudeTranscriptReader(projects: home.appendingPathComponent("projects"))
        let sessions = ClaudeSessionMonitor.read(directory: home.appendingPathComponent("sessions"), transcripts: reader)
        for session in sessions {
            print("LIVE \(session.name) [\(session.state)] \(session.doing.map { "\($0.text)" } ?? "-") · \(session.tokens ?? "no tokens")")
        }
    }
}
