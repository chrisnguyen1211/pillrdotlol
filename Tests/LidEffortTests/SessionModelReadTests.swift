import XCTest
@testable import LidEffort

/// Each agent's session says which model it runs, read in the same pass as
/// its tokens — the shapes below are the real ones, cut down.
final class SessionModelReadTests: XCTestCase {
    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testClaudeTakesTheNewestRealModel() throws {
        let url = try file([
            #"{"type":"assistant","message":{"id":"a","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","message":{"id":"b","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","message":{"id":"c","model":"<synthetic>"}}"#,
        ])
        let read = TokenTally.read(url, format: .claude)
        XCTAssertEqual(read?.model, "claude-opus-5-5")
        XCTAssertEqual(read?.total, 30)
    }

    func testCodexTakesModelAndEffortFromTheTurnContext() throws {
        let url = try file([
            #"{"type":"turn_context","payload":{"type":"turn_context","model":"gpt-5.6-terra","effort":"xhigh","summary":"auto"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1200,"cached_input_tokens":800}}}}"#,
        ])
        let read = TokenTally.read(url, format: .codex)
        XCTAssertEqual(read?.model, "gpt-5.6-terra")
        XCTAssertEqual(read?.effort, "xhigh")
        XCTAssertEqual(read?.total, 1200, "the running total does not wipe the model")
    }

    func testGrokTakesTheModelFromItsUpdates() throws {
        let url = try file([
            #"{"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","_meta":{"modelId":"grok-4.7"}}}}"#,
        ])
        let read = TokenTally.read(url, format: .grok)
        XCTAssertEqual(read?.model, "grok-4.7")
        XCTAssertNil(TokenTally.count(url, format: .grok), "no tokens yet: nothing to show as a count")
    }

    func testACopyWithANewStateKeepsTheModel() {
        var session = AgentSession(id: "codex.1", name: "x", detail: "Codex", state: .idle, waitingFor: nil, since: Date())
        session.model = "gpt-5.5"
        session.effort = "high"
        let copy = AgentSession(id: "codex.1", name: "x", detail: "Codex", state: .waiting, waitingFor: nil, since: Date())
            .keepingModel(of: session)
        XCTAssertEqual(copy.model, "gpt-5.5")
        XCTAssertEqual(copy.effort, "high")
    }
}
