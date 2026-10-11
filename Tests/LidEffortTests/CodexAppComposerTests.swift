import SQLite3
import XCTest
@testable import LidEffort

/// The Codex app (ChatGPT.app, `com.openai.codex`): its threads opened by
/// its own link, the thread on screen told from its window, its message box
/// and button known in any language, and only the app's threads answered there.
final class CodexAppComposerTests: XCTestCase {
    private let thread = "019f6973-158a-7a42-b9aa-09ebf93ce67b"

    // MARK: Links

    func testAThreadIsOpenedByTheAppsOwnLink() {
        XCTAssertEqual(CodexDesktopComposer.link(toThread: thread)?.absoluteString, "codex://threads/\(thread)")
        XCTAssertEqual(CodexDesktopComposer.threadID(inLink: "codex://threads/\(thread)"), thread)
        XCTAssertEqual(CodexDesktopComposer.threadID(inLink: "codex://threads/\(thread)?prompt=hi"), thread,
                       "the app reads the first segment, whatever follows")
    }

    func testOnlyAThreadIdMakesALink() {
        XCTAssertNil(CodexDesktopComposer.link(toThread: "new"), "codex://threads/new starts a new chat")
        XCTAssertNil(CodexDesktopComposer.link(toThread: "../settings"))
        XCTAssertNil(CodexDesktopComposer.link(toThread: "\(thread)?prompt=rm"))
        XCTAssertNil(CodexDesktopComposer.link(toThread: "\(thread)/review"))
        XCTAssertNil(CodexDesktopComposer.link(toThread: ""))
        XCTAssertNil(CodexDesktopComposer.link(toThread: "local_56f8c627-e12b-4431-a984-b5ffc9f735d5"),
                     "a Claude app id is not a Codex thread")
        XCTAssertNil(CodexDesktopComposer.threadID(inLink: "codex://threads/new"))
        XCTAssertNil(CodexDesktopComposer.threadID(inLink: "codex://settings/\(thread)"))
        XCTAssertNil(CodexDesktopComposer.threadID(inLink: "https://chatgpt.com/threads/\(thread)"))
    }

    // MARK: Which thread is on screen

    private var titles: [String: [String]] {
        [thread: ["Fix the login loop"],
         "019f8df4-863c-7952-8bf8-db01ae7c45e8": ["Pricing page"],
         "019f8df8-abab-77c0-98db-1efea7d32b4d": ["Same name"],
         "019f8e32-f5a1-76c1-a346-5d3e4e00e6dd": ["Same name"]]
    }

    func testTheThreadOnScreenIsTheOneItsSidebarRowNames() {
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Fix the login loop"], thread: thread, titles: titles),
                       .thread(thread))
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["  Fix the\nlogin   loop "], thread: thread, titles: titles),
                       .thread(thread), "white space is not a different title")
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Fix the login loop", "Fix the login loop"],
                                                 thread: thread, titles: titles),
                       .thread(thread), "the same thread pinned and in its project")
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Fix the login loop", "~/code/app"],
                                                 thread: thread, titles: titles),
                       .thread(thread), "a picker's current choice is not a thread")
    }

    func testAnotherThreadOnScreenIsNotWrittenInto() {
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Pricing page"], thread: thread, titles: titles), .other)
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["A ChatGPT chat"], thread: thread, titles: titles), .other)
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["fix the login loop"], thread: thread, titles: titles), .other,
                       "titles are compared as written")
    }

    func testWhenATitleCannotTellItIsNotSure() {
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: [], thread: thread, titles: titles), .unknown,
                       "nothing marked current: the sidebar is hidden, or a page with no thread")
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Same name"], thread: "019f8df8-abab-77c0-98db-1efea7d32b4d",
                                                 titles: titles), .unknown, "two threads share the title")
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Fix the login loop"], thread: "019f9999-0000-7000-8000-000000000000",
                                                 titles: titles), .unknown, "no title known for the thread")
        XCTAssertEqual(CodexDesktopComposer.view(shownTitles: ["Fix the login loop", "Pricing page"],
                                                 thread: thread, titles: titles), .unknown, "two threads marked current")
        XCTAssertTrue(CodexDesktopComposer.isCurrent("page"))
        XCTAssertTrue(CodexDesktopComposer.isCurrent("true"))
        XCTAssertFalse(CodexDesktopComposer.isCurrent("false"))
        XCTAssertFalse(CodexDesktopComposer.isCurrent(""))
    }

    // MARK: The box and its button

    func testTheComposerIsTheProseMirrorEditorAndNeverTheTerminal() {
        let area = "AXTextArea"
        XCTAssertTrue(CodexDesktopComposer.isComposer(role: area, classes: ["ProseMirror", "text-size-chat"]))
        XCTAssertFalse(CodexDesktopComposer.isComposer(role: area, classes: ["xterm-helper-textarea"]),
                       "the terminal pane runs what is typed as shell")
        XCTAssertFalse(CodexDesktopComposer.isComposer(role: area, classes: ["ProseMirror", "xterm"]))
        XCTAssertFalse(CodexDesktopComposer.isComposer(role: "AXTextField", classes: ["ProseMirror"]),
                       "the find bar and the browser's address field are fields")
        XCTAssertFalse(CodexDesktopComposer.isComposer(role: area, classes: []),
                       "a text area that isn't the editor is not guessed at")
    }

    func testTheSubmitButtonIsKnownByItsWholeLabelInTheAppsLanguages() {
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "Send"), .send)
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "Stop"), .stop)
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "Gửi"), .send, "Vietnamese")
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "Ngừng"), .stop)
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "送信"), .send, "Japanese")
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "Envoyer"), .send, "French")
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "Остановить"), .stop, "Russian")
        XCTAssertEqual(CodexDesktopComposer.buttonKind(label: "发送"), .send, "Simplified Chinese")
        XCTAssertNil(CodexDesktopComposer.buttonKind(label: "Send to cloud"))
        XCTAssertNil(CodexDesktopComposer.buttonKind(label: "Stop dictation"))
        XCTAssertNil(CodexDesktopComposer.buttonKind(label: "Transcribe and send"))
        XCTAssertNil(CodexDesktopComposer.buttonKind(label: "Steer"), "a running turn's, not Send")
        XCTAssertTrue(CodexDesktopComposer.sendLabels.isDisjoint(with: CodexDesktopComposer.stopLabels))
    }

    // MARK: Which threads are the app's

    func testAThreadIdIsReadFromItsRolloutAndItsTime() throws {
        XCTAssertEqual(CodexAppThread.threadID(inRolloutName: "rollout-2026-07-16T12-42-39-\(thread).jsonl"), thread)
        XCTAssertNil(CodexAppThread.threadID(inRolloutName: "rollout-2026-07-16T12-42-39.jsonl"))
        XCTAssertNil(CodexAppThread.threadID(inRolloutName: "notes-\(thread).jsonl"))
        let made = try XCTUnwrap(CodexAppThread.creationDate(ofThread: thread))
        XCTAssertEqual(made.timeIntervalSince1970, 1_784_180_577.674, accuracy: 0.001)
        XCTAssertNil(CodexAppThread.creationDate(ofThread: "6f1c2d3e-4f50-4172-8394-a5b6c7d8e9f0"), "a v4 id has no time")
    }

    func testOnlyTheAppsOwnThreadsAreAnsweredThere() throws {
        XCTAssertTrue(CodexAppThread.isAppOriginator("Codex Desktop"))
        XCTAssertTrue(CodexAppThread.isAppOriginator("codex_work_desktop"))
        XCTAssertFalse(CodexAppThread.isAppOriginator("codex-tui"), "a terminal's thread")
        XCTAssertFalse(CodexAppThread.isAppOriginator("codex_exec"))
        XCTAssertFalse(CodexAppThread.isAppOriginator("codex_vscode"))
        XCTAssertFalse(CodexAppThread.isAppOriginator(nil))
        XCTAssertTrue(CodexAppThread.isAppSource(kind: "vscode"), "the app server's own kind")
        XCTAssertTrue(CodexAppThread.isAppSource(kind: "chatgpt"))
        XCTAssertTrue(CodexAppThread.isAppSource(kind: nil))
        XCTAssertFalse(CodexAppThread.isAppSource(kind: "cli"))
        XCTAssertFalse(CodexAppThread.isAppSource(kind: "exec"))

        let sessions = FileManager.default.temporaryDirectory.appendingPathComponent("CodexAppThread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessions) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: try XCTUnwrap(CodexAppThread.creationDate(ofThread: thread)))
        let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", day.year!, day.month!, day.day!))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-2026-07-16T12-42-39-\(thread).jsonl")
        try #"{"type":"session_meta","payload":{"id":"\#(thread)","originator":"Codex Desktop","source":"vscode"}}"#
            .appending("\n{\"type\":\"event_msg\"}\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexAppThread.rollout(forThread: thread, under: sessions)?.lastPathComponent, file.lastPathComponent)
        XCTAssertEqual(CodexAppThread.originator(ofRollout: file), "Codex Desktop")
        XCTAssertNil(CodexAppThread.rollout(forThread: "019f8df4-863c-7952-8bf8-db01ae7c45e8", under: sessions))
    }

    func testARenameIsTheTitleTheSidebarShows() {
        let index = """
        {"id":"\(thread)","thread_name":"First name","updated_at":"2026-07-16T05:42:58Z"}
        {"id":"019f8df4-863c-7952-8bf8-db01ae7c45e8","thread_name":"Pricing page"}
        {"id":"\(thread)","thread_name":"Fix the login loop","updated_at":"2026-07-16T06:00:00Z"}
        not json
        """
        let titles = CodexAppThread.indexTitles(index)
        XCTAssertEqual(titles[thread], ["Fix the login loop"])
        XCTAssertEqual(titles["019f8df4-863c-7952-8bf8-db01ae7c45e8"], ["Pricing page"])
    }

    // MARK: Reach, and a click

    private func session(id: String = "codex.desktop", pid: pid_t? = nil, thread: String?) -> AgentSession {
        var session = AgentSession(id: id, name: "Fix the login loop", detail: "Complete", state: .success,
                                   waitingFor: nil, since: Date(), processID: pid)
        session.appThreadID = thread
        return session
    }

    func testACodexAppThreadIsReachedThroughTheApp() {
        XCTAssertEqual(SessionCommander.codexReach(session(thread: thread), installed: true), .codexApp(threadID: thread))
        XCTAssertNil(SessionCommander.codexReach(session(thread: thread), installed: false), "no app to open it in")
        XCTAssertNil(SessionCommander.codexReach(session(thread: nil), installed: true), "a terminal's thread")
        XCTAssertNil(SessionCommander.codexReach(session(thread: "not-a-thread"), installed: true))
        XCTAssertNil(SessionCommander.codexReach(session(id: "claude.x", pid: 4242, thread: thread), installed: true),
                     "a session with a process of its own is reached through that")
    }

    func testAClickOpensTheThreadByItsLink() {
        XCTAssertEqual(SessionFocus.link(for: session(thread: thread))?.absoluteString, "codex://threads/\(thread)")
        XCTAssertNil(SessionFocus.link(for: session(thread: nil)))
        XCTAssertNil(SessionFocus.link(for: session(pid: 4242, thread: thread)))
    }

    // MARK: The monitor

    private func catalogue(threadID: String, kind: String, at: Date) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-dev-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE local_thread_catalog (thread_id TEXT, display_title TEXT NOT NULL,
                source_updated_at REAL NOT NULL, source_kind TEXT);
            INSERT INTO local_thread_catalog VALUES ('\(threadID)', 'Fix the login loop', \(at.timeIntervalSince1970), '\(kind)');
            """, nil, nil, nil), SQLITE_OK)
        return url
    }

    @MainActor func testTheAppsNewestThreadCarriesItsIdToTheCard() throws {
        let now = Date()
        let app = try catalogue(threadID: thread, kind: "vscode", at: now.addingTimeInterval(-1))
        let cli = try catalogue(threadID: thread, kind: "cli", at: now.addingTimeInterval(-1))
        defer { try? FileManager.default.removeItem(at: app); try? FileManager.default.removeItem(at: cli) }
        let noState = URL(fileURLWithPath: "/nonexistent/state.sqlite")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")

        let shown = CodexActivityMonitor.read(stateStore: noState, desktopStore: app, staleAfter: 8, now: now,
                                              profile: .default(home: home))
        XCTAssertEqual(shown.first?.appThreadID, thread)
        XCTAssertNil(CodexActivityMonitor.read(stateStore: noState, desktopStore: cli, staleAfter: 8, now: now,
                                               profile: .default(home: home)).first?.appThreadID,
                     "a terminal's thread is not answered in the app")
        let other = CodexProfile(slug: "work", configDirectory: home.appendingPathComponent(".codex-work"))
        XCTAssertNil(CodexActivityMonitor.read(stateStore: noState, desktopStore: app, staleAfter: 8, now: now,
                                               profile: other).first?.appThreadID,
                     "the app keeps its threads in the default home only")
    }
}
