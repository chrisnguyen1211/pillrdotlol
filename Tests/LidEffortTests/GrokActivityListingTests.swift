import XCTest
@testable import LidEffort

/// A Grok session is listed for as long as its process lives: working while
/// its turn is open — however long a command runs without a word — idle once
/// the turn is complete.
final class GrokActivityListingTests: XCTestCase {
    private func setUp(events: [[String: Any]], age: TimeInterval) throws -> (active: URL, root: URL, now: Date) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString)")
        let id = "01a0f8aa-cd49-77c0-ab0b-70d54599921a"
        let dir = base.appendingPathComponent("sessions/%2Ftmp%2Fwork/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let updates = dir.appendingPathComponent("updates.jsonl")
        let lines = events.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: updates, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: updates.path)
        let active = base.appendingPathComponent("active_sessions.json")
        let row: [String: Any] = ["session_id": id, "pid": Int(ProcessInfo.processInfo.processIdentifier), "cwd": "/tmp/work"]
        try JSONSerialization.data(withJSONObject: [row]).write(to: active)
        return (active, base.appendingPathComponent("sessions"), now)
    }

    private func event(_ update: [String: Any], at: TimeInterval) -> [String: Any] {
        ["method": "session/update", "timestamp": at, "params": ["sessionId": "s", "update": update]]
    }

    func testAnIdleSessionIsStillListed() throws {
        let t = Date().timeIntervalSince1970 - 600
        let env = try setUp(events: [event(["sessionUpdate": "tool_call", "toolCallId": "a", "title": "Run tests"], at: t),
                                     event(["sessionUpdate": "turn_completed"], at: t + 5)], age: 600)
        let sessions = GrokActivity.read(activeURL: env.active, sessionsRoot: env.root, staleAfter: 45, now: env.now)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .idle)
        XCTAssertNil(sessions.first?.doing)
    }

    func testALongSilentCommandIsStillWork() throws {
        let t = Date().timeIntervalSince1970 - 300
        let env = try setUp(events: [event(["sessionUpdate": "tool_call", "toolCallId": "a", "title": "Execute docker compose up"], at: t)],
                            age: 300)
        let session = try XCTUnwrap(GrokActivity.read(activeURL: env.active, sessionsRoot: env.root, staleAfter: 45, now: env.now).first)
        XCTAssertEqual(session.state, .busy)
        XCTAssertEqual(session.doing?.text, "Execute docker compose up")
        XCTAssertEqual(session.since.timeIntervalSince1970, t, accuracy: 1, "timed from the call, not the file")
    }

    func testATurnOpenForHalfAnHourIsStuckNotWork() throws {
        let t = Date().timeIntervalSince1970 - 3600
        let env = try setUp(events: [event(["sessionUpdate": "tool_call", "toolCallId": "a", "title": "x"], at: t)], age: 3600)
        XCTAssertEqual(GrokActivity.read(activeURL: env.active, sessionsRoot: env.root, staleAfter: 45, now: env.now).first?.state, .idle)
    }

    func testAFinishedTurnIsAnnouncedOnce() throws {
        let t = Date().timeIntervalSince1970 - 20
        let open = try setUp(events: [event(["sessionUpdate": "tool_call", "toolCallId": "a", "title": "Run tests"], at: t)], age: 20)
        var watcher = SessionCompletionWatcher()
        _ = watcher.absorb(["grok": GrokActivity.read(activeURL: open.active, sessionsRoot: open.root, staleAfter: 45, now: open.now)])
        // The turn completes: same session, now finished.
        let updates = try XCTUnwrap(FileManager.default.enumerator(at: open.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "updates.jsonl" })
        let handle = try FileHandle(forWritingTo: updates)
        handle.seekToEndOfFile()
        handle.write(Data((String(decoding: try JSONSerialization.data(withJSONObject: event(["sessionUpdate": "turn_completed"], at: t + 15)), as: UTF8.self) + "\n").utf8))
        try handle.close()
        let finished = GrokActivity.read(activeURL: open.active, sessionsRoot: open.root, staleAfter: 45, now: Date())
        XCTAssertEqual(finished.first?.state, .success)
        let events = watcher.absorb(["grok": finished])
        XCTAssertEqual(events.count, 1, "the done card for Grok")
        XCTAssertEqual(events.first?.reason, .finished)
    }
}
