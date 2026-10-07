import XCTest
@testable import LidEffort

final class ClaudeSessionRecordTests: XCTestCase {
    private func record(_ json: String) -> ClaudeSessionRecord? {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return ClaudeSessionRecord(json: object)
    }

    private func session(_ json: String) -> AgentSession? { record(json)?.session }

    /// A real file, trimmed. Unknown keys must not cost us the session.
    func testDecodesALiveSession() throws {
        let s = try XCTUnwrap(session("""
        { "pid": 2678, "sessionId": "c85d4247", "cwd": "/Users/alex/usage-notch",
          "startedAt": 1787894126697, "procStart": "Fri Aug 28 05:15:20 2026",
          "kind": "interactive", "entrypoint": "cli", "name": "usage-notch-bc",
          "status": "busy", "statusUpdatedAt": 1787897225305,
          "peerFeatures": ["notify_idle"], "somethingNew": 42 }
        """))
        XCTAssertEqual(s.id, "claude.2678")
        XCTAssertEqual(s.name, "usage-notch-bc")
        XCTAssertEqual(s.state, .busy)
        XCTAssertEqual(s.detail, "Terminal · usage-notch")
    }

    func testWaitingCarriesWhatItIsWaitingFor() throws {
        let s = try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "waiting", "waitingFor": "permission" }
        """))
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.waitingFor, "permission")
    }

    /// `tempo` is the normalised form and outranks the raw status word.
    func testTempoWins() throws {
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "busy", "tempo": "blocked" }
        """)).state, .waiting)
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "idle", "tempo": "active" }
        """)).state, .busy)
    }

    func testUnknownStatusIsTreatedAsIdle() throws {
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/tmp/x", "status": "hibernating" }
        """)).state, .idle)
    }

    func testFallsBackToTheFolderWhenUnnamed() throws {
        XCTAssertEqual(try XCTUnwrap(session("""
        { "pid": 1, "cwd": "/Users/alex/notch-app", "status": "idle" }
        """)).name, "notch-app")
    }

    func testRejectsRecordsWithoutAPidOrCwd() {
        XCTAssertNil(session(#"{ "cwd": "/tmp/x", "status": "busy" }"#))
        XCTAssertNil(session(#"{ "pid": 1, "status": "busy" }"#))
    }

    func testSurfaceNamesWhereItIsRunning() throws {
        func surface(_ entrypoint: String) throws -> String {
            ClaudeSessionRecord.surface(entrypoint)
        }
        XCTAssertEqual(try surface("claude-vscode"), "VS Code")
        XCTAssertEqual(try surface("claude-desktop"), "Desktop")
        XCTAssertEqual(try surface("cli"), "Terminal")
    }

    /// `procStart` is a ctime string in UTC. Reading it as local time puts it
    /// hours out, and the liveness check then throws away a live session — which
    /// is exactly what happened the first time this was wired up.
    func testProcStartIsParsedAsUTC() throws {
        let parsed = try XCTUnwrap(ClaudeSessionRecord.parseProcStart("Fri Aug 28 05:15:20 2026"))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1787894120, accuracy: 1)
    }

    func testProcStartHandlesASpacePaddedDay() throws {
        let parsed = try XCTUnwrap(ClaudeSessionRecord.parseProcStart("Sat Aug  8 05:15:20 2026"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.day, from: parsed), 8)
    }

    /// The epoch field is unambiguous, so it wins over the ctime string.
    func testPrefersTheEpochStartTime() throws {
        let r = try XCTUnwrap(record("""
        { "pid": 1, "cwd": "/tmp/x", "status": "busy",
          "startedAt": 1787894126697, "procStart": "Mon Jan 1 00:00:00 2001" }
        """))
        XCTAssertEqual(try XCTUnwrap(r.startedAt).timeIntervalSince1970, 1787894126.697, accuracy: 0.01)
    }
}

/// Which source gets to say what a session is doing.
///
/// Claude Code fills `status` in from its terminal interface, so a terminal
/// session's record answers for itself and a desktop session's never does. The
/// split has to hold in both directions: the desktop case is the bug being
/// fixed, and the terminal case is the behaviour that must not change —
/// `waiting` in particular, which nothing but the terminal interface can know.
@MainActor
final class ClaudeSessionStateSourceTests: XCTestCase {
    private var projects: URL!

    override func setUpWithError() throws {
        projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projects)
    }

    private func record(_ json: String) throws -> ClaudeSessionRecord {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(ClaudeSessionRecord(json: object))
    }

    private func writeTranscript(_ body: String, session: String, cwd: String) throws {
        let directory = projects
            .appendingPathComponent(ClaudeTranscript.projectSlug(forCWD: cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: directory.appendingPathComponent("\(session).jsonl"))
    }

    private var reader: ClaudeTranscriptReader { ClaudeTranscriptReader(projects: projects) }

    /// The real shape of a desktop session's file, trimmed. No status, no
    /// tempo, no `statusUpdatedAt` — and the file is written once, when the
    /// session starts, so its own timestamp says nothing either.
    private let desktop = """
    { "pid": 26440, "sessionId": "0b24b489", "cwd": "/Users/alex/app",
      "startedAt": 1788731755247, "procStart": "Sun Sep  6 21:55:54 2026",
      "kind": "interactive", "entrypoint": "claude-desktop", "name": "app-6c",
      "messagingSocketPath": "/tmp/cc-socks/26440.sock" }
    """

    func testADesktopRecordAdmitsItSaysNothingAboutState() throws {
        let desktop = try record(desktop)
        XCTAssertFalse(desktop.reportsStatus)
        XCTAssertEqual(desktop.sessionID, "0b24b489")
        XCTAssertEqual(desktop.cwd, "/Users/alex/app")
        XCTAssertEqual(desktop.session.detail, "Desktop · app")

        let terminal = try record(#"{ "pid": 1, "cwd": "/tmp/x", "status": "busy" }"#)
        XCTAssertTrue(terminal.reportsStatus)
    }

    /// A word neither of us knows is worth no more than no word at all, so it
    /// goes to the transcript too.
    func testAnUnrecognisedStatusIsNotAnAnswer() throws {
        XCTAssertFalse(try record(#"{ "pid": 1, "cwd": "/tmp/x", "status": "hibernating" }"#)
            .reportsStatus)
        XCTAssertTrue(try record(#"{ "pid": 1, "cwd": "/tmp/x", "status": "idle" }"#)
            .reportsStatus)
    }

    func testADesktopSessionTakesItsStateFromTheTranscript() throws {
        try writeTranscript(#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
                            session: "0b24b489", cwd: "/Users/alex/app")
        let session = ClaudeSessionMonitor.state(of: try record(desktop), transcripts: reader)
        XCTAssertEqual(session.state, .busy)
        XCTAssertEqual(session.id, "claude.26440")
    }

    func testADesktopSessionThatFinishedItsTurnIsIdle() throws {
        try writeTranscript(#"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#,
                            session: "0b24b489", cwd: "/Users/alex/app")
        XCTAssertEqual(
            ClaudeSessionMonitor.state(of: try record(desktop), transcripts: reader).state, .idle
        )
    }

    /// With no transcript to read, the record's own answer stands — which is
    /// exactly what the notch did before any of this existed.
    func testWithNoTranscriptTheRecordStands() throws {
        XCTAssertEqual(
            ClaudeSessionMonitor.state(of: try record(desktop), transcripts: reader).state, .idle
        )
        XCTAssertEqual(
            ClaudeSessionMonitor.state(of: try record(desktop), transcripts: nil).state, .idle
        )
    }

    /// The behaviour that must not regress: a terminal session says `waiting`,
    /// and the transcript — which cannot see a permission prompt at all — is
    /// never allowed to talk it out of that.
    func testATerminalSessionKeepsItsOwnStateAndItsWaitingFor() throws {
        let waiting = try record("""
        { "pid": 7, "sessionId": "0b24b489", "cwd": "/Users/alex/app",
          "status": "waiting", "waitingFor": "permission" }
        """)
        try writeTranscript(#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
                            session: "0b24b489", cwd: "/Users/alex/app")
        let session = ClaudeSessionMonitor.state(of: waiting, transcripts: reader)
        XCTAssertEqual(session.state, .waiting)
        XCTAssertEqual(session.waitingFor, "permission")
    }

    // MARK: - Deduplication

    /// Resuming after a crash registers a new pid while the old process is
    /// still winding down, and for a moment both files are live. One session
    /// must not be drawn twice.
    func testTheSameSessionUnderTwoPidsIsDrawnOnce() throws {
        let old = try record("""
        { "pid": 1, "sessionId": "same", "cwd": "/tmp/x", "startedAt": 1000000 }
        """)
        let new = try record("""
        { "pid": 2, "sessionId": "same", "cwd": "/tmp/x", "startedAt": 2000000 }
        """)
        for pair in [[old, new], [new, old]] {
            let kept = ClaudeSessionMonitor.deduplicated(pair)
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept.first?.pid, 2, "the most recently started record wins")
        }
    }

    func testDifferentSessionsAreAllKept() throws {
        let a = try record(#"{ "pid": 1, "sessionId": "a", "cwd": "/tmp/x" }"#)
        let b = try record(#"{ "pid": 2, "sessionId": "b", "cwd": "/tmp/x" }"#)
        XCTAssertEqual(ClaudeSessionMonitor.deduplicated([a, b]).count, 2)
    }

    /// A record old enough to have no session id cannot be matched against
    /// anything, so it is kept rather than dropped or merged.
    func testRecordsWithoutASessionIdAreKept() throws {
        let a = try record(#"{ "pid": 1, "cwd": "/tmp/x" }"#)
        let b = try record(#"{ "pid": 2, "cwd": "/tmp/x" }"#)
        XCTAssertEqual(ClaudeSessionMonitor.deduplicated([a, b]).count, 2)
    }
}

/// A record with nothing to date itself by must still answer the same thing
/// twice. It used to answer `Date()`, so every rescan produced a session that
/// compared unequal to the one before it and the notch re-animated at 2 Hz.
extension ClaudeSessionRecordTests {
    func testARecordWithNoTimestampHoldsStill() throws {
        let json = """
        { "pid": 1, "sessionId": "a", "cwd": "/tmp/x", "startedAt": 1788731755247,
          "entrypoint": "claude-desktop" }
        """
        let first = try XCTUnwrap(session(json))
        let second = try XCTUnwrap(session(json))
        XCTAssertEqual(first.since, second.since)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.since.timeIntervalSince1970, 1788731755.247, accuracy: 0.01)
    }
}

/// The session pillr starts itself must never reach the notch.
///
/// Renewing the OAuth token runs the Claude CLI, and the CLI registers a
/// session file for the second or so it is alive — verified on a real machine:
/// the count under `~/.claude/sessions` goes six, seven, six, and the file
/// carries the pid of the process pillr spawned. Left alone it draws a row
/// nobody asked for, and `isBusy` reads it as work in progress and starts
/// polling usage hard on the strength of it.
@MainActor
final class ClaudeOwnSessionFilterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// This process, so the liveness check passes and the only thing under test
    /// is the filter.
    private var livePID: Int32 { ProcessInfo.processInfo.processIdentifier }

    private func writeSession(pid: Int32, name: String) throws {
        let json = """
        { "pid": \(pid), "sessionId": "\(name)", "cwd": "/Users/alex/app",
          "name": "\(name)", "entrypoint": "claude-desktop" }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("\(pid).json"))
    }

    func testTheSessionIsReadWhenNothingIsIgnored() throws {
        try writeSession(pid: livePID, name: "mine")
        let found = ClaudeSessionMonitor.read(directory: directory)
        XCTAssertEqual(found.map(\.name), ["mine"])
    }

    func testAnIgnoredPidIsLeftOut() throws {
        try writeSession(pid: livePID, name: "mine")
        let found = ClaudeSessionMonitor.read(directory: directory, ignoring: [livePID])
        XCTAssertTrue(found.isEmpty, "the session Lid Effort started is not the user's")
    }

    /// Ignoring one must not hide the rest — the notch still has to show every
    /// session the user actually has open.
    func testEveryOtherSessionSurvives() throws {
        try writeSession(pid: livePID, name: "ours")
        try writeSession(pid: getppid(), name: "theirs")
        let found = ClaudeSessionMonitor.read(directory: directory, ignoring: [livePID])
        XCTAssertEqual(found.map(\.name), ["theirs"])
    }
}
