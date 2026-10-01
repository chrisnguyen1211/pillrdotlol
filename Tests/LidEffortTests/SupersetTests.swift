import XCTest
import SQLite3
@testable import LidEffort

/// Superset as a place sessions run — against a made-up Superset home, so
/// nothing here reads or touches the real one.
final class SupersetTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("superset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("host/org1"), withIntermediateDirectories: true)
        setenv("SUPERSET_HOME_DIR", home.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("SUPERSET_HOME_DIR")
        try? FileManager.default.removeItem(at: home)
    }

    private func sql(_ url: URL, _ statements: [String]) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for statement in statements { XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK, statement) }
        sqlite3_close(db)
    }

    func testAPlaceIsReadFromThePanesEnvironment() {
        XCTAssertEqual(Superset.place(environment: ["PATH=/bin", "SUPERSET_WORKSPACE_ID=ws1", "SUPERSET_TAB_ID=tab-1", "SUPERSET_PANE_ID=pane-1"]),
                       Superset.Place(workspaceID: "ws1", stack: .v1(tabID: "tab-1", paneID: "pane-1")))
        XCTAssertEqual(Superset.place(environment: ["SUPERSET_WORKSPACE_ID=ws2", "SUPERSET_TERMINAL_ID=t9", "SUPERSET_TAB_ID=x", "SUPERSET_PANE_ID=y"]),
                       Superset.Place(workspaceID: "ws2", stack: .v2(terminalID: "t9")), "the new stack wins when both are there")
        XCTAssertNil(Superset.place(environment: ["TERM_PROGRAM=Apple_Terminal", "HOME=/Users/me"]))
        XCTAssertEqual(Superset.place(environment: ["SUPERSET_WORKSPACE_ID=w", "SUPERSET_WORKSPACE_NAME=ceck", "SUPERSET_TAB_ID=t", "SUPERSET_PANE_ID=p"])?.name,
                       "ceck", "the name Superset exported, for when its database is busy")
    }

    func testTheLinkOpensThatVeryTerminal() throws {
        let v1 = try XCTUnwrap(Superset.focusURL(.init(workspaceID: "ws1", stack: .v1(tabID: "tab-1", paneID: "pane-1"))))
        XCTAssertEqual(v1.absoluteString, "superset://workspace/ws1?tabId=tab-1&paneId=pane-1")
        let id = UUID()
        let v2 = try XCTUnwrap(Superset.focusURL(.init(workspaceID: "ws2", stack: .v2(terminalID: "t9")), requestID: id))
        XCTAssertEqual(v2.absoluteString, "superset://v2-workspace/ws2?terminalId=t9&focusRequestId=\(id.uuidString.lowercased())")
    }

    func testWorkspacesFromBothStacksNameTheSessionRow() {
        sql(home.appendingPathComponent("local.db"), [
            "CREATE TABLE workspaces (id text, name text, branch text, last_opened_at integer)",
            "INSERT INTO workspaces VALUES ('ws1', 'ceck', 'main', 10), ('ws0', 'default', 'feat/reddit', 5)",
        ])
        sql(home.appendingPathComponent("host/org1/host.db"), [
            "CREATE TABLE workspaces (id text, name text, branch text, archived_at integer)",
            "INSERT INTO workspaces VALUES ('ws2', 'invoices', 'feat/invoices', NULL), ('ws3', 'old', 'x', 99)",
            "CREATE TABLE terminal_sessions (id text, status text, last_attached_at integer)",
        ])
        let all = Superset.workspaces(now: Date().addingTimeInterval(3600))
        XCTAssertEqual(all["ws1"]?.name, "ceck")
        XCTAssertEqual(all["ws2"]?.branch, "feat/invoices")
        XCTAssertNil(all["ws3"], "archived workspaces are not listed")
        XCTAssertEqual(Superset.detail(for: all["ws1"]), "Superset · ceck · ⎇ main")
        XCTAssertEqual(Superset.detail(for: all["ws0"]), "Superset · ⎇ feat/reddit", "a workspace called default is named by its branch")
        XCTAssertEqual(Superset.detail(for: nil), "Superset")
    }

    func testTheOldStacksPaneInViewIsTheSelectedOneOfTheOpenWorkspace() throws {
        sql(home.appendingPathComponent("local.db"), [
            "CREATE TABLE workspaces (id text, name text, branch text, last_opened_at integer)",
            "INSERT INTO workspaces VALUES ('ws1', 'ceck', 'main', 20), ('ws2', 'other', 'dev', 10)",
        ])
        let state: [String: Any] = ["tabsState": [
            "activeTabIds": ["ws1": "tab-1", "ws2": "tab-9"],
            "focusedPaneIds": ["tab-1": "pane-1", "tab-9": "pane-9"],
        ]]
        try JSONSerialization.data(withJSONObject: state).write(to: home.appendingPathComponent("app-state.json"))
        let selected = Superset.Place(workspaceID: "ws1", stack: .v1(tabID: "tab-1", paneID: "pane-1"))
        XCTAssertTrue(Superset.isInView(selected, frontmostBundleID: Superset.bundleID))
        XCTAssertFalse(Superset.isInView(selected, frontmostBundleID: "com.apple.Terminal"), "Superset has to be in front")
        XCTAssertFalse(Superset.isInView(.init(workspaceID: "ws1", stack: .v1(tabID: "tab-1", paneID: "pane-2")),
                                         frontmostBundleID: Superset.bundleID), "another pane of the same tab")
        XCTAssertFalse(Superset.isInView(.init(workspaceID: "ws2", stack: .v1(tabID: "tab-9", paneID: "pane-9")),
                                         frontmostBundleID: Superset.bundleID), "a workspace that is not open")
    }

    func testTheNewStacksTerminalInViewIsTheLastAttached() {
        sql(home.appendingPathComponent("host/org1/host.db"), [
            "CREATE TABLE workspaces (id text, name text, branch text, archived_at integer)",
            "CREATE TABLE terminal_sessions (id text, status text, last_attached_at integer)",
            "INSERT INTO terminal_sessions VALUES ('t1', 'active', 100), ('t2', 'active', 300), ('t3', 'ended', 900)",
        ])
        XCTAssertTrue(Superset.isInView(.init(workspaceID: "w", stack: .v2(terminalID: "t2")), frontmostBundleID: Superset.bundleID))
        XCTAssertFalse(Superset.isInView(.init(workspaceID: "w", stack: .v2(terminalID: "t1")), frontmostBundleID: Superset.bundleID))
    }

    func testTheHostServiceIsFoundOnlyWhileItRuns() throws {
        let manifest = home.appendingPathComponent("host/org1/manifest.json")
        try JSONSerialization.data(withJSONObject: ["pid": getpid(), "endpoint": "http://127.0.0.1:4891", "authToken": "tok"]).write(to: manifest)
        XCTAssertEqual(Superset.host(), Superset.Host(endpoint: URL(string: "http://127.0.0.1:4891")!, token: "tok"))
        try JSONSerialization.data(withJSONObject: ["pid": 999_999, "endpoint": "http://127.0.0.1:4891", "authToken": "tok"]).write(to: manifest)
        XCTAssertNil(Superset.host(), "a manifest left behind by a dead service is not a service")
    }

    func testTheSendIsTheCLIsOwnCall() throws {
        let request = Superset.sendRequest(host: .init(endpoint: URL(string: "http://127.0.0.1:4891")!, token: "tok"),
                                           workspaceID: "ws2", terminalID: "t9", text: "/effort high")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:4891/trpc/terminal.send?batch=1")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let input = try XCTUnwrap((body["0"] as? [String: Any])?["json"] as? [String: Any])
        XCTAssertEqual(input["terminalId"] as? String, "t9")
        XCTAssertEqual(input["workspaceId"] as? String, "ws2")
        XCTAssertEqual(input["text"] as? String, "/effort high")
        XCTAssertEqual(input["submit"] as? Bool, true)
    }

    func testTheOldStackCannotBeTypedInto() async {
        let outcome = await Superset.send("/effort high", to: .init(workspaceID: "w", stack: .v1(tabID: "t", paneID: "p")))
        XCTAssertEqual(outcome, .notV2)
    }
}

/// Read-only, against the real Superset on this Mac, when a pid is named.
final class SupersetLiveTests: XCTestCase {
    func testALiveSession() throws {
        guard let raw = ProcessInfo.processInfo.environment["EFFORT_SUPERSET_PID"], let pid = Int32(raw) else { throw XCTSkip("no pid named") }
        let place = try XCTUnwrap(Superset.place(of: pid))
        let workspace = Superset.workspace(id: place.workspaceID)
        print("SUPERSET place=\(place) detail=\(Superset.detail(for: workspace)) link=\(Superset.focusURL(place)?.absoluteString ?? "-") host=\(Superset.host() != nil)")
    }
}
