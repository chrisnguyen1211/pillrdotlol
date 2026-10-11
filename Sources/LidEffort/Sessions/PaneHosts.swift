import Foundation
import LidEffortCore

/// A session's pane in a host that pillr can read and type into from
/// outside, in the background: a terminal multiplexer (tmux, Zellij), which
/// works whatever terminal it is shown in, or a terminal with a remote
/// control (kitty, WezTerm).
enum PaneHost: Equatable, Hashable, Sendable {
    case tmux(TmuxPane)
    case zellij(ZellijPane)
    case kitty(KittyWindow)
    case wezterm(WezTermPane)

    /// What to call it on the card.
    var name: String {
        switch self {
        case .tmux: return "tmux"
        case .zellij: return "Zellij"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        }
    }

    /// A multiplexer has no window of its own: it is shown by some terminal
    /// (its client), and nothing else can be pasted into in its place.
    var isMultiplexer: Bool {
        switch self {
        case .tmux, .zellij: return true
        case .kitty, .wezterm: return false
        }
    }
}

/// Where focusing a pane got to: chosen in its host, and, for a
/// multiplexer, the client showing it, whose terminal is the app to raise.
struct PaneFocus: Equatable, Sendable {
    let selected: Bool
    var clientPID: pid_t? = nil
    var clientTTY: String? = nil
}

enum PaneHosts {
    static let kittyBundleID = "net.kovidgoyal.kitty"
    static let weztermBundleID = "com.github.wez.wezterm"

    /// The pane a process runs in, from its own process tree and the
    /// variables these hosts export into every pane. A multiplexer wins
    /// over the terminal around it: tmux in kitty is typed into by tmux.
    static func locate(pid: pid_t, bundleID: String?, bundleURL: URL?,
                       facts: ProcessFacts = .live,
                       isSafe: (String) -> Bool = HostTools.isSafeExecutable,
                       run: @escaping HostCommand.Runner = HostCommand.live) -> PaneHost? {
        if let pane = Tmux.locate(pid: pid, facts: facts, isSafe: isSafe) { return .tmux(pane) }
        if let pane = Zellij.locate(pid: pid, facts: facts, isSafe: isSafe, run: run) { return .zellij(pane) }
        switch bundleID {
        case kittyBundleID:
            return Kitty.locate(pid: pid, bundleURL: bundleURL, facts: facts, isSafe: isSafe).map(PaneHost.kitty)
        case weztermBundleID:
            return WezTerm.locate(pid: pid, bundleURL: bundleURL, facts: facts, isSafe: isSafe).map(PaneHost.wezterm)
        default:
            return nil
        }
    }

    static func write(_ line: String, stashKey: Character?, to host: PaneHost,
                      run: @escaping HostCommand.Runner = HostCommand.live) -> PaneWriter.Outcome {
        switch host {
        case .tmux(let pane): return Tmux.write(line, stashKey: stashKey, pane: pane, run: run)
        case .zellij(let pane): return Zellij.write(line, stashKey: stashKey, pane: pane, run: run)
        case .kitty(let window): return Kitty.write(line, stashKey: stashKey, window: window, run: run)
        case .wezterm(let pane): return WezTerm.write(line, stashKey: stashKey, pane: pane, run: run)
        }
    }

    /// Esc, pressed in the pane itself: no window has to come forward.
    static func stop(_ host: PaneHost, run: @escaping HostCommand.Runner = HostCommand.live) -> Bool {
        switch host {
        case .tmux(let pane): return Tmux.press(.escape, pane: pane, run: run)
        case .zellij(let pane): return Zellij.press(.escape, pane: pane, run: run)
        case .kitty(let window): return Kitty.press(.escape, window: window, run: run)
        case .wezterm(let pane): return WezTerm.press(.escape, pane: pane, run: run)
        }
    }

    static func focus(_ host: PaneHost, run: @escaping HostCommand.Runner = HostCommand.live,
                      facts: ProcessFacts = .live) -> PaneFocus {
        switch host {
        case .tmux(let pane): return Tmux.focus(pane, run: run)
        case .zellij(let pane): return Zellij.focus(pane, run: run, facts: facts)
        case .kitty(let window): return PaneFocus(selected: Kitty.focus(window, run: run))
        case .wezterm(let pane): return PaneFocus(selected: WezTerm.focus(pane, run: run))
        }
    }

    /// Commands run one after another, all of which must succeed.
    static func all(_ commands: [HostCommand], run: @escaping HostCommand.Runner) -> Bool {
        for command in commands {
            guard run(command)?.succeeded == true else { return false }
        }
        return true
    }
}

// MARK: - tmux

struct TmuxPane: Equatable, Hashable, Sendable {
    let tool: String
    /// The server's socket, from `$TMUX`; nil for the default one.
    let socket: String?
    /// `%3`, from `$TMUX_PANE`; nil when it has to be found by tty.
    let paneID: String?
    /// The agent's terminal: the pane's own `pane_tty`.
    let tty: String?
    /// The agent and its parents, for a pane found by its shell's pid.
    let ancestry: [pid_t]
}

/// tmux, through its own command line: `capture-pane` reads the screen,
/// `send-keys` types, `select-window`/`select-pane` and `switch-client`
/// bring the pane forward in the client showing it.
enum Tmux {
    struct Pane: Equatable {
        let id: String
        let tty: String
        let pid: pid_t
        let windowID: String
        /// Copy mode or another mode: keys would go to the mode, not the agent.
        let inMode: Bool
        let session: String
    }

    struct Client: Equatable {
        let pid: pid_t
        let tty: String
        let activity: Int
        let session: String
    }

    /// Space-separated, the free-text session name last.
    static let paneFormat = "#{pane_id} #{pane_tty} #{pane_pid} #{window_id} #{pane_in_mode} #{session_name}"
    static let clientFormat = "#{client_pid} #{client_tty} #{client_activity} #{session_name}"

    static func locate(pid: pid_t, facts: ProcessFacts, isSafe: (String) -> Bool) -> TmuxPane? {
        let ancestry = facts.ancestry(pid)
        var socket: String?
        var serverPID: pid_t?
        var paneID: String?
        // `$TMUX` names the server; it counts only if that server really
        // is up the tree: a terminal started from a tmux shell inherits
        // it without running in tmux at all.
        if let tmux = facts.inherited("TMUX", from: pid), let parsed = parseTMUX(tmux.value),
           ancestry.dropFirst().contains(parsed.serverPID) {
            socket = parsed.socket
            serverPID = parsed.serverPID
            if let pane = facts.inherited("TMUX_PANE", from: pid)?.value, isPaneID(pane) { paneID = pane }
        } else if let server = facts.ancestor(named: "tmux", of: pid) {
            serverPID = server.pid
        } else {
            return nil
        }
        let serverPath = serverPID.flatMap { facts.executablePath($0) }
        let preferred = serverPath.map { ($0 as NSString).lastPathComponent == "tmux" ? [$0] : [] } ?? []
        guard let tool = HostTools.resolve("tmux", preferring: preferred, isSafe: isSafe) else { return nil }
        return TmuxPane(tool: tool, socket: socket, paneID: paneID, tty: facts.tty(pid), ancestry: ancestry)
    }

    /// `$TMUX` is `socket,server-pid,session`: split from the end, as a
    /// socket path may itself hold a comma.
    static func parseTMUX(_ value: String) -> (socket: String, serverPID: pid_t)? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3, let pid = pid_t(parts[parts.count - 2]), pid > 1 else { return nil }
        let socket = parts.dropLast(2).joined(separator: ",")
        guard socket.hasPrefix("/") else { return nil }
        return (socket, pid)
    }

    static func isPaneID(_ value: String) -> Bool {
        value.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil
    }

    // MARK: Commands

    static func base(_ pane: TmuxPane) -> [String] { pane.socket.map { ["-S", $0] } ?? [] }

    static func listPanes(_ pane: TmuxPane) -> HostCommand {
        HostCommand(tool: pane.tool, arguments: base(pane) + ["list-panes", "-a", "-F", paneFormat])
    }

    static func capture(_ pane: TmuxPane, target: String) -> HostCommand {
        HostCommand(tool: pane.tool, arguments: base(pane) + ["capture-pane", "-p", "-t", target])
    }

    /// The text as typed (`-l`), after `--` so a leading dash is text. tmux
    /// reads an argument ending in `;` as the end of a command and drops
    /// the `;`, so trailing semicolons go as their byte instead.
    static func type(_ text: String, pane: TmuxPane, target: String) -> [HostCommand] {
        let body = String(text.reversed().drop { $0 == ";" }.reversed())
        let semicolons = text.count - body.count
        var commands: [HostCommand] = []
        if !body.isEmpty {
            commands.append(HostCommand(tool: pane.tool,
                                        arguments: base(pane) + ["send-keys", "-t", target, "-l", "--", body]))
        }
        if semicolons > 0 {
            commands.append(HostCommand(tool: pane.tool,
                                        arguments: base(pane) + ["send-keys", "-t", target, "-H"]
                                            + Array(repeating: "3b", count: semicolons)))
        }
        return commands
    }

    static func key(_ key: PaneWriter.Key, pane: TmuxPane, target: String) -> HostCommand {
        let keys: [String]
        switch key {
        case .enter: keys = ["Enter"]
        case .escape: keys = ["Escape"]
        case .control: keys = ["-H", String(format: "%02x", PaneWriter.byte(key))]
        }
        return HostCommand(tool: pane.tool, arguments: base(pane) + ["send-keys", "-t", target] + keys)
    }

    // MARK: Reading tmux's answers

    static func parsePanes(_ output: String) -> [Pane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, isPaneID(fields[0]), let pid = pid_t(fields[2]) else { return nil }
            return Pane(id: fields[0], tty: ProcessTable.normalizeTTY(fields[1]), pid: pid, windowID: fields[3],
                        inMode: fields[4] != "0" && !fields[4].isEmpty, session: fields[5])
        }
    }

    static func parseClients(_ output: String) -> [Client] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let pid = pid_t(fields[0]), pid > 0 else { return nil }
            return Client(pid: pid, tty: fields[1], activity: Int(fields[2]) ?? 0, session: fields[3])
        }
    }

    /// The agent's pane: the one `$TMUX_PANE` names when its tty agrees,
    /// else the one on the agent's tty, else the one whose shell is the
    /// agent's parent.
    static func match(_ panes: [Pane], pane: TmuxPane) -> Pane? {
        if let id = pane.paneID, let row = panes.first(where: { $0.id == id }),
           pane.tty == nil || row.tty == pane.tty {
            return row
        }
        if let tty = pane.tty, let row = panes.first(where: { $0.tty == tty }) { return row }
        return panes.first { pane.ancestry.contains($0.pid) }
    }

    /// The client to show it in: one already on the pane's session, the
    /// most recently used; else the most recent client, switched over.
    static func client(for session: String, among clients: [Client]) -> (client: Client, switchTo: Bool)? {
        if let on = clients.filter({ $0.session == session }).max(by: { $0.activity < $1.activity }) {
            return (on, false)
        }
        return clients.max(by: { $0.activity < $1.activity }).map { ($0, true) }
    }

    // MARK: Doing it

    static func write(_ line: String, stashKey: Character?, pane: TmuxPane,
                      run: @escaping HostCommand.Runner,
                      pause: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.15) }) -> PaneWriter.Outcome {
        guard let listed = run(listPanes(pane)), listed.succeeded else { return .unreadable }
        guard let row = match(parsePanes(listed.output), pane: pane) else { return .notFound }
        if row.inMode { return .busy }
        let target = row.id
        let io = PaneWriter.IO(
            read: {
                guard let screen = run(capture(pane, target: target)), screen.succeeded else { return nil }
                return screen.output
            },
            type: { PaneHosts.all(type($0, pane: pane, target: target), run: run) },
            press: { run(key($0, pane: pane, target: target))?.succeeded == true }
        )
        return PaneWriter.write(line, stashKey: stashKey, io: io, pause: pause)
    }

    static func press(_ key: PaneWriter.Key, pane: TmuxPane, run: @escaping HostCommand.Runner) -> Bool {
        guard let listed = run(listPanes(pane)), listed.succeeded,
              let row = match(parsePanes(listed.output), pane: pane), !row.inMode else { return false }
        return run(self.key(key, pane: pane, target: row.id))?.succeeded == true
    }

    /// The pane made current in its window and session, and the client
    /// that will show it, switched to that session if none was on it.
    static func focus(_ pane: TmuxPane, run: @escaping HostCommand.Runner) -> PaneFocus {
        guard let listed = run(listPanes(pane)), listed.succeeded,
              let row = match(parsePanes(listed.output), pane: pane) else { return PaneFocus(selected: false) }
        var selected = PaneHosts.all([
            HostCommand(tool: pane.tool, arguments: base(pane) + ["select-window", "-t", row.id]),
            HostCommand(tool: pane.tool, arguments: base(pane) + ["select-pane", "-t", row.id]),
        ], run: run)
        let clients = run(HostCommand(tool: pane.tool, arguments: base(pane) + ["list-clients", "-F", clientFormat]))
        guard let clients, clients.succeeded,
              let (client, switchTo) = client(for: row.session, among: parseClients(clients.output)) else {
            return PaneFocus(selected: selected)
        }
        if switchTo {
            let switched = HostCommand(tool: pane.tool,
                                       arguments: base(pane) + ["switch-client", "-c", client.tty, "-t", row.id])
            selected = selected && run(switched)?.succeeded == true
        }
        return PaneFocus(selected: selected, clientPID: client.pid, clientTTY: ProcessTable.normalizeTTY(client.tty))
    }
}

// MARK: - Zellij

struct ZellijPane: Equatable, Hashable, Sendable {
    let tool: String
    let session: String
    /// `3` or `terminal_3`, from `$ZELLIJ_PANE_ID`.
    let paneID: String
    /// `$ZELLIJ_SOCKET_DIR`, when the server was started with one.
    let socketDir: String?
}

/// Zellij 0.44 and newer, through `zellij --session … action …`: every
/// action used here takes `--pane-id`, so nothing depends on which pane
/// has the focus. Older Zellij has no way to name a pane and refuses.
enum Zellij {
    static func locate(pid: pid_t, facts: ProcessFacts, isSafe: (String) -> Bool,
                       run: @escaping HostCommand.Runner = HostCommand.live) -> ZellijPane? {
        guard let server = facts.ancestor(named: "zellij", of: pid),
              let tool = HostTools.resolve("zellij", preferring: [server.path], isSafe: isSafe) else { return nil }
        if let session = facts.inherited("ZELLIJ_SESSION_NAME", from: pid)?.value,
           let paneID = facts.inherited("ZELLIJ_PANE_ID", from: pid)?.value, isPaneID(paneID), !session.hasPrefix("-") {
            let socketDir = facts.inherited("ZELLIJ_SOCKET_DIR", from: pid)?.value
            return ZellijPane(tool: tool, session: session, paneID: paneID, socketDir: socketDir)
        }
        // macOS 27 keeps another process's environment to itself: the
        // session is then the server's own socket name, and the pane the
        // one running the agent's command in the agent's folder.
        guard let session = sessionName(serverArguments: facts.environment(server.pid)) else { return nil }
        let probe = ZellijPane(tool: tool, session: session, paneID: "0", socketDir: nil)
        guard let listed = run(command(probe, ["list-panes", "--all", "--json"])), listed.succeeded else { return nil }
        let arguments = Array(facts.environment(pid).dropFirst())
        guard let paneID = pane(in: listed.output, arguments: arguments, cwd: SessionFocus.currentDirectory(of: pid)) else {
            return nil
        }
        return ZellijPane(tool: tool, session: session, paneID: paneID, socketDir: nil)
    }

    /// `zellij --server /…/zellij-501/contract_version_1/<session>`.
    static func sessionName(serverArguments: [String]) -> String? {
        guard let index = serverArguments.firstIndex(of: "--server"), serverArguments.indices.contains(index + 1) else {
            return nil
        }
        let name = (serverArguments[index + 1] as NSString).lastPathComponent
        return name.isEmpty || name.hasPrefix("-") ? nil : name
    }

    /// The one terminal pane whose running command is the process's own
    /// (its arguments, as `pane_command` writes them) and, if told, whose
    /// folder is the process's. `terminal_<id>`.
    static func pane(in json: String, arguments: [String], cwd: String?) -> String? {
        guard let data = json.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let command = arguments.joined(separator: " ")
        let matches = panes.filter { pane in
            guard (pane["is_plugin"] as? Bool) == false, (pane["exited"] as? Bool) != true,
                  let running = pane["pane_command"] as? String, !running.isEmpty else { return false }
            return running == command || command.hasSuffix(" " + running) || running.hasSuffix(" " + command) || running == arguments.last
        }
        let narrowed = cwd.map { folder in matches.filter { ($0["pane_cwd"] as? String) == folder } } ?? matches
        let pick = narrowed.count == 1 ? narrowed : (matches.count == 1 ? matches : [])
        guard let id = pick.first?["id"] as? Int else { return nil }
        return "terminal_\(id)"
    }

    static func isPaneID(_ value: String) -> Bool {
        value.range(of: #"^(terminal_)?[0-9]+$"#, options: .regularExpression) != nil
    }

    static func command(_ pane: ZellijPane, _ action: [String], input: String? = nil) -> HostCommand {
        HostCommand(tool: pane.tool, arguments: ["--session=\(pane.session)", "action"] + action,
                    environment: pane.socketDir.map { ["ZELLIJ_SOCKET_DIR": $0] } ?? [:], input: input)
    }

    static func dump(_ pane: ZellijPane) -> HostCommand {
        command(pane, ["dump-screen", "--pane-id", pane.paneID])
    }

    static func type(_ text: String, pane: ZellijPane) -> HostCommand {
        command(pane, ["write-chars", "--pane-id", pane.paneID, "--", text])
    }

    static func key(_ key: PaneWriter.Key, pane: ZellijPane) -> HostCommand {
        command(pane, ["write", "--pane-id", pane.paneID, String(PaneWriter.byte(key))])
    }

    static func write(_ line: String, stashKey: Character?, pane: ZellijPane,
                      run: @escaping HostCommand.Runner,
                      pause: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.15) }) -> PaneWriter.Outcome {
        let io = PaneWriter.IO(
            read: {
                guard let screen = run(dump(pane)), screen.succeeded else { return nil }
                return screen.output
            },
            type: { run(type($0, pane: pane))?.succeeded == true },
            press: { run(key($0, pane: pane))?.succeeded == true }
        )
        return PaneWriter.write(line, stashKey: stashKey, io: io, pause: pause)
    }

    static func press(_ key: PaneWriter.Key, pane: ZellijPane, run: @escaping HostCommand.Runner) -> Bool {
        run(self.key(key, pane: pane))?.succeeded == true
    }

    /// The pane focused in its session, and the one Zellij client running
    /// in a terminal that can be told to be that session's.
    static func focus(_ pane: ZellijPane, run: @escaping HostCommand.Runner, facts: ProcessFacts) -> PaneFocus {
        let selected = run(command(pane, ["focus-pane-id", pane.paneID]))?.succeeded == true
        guard let ps = run(HostCommand(tool: "/bin/ps", arguments: ["-axo", "pid=,ppid=,tty=,comm="])),
              ps.succeeded else { return PaneFocus(selected: selected) }
        let client = self.client(of: pane.session, in: ProcessTable(psOutput: ps.output), facts: facts)
        return PaneFocus(selected: selected, clientPID: client?.pid, clientTTY: client?.tty)
    }

    /// Zellij clients are the `zellij` processes with a terminal (the
    /// server has none). One alone is the one; among several, the one
    /// started for this session by name.
    static func client(of session: String, in table: ProcessTable, facts: ProcessFacts) -> (pid: pid_t, tty: String)? {
        let clients = table.rows.filter { row in
            row.tty != "??" && (row.command as NSString).lastPathComponent == "zellij"
        }
        if clients.count == 1, let only = clients.first { return (only.pid, only.tty) }
        let named = clients.filter { row in
            let arguments = facts.environment(row.pid)
            return arguments.contains(session) || arguments.contains("--session=" + session)
        }
        guard named.count == 1, let one = named.first else { return nil }
        return (one.pid, one.tty)
    }
}

