import AppKit
import Foundation
import OSLog
import SQLite3

/// Superset (superset.sh) as a place sessions run: which workspace and
/// terminal a Claude process sits in, that workspace's name and branch, a
/// link that takes you to it, whether it is the one you are looking at, and
/// — through its host service, where one runs — typing into it.
///
/// Superset keeps two terminal stacks side by side. The older one (v1) keeps
/// its state in `local.db` and `app-state.json` and has no supported way to
/// type into a pane; the newer one (v2) runs a local host service whose
/// `terminal.send` its own CLI uses. Everything here is read-only apart from
/// that one call, and every schema read is defensive: these are Superset's
/// internals, not an API, and a failed read only means less is shown.
enum Superset {
    static let bundleID = "com.superset.desktop"
    private static let log = Logger(subsystem: "lol.spyx.app", category: "superset")

    static var home: URL {
        if let path = ProcessInfo.processInfo.environment["SUPERSET_HOME_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".superset")
    }

    // MARK: Where a process sits

    struct Place: Equatable, Hashable {
        enum Stack: Equatable, Hashable {
            case v1(tabID: String, paneID: String)
            case v2(terminalID: String)
        }
        let workspaceID: String
        let stack: Stack
        /// The workspace's name as Superset exported it into the pane — what
        /// is shown when its database cannot be read at that moment.
        var name: String? = nil
    }

    /// From a process's environment — `KEY=VALUE` strings, as the kernel
    /// hands them over. Superset exports these into every pane it starts.
    static func place(environment: [String]) -> Place? {
        var env: [String: String] = [:]
        for entry in environment {
            guard let eq = entry.firstIndex(of: "="), entry.hasPrefix("SUPERSET_") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        guard let workspace = env["SUPERSET_WORKSPACE_ID"], !workspace.isEmpty else { return nil }
        let name = env["SUPERSET_WORKSPACE_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        if let terminal = env["SUPERSET_TERMINAL_ID"], !terminal.isEmpty {
            return Place(workspaceID: workspace, stack: .v2(terminalID: terminal), name: name)
        }
        if let tab = env["SUPERSET_TAB_ID"], let pane = env["SUPERSET_PANE_ID"], !tab.isEmpty, !pane.isEmpty {
            return Place(workspaceID: workspace, stack: .v1(tabID: tab, paneID: pane), name: name)
        }
        return nil
    }

    private static var placeCache: [pid_t: Place?] = [:]
    private static let cacheLock = NSLock()

    /// A process's place, read once per pid — the environment a process was
    /// started with does not change.
    static func place(of pid: pid_t) -> Place? {
        cacheLock.lock()
        if let cached = placeCache[pid] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let found = place(environment: TerminalTabFocus.environment(of: pid))
        cacheLock.lock()
        placeCache[pid] = found
        cacheLock.unlock()
        return found
    }

    // MARK: The workspace

    struct Workspace: Equatable {
        let id: String
        let name: String
        let branch: String
    }

    private static var workspaceCache: (at: Date, all: [String: Workspace])?
    private static let workspaceTTL: TimeInterval = 30

    /// Every workspace Superset knows, from both stacks, cached for half a
    /// minute: the session list rescans far more often than names change.
    static func workspaces(now: Date = Date()) -> [String: Workspace] {
        cacheLock.lock()
        if let cache = workspaceCache, now.timeIntervalSince(cache.at) < workspaceTTL {
            cacheLock.unlock()
            return cache.all
        }
        cacheLock.unlock()
        var all: [String: Workspace] = [:]
        for row in query(home.appendingPathComponent("local.db"), "SELECT id, name, branch FROM workspaces") {
            if row.count == 3 { all[row[0]] = Workspace(id: row[0], name: row[1], branch: row[2]) }
        }
        for db in hostDatabases() {
            for row in query(db, "SELECT id, name, branch FROM workspaces WHERE archived_at IS NULL") where row.count == 3 {
                all[row[0]] = Workspace(id: row[0], name: row[1], branch: row[2])
            }
        }
        // Nothing read is not the same as nothing there — the database may
        // have been busy — so an empty answer is not kept.
        if !all.isEmpty {
            cacheLock.lock()
            workspaceCache = (now, all)
            cacheLock.unlock()
        }
        return all
    }

    static func workspace(id: String) -> Workspace? { workspaces()[id] }

    /// The line a session row shows: "Superset · ceck · ⎇ main".
    static func detail(for workspace: Workspace?) -> String {
        guard let workspace else { return "Superset" }
        let name = workspace.name.isEmpty || workspace.name == "default" ? nil : workspace.name
        return ["Superset", name, workspace.branch.isEmpty ? nil : "⎇ \(workspace.branch)"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A Claude session, labelled with its Superset workspace when it runs
    /// in one; any other session is returned as it came.
    static func labelled(_ session: AgentSession) -> AgentSession {
        guard let pid = session.processID, let place = place(of: pid) else { return session }
        let known = workspace(id: place.workspaceID)
            ?? place.name.map { Workspace(id: place.workspaceID, name: $0, branch: "") }
        return AgentSession(id: session.id, name: session.name,
                            detail: detail(for: known),
                            state: session.state, waitingFor: session.waitingFor,
                            since: session.since, processID: pid, doing: session.doing, tokens: session.tokens)
            .keepingModel(of: session)
    }

    // MARK: Going there

    /// The deep link that opens that workspace with that terminal in front —
    /// the one Superset's own CLI builds.
    static func focusURL(_ place: Place, requestID: UUID = UUID()) -> URL? {
        var components = URLComponents()
        components.scheme = "superset"
        switch place.stack {
        case .v1(let tab, let pane):
            components.host = "workspace"
            components.path = "/\(place.workspaceID)"
            components.queryItems = [URLQueryItem(name: "tabId", value: tab), URLQueryItem(name: "paneId", value: pane)]
        case .v2(let terminal):
            components.host = "v2-workspace"
            components.path = "/\(place.workspaceID)"
            components.queryItems = [URLQueryItem(name: "terminalId", value: terminal),
                                     URLQueryItem(name: "focusRequestId", value: requestID.uuidString.lowercased())]
        }
        return components.url
    }

    @discardableResult
    static func focus(pid: pid_t) -> Bool {
        guard let place = place(of: pid), let url = focusURL(place) else { return false }
        log.notice("focus \(url.absoluteString, privacy: .public)")
        return NSWorkspace.shared.open(url)
    }

    // MARK: In view

    /// Whether this is the terminal you are looking at: Superset in front,
    /// its workspace the one open, and — in the old stack — its tab and pane
    /// the selected ones; in the new, the terminal last attached to a view.
    static func isInView(_ place: Place, frontmostBundleID: String?) -> Bool {
        guard frontmostBundleID == bundleID else { return false }
        switch place.stack {
        case .v1(let tab, let pane):
            let active = query(home.appendingPathComponent("local.db"),
                               "SELECT id FROM workspaces ORDER BY last_opened_at DESC LIMIT 1").first?.first
            guard active == place.workspaceID else { return false }
            guard let data = try? Data(contentsOf: home.appendingPathComponent("app-state.json")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabs = state["tabsState"] as? [String: Any] else { return false }
            guard let selection = v1Selection(tabsState: tabs, workspaceID: place.workspaceID) else { return false }
            return selection == (tab, pane)
        case .v2(let terminal):
            for db in hostDatabases() {
                let latest = query(db, "SELECT id FROM terminal_sessions WHERE status = 'active' ORDER BY last_attached_at DESC LIMIT 1").first?.first
                if latest == terminal { return true }
            }
            return false
        }
    }

    /// The old stack's selection for a workspace: its active tab, and that
    /// tab's focused pane.
    static func v1Selection(tabsState: [String: Any], workspaceID: String) -> (String, String)? {
        guard let tab = (tabsState["activeTabIds"] as? [String: String])?[workspaceID],
              let pane = (tabsState["focusedPaneIds"] as? [String: String])?[tab] else { return nil }
        return (tab, pane)
    }

    // MARK: Typing, through the host service

    struct Host: Equatable {
        let endpoint: URL
        let token: String
    }

    /// The running host service, from its manifest — which exists only while
    /// it runs, and whose pid is checked in case it outlived its process.
    static func host() -> Host? {
        let root = home.appendingPathComponent("host")
        let orgs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for org in orgs {
            let url = root.appendingPathComponent(org).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let endpoint = (manifest["endpoint"] as? String).flatMap(URL.init(string:)),
                  let token = manifest["authToken"] as? String else { continue }
            if let pid = (manifest["pid"] as? NSNumber)?.int32Value, kill(pid, 0) != 0 { continue }
            return Host(endpoint: endpoint, token: token)
        }
        return nil
    }

    /// `terminal.send`, as the CLI's tRPC client posts it: a batch of one,
    /// superjson-wrapped, Enter pressed after the text.
    static func sendRequest(host: Host, workspaceID: String, terminalID: String, text: String) -> URLRequest {
        var url = host.endpoint.appendingPathComponent("trpc").appendingPathComponent("terminal.send")
        url = URL(string: url.absoluteString + "?batch=1") ?? url
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
        request.setValue("lid-effort", forHTTPHeaderField: "x-superset-client")
        let input: [String: Any] = ["terminalId": terminalID, "workspaceId": workspaceID, "text": text, "submit": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["0": ["json": input]])
        return request
    }

    enum SendOutcome: Equatable {
        case sent
        case notV2
        case noHost
        case failed(String)
    }

    /// Types `text` and Enter into the session's terminal. Only the new
    /// stack can take it; the old one has no supported way in.
    static func send(_ text: String, to place: Place) async -> SendOutcome {
        guard case .v2(let terminal) = place.stack else { return .notV2 }
        guard let host = host() else { return .noHost }
        let request = sendRequest(host: host, workspaceID: place.workspaceID, terminalID: terminal, text: text)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                log.error("terminal.send \(status, privacy: .public): \(body, privacy: .public)")
                return .failed("HTTP \(status)")
            }
            return .sent
        } catch {
            log.error("terminal.send failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Reading its databases

    static func hostDatabases() -> [URL] {
        let root = home.appendingPathComponent("host")
        let orgs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return orgs.map { root.appendingPathComponent($0).appendingPathComponent("host.db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Rows as strings, read-only. Opened without `immutable`, so the newest
    /// writes still in the write-ahead log are seen; never written to.
    static func query(_ url: URL, _ sql: String) -> [[String]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = sqlite3_column_count(statement)
            rows.append((0..<count).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return rows
    }
}
