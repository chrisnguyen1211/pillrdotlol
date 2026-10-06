import XCTest
@testable import LidEffort

/// A reply sent for real, end to end, into a Terminal tab running a stand-in
/// agent (`fake-agent.sh`: an idle `❯` prompt that writes each line it gets
/// to `received.txt`). Skipped unless `SPYX_LIVE_REPLY_DIR` names that
/// stand-in's folder — it types into a real window, so it is never run by
/// accident.
@MainActor
final class LiveReplyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SPYX_LIVE_REPLY_DIR"] else {
            throw XCTSkip("live reply test: set SPYX_LIVE_REPLY_DIR")
        }
        dir = URL(fileURLWithPath: path)
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func setMode(_ mode: String) throws {
        try mode.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    private var session: AgentSession {
        AgentSession(id: "claude.live", name: "reply test", detail: "", state: .idle, waitingFor: nil,
                     since: Date(), processID: pid_t(read("pid")))
    }

    /// The stand-in redraws its prompt within a second of a mode change.
    private func redraw() async throws {
        try await Task.sleep(nanoseconds: 1_600_000_000)
    }

    func testAReplyReachesAnIdleTerminalSessionAndOnlyThen() async throws {
        let tty = read("tty")
        XCTAssertEqual(SessionCommander.reach(session), .terminal(tty: tty), "routed to its own Terminal tab")

        // Idle: sent, and the agent got exactly the line.
        try setMode("idle")
        let message = "spyx reply test — xin chào \"quoted\" & $HOME `tick` \\ end"
        let outcome1 = await SessionCommander.reply(message, to: session)

        XCTAssertEqual(outcome1, .sent)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(read("received.txt").components(separatedBy: "\n").last, message,
                       "the agent received the message byte for byte")

        // A multi-line message arrives as one line, not as two sends.
        let outcome2 = await SessionCommander.reply("line one\nline two", to: session)

        XCTAssertEqual(outcome2, .sent)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(read("received.txt").components(separatedBy: "\n").last, "line one line two")

        // Busy: a running turn is not typed into.
        try setMode("busy")
        try await redraw()
        let before = read("received.txt")
        let outcome3 = await SessionCommander.reply("must not arrive (busy)", to: session)

        XCTAssertEqual(outcome3, .busy)

        // A draft at the prompt is never appended to.
        try setMode("draft")
        try await redraw()
        let outcome4 = await SessionCommander.reply("must not arrive (draft)", to: session)

        XCTAssertEqual(outcome4, .busy)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(read("received.txt").contains("must not arrive"), "nothing was typed while busy")
        XCTAssertEqual(read("received.txt"), before)

        try setMode("idle")
        try await redraw()
    }
}

/// What spyx makes of the Claude Code sessions on this Mac right now: state,
/// pid and route, so a missing Reply button can be told from a busy row.
/// Skipped unless `SPYX_LIVE_SESSIONS` is set. Prints, never writes.
@MainActor
final class LiveSessionReachDiagnostics: XCTestCase {
    func testPrintEachSessionsRoute() throws {
        guard ProcessInfo.processInfo.environment["SPYX_LIVE_SESSIONS"] != nil else {
            throw XCTSkip("set SPYX_LIVE_SESSIONS")
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = ClaudeSessionRecord(json: json) else { continue }
            let session = record.session
            print("LIVE \(session.id) state=\(session.state) pid=\(session.processID.map(String.init) ?? "nil") reach=\(SessionCommander.reach(session)) owner=\(session.processID.flatMap { SessionFocus.owningApp(of: $0)?.bundleIdentifier } ?? "nil")")
        }
    }
}
