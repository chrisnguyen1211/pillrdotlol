import Foundation
import LidEffortCore

// MARK: - kitty

struct KittyWindow: Equatable, Hashable, Sendable {
    /// `kitten` (or `kitty`) from the running app's own bundle.
    let tool: String
    /// `unix:/…`, from `$KITTY_LISTEN_ON`.
    let socket: String
    /// From `$KITTY_WINDOW_ID`; nil when it has to be found with `ls`.
    let windowID: Int?
    /// The agent and its parents, to find the window by its processes.
    let ancestry: [pid_t]
}

/// kitty's remote control over its socket: `get-text` reads the screen,
/// `send-text --stdin` types exactly what it is given (stdin is not read
/// for escapes, unlike an argument), `focus-window` brings the window
/// forward, switching tabs. Only there when kitty.conf turns it on:
/// `allow_remote_control` (`yes`, `socket` or `socket-only`) with
/// `listen_on unix:…`, which is what puts `$KITTY_LISTEN_ON` in a pane.
enum Kitty {
    static func locate(pid: pid_t, bundleURL: URL?, facts: ProcessFacts, isSafe: (String) -> Bool,
                       config: String? = Kitty.userConfig()) -> KittyWindow? {
        // `$KITTY_LISTEN_ON`; where the agent's environment can't be read
        // (macOS 27 keeps a system shell's to itself), kitty's own
        // `--listen-on`, else kitty.conf's `listen_on` (to which kitty adds
        // `-<its pid>`), whichever socket is there.
        let socket: String
        if let told = facts.inherited("KITTY_LISTEN_ON", from: pid)?.value {
            guard told.hasPrefix("unix:") else { return nil }
            socket = told
        } else {
            // Guessed, so only one that is really there.
            let kitty = facts.ancestor(named: "kitty", of: pid)
            let guesses = kitty.map { listenOn(arguments: facts.environment($0.pid), config: config, kittyPID: $0.pid) } ?? []
            guard let found = guesses.compactMap({ $0 }).first(where: { candidate in
                candidate.hasPrefix("unix:") && (candidate.hasPrefix("unix:@")
                    || FileManager.default.fileExists(atPath: String(candidate.dropFirst("unix:".count))))
            }) else { return nil }
            socket = found
        }
        let preferred = [HostTools.inBundle(bundleURL, "Contents/MacOS/kitten"),
                         HostTools.inBundle(bundleURL, "Contents/MacOS/kitty")].compactMap { $0 }
        guard let tool = HostTools.resolve("kitten", preferring: preferred, isSafe: isSafe) else { return nil }
        let window = facts.inherited("KITTY_WINDOW_ID", from: pid).flatMap { Int($0.value) }
        return KittyWindow(tool: tool, socket: socket, windowID: window, ancestry: facts.ancestry(pid))
    }

    /// Sockets kitty may be listening on, from its own arguments and then
    /// its config: as given, and with `-<pid>` added as kitty does to a
    /// configured one.
    static func listenOn(arguments: [String], config: String?, kittyPID: pid_t) -> [String?] {
        var found: [String] = []
        for (index, argument) in arguments.enumerated() {
            if argument == "--listen-on", arguments.indices.contains(index + 1) { found.append(arguments[index + 1]) }
            if argument.hasPrefix("--listen-on=") { found.append(String(argument.dropFirst("--listen-on=".count))) }
        }
        for line in (config ?? "").split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == "listen_on" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            found.append(value.replacingOccurrences(of: "{kitty_pid}", with: String(kittyPID)))
            found.append(value + "-\(kittyPID)")
        }
        return found
    }

    static func userConfig() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".config")
        return try? String(contentsOf: base.appendingPathComponent("kitty/kitty.conf"), encoding: .utf8)
    }

    static func command(_ window: KittyWindow, _ arguments: [String], input: String? = nil) -> HostCommand {
        HostCommand(tool: window.tool, arguments: ["@", "--to", window.socket] + arguments, input: input)
    }

    static func match(_ id: Int) -> [String] { ["--match", "id:\(id)"] }

    static func list(_ window: KittyWindow) -> HostCommand { command(window, ["ls"]) }

    static func getText(_ window: KittyWindow, id: Int) -> HostCommand {
        command(window, ["get-text"] + match(id) + ["--extent", "screen"])
    }

    static func sendText(_ text: String, window: KittyWindow, id: Int) -> HostCommand {
        command(window, ["send-text"] + match(id) + ["--stdin"], input: text)
    }

    static func key(_ key: PaneWriter.Key, window: KittyWindow, id: Int) -> HostCommand {
        sendText(String(UnicodeScalar(PaneWriter.byte(key))), window: window, id: id)
    }

    static func focusWindow(_ window: KittyWindow, id: Int) -> HostCommand {
        command(window, ["focus-window"] + match(id))
    }

    /// The window the agent is in, from `kitten @ ls`: the one whose shell
    /// is up the agent's tree, or that lists the agent among its
    /// foreground processes.
    static func windowID(inList json: String, ancestry: [pid_t]) -> Int? {
        guard let data = json.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for osWindow in osWindows {
            for tab in osWindow["tabs"] as? [[String: Any]] ?? [] {
                for window in tab["windows"] as? [[String: Any]] ?? [] {
                    guard let id = (window["id"] as? NSNumber)?.intValue else { continue }
                    if let pid = (window["pid"] as? NSNumber)?.int32Value, ancestry.contains(pid) { return id }
                    let foreground = (window["foreground_processes"] as? [[String: Any]] ?? [])
                        .compactMap { ($0["pid"] as? NSNumber)?.int32Value }
                    if let agent = ancestry.first, foreground.contains(agent) { return id }
                }
            }
        }
        return nil
    }

    static func resolveID(_ window: KittyWindow, run: @escaping HostCommand.Runner) -> Int? {
        if let id = window.windowID { return id }
        guard let listed = run(list(window)), listed.succeeded else { return nil }
        return windowID(inList: listed.output, ancestry: window.ancestry)
    }

    static func write(_ line: String, stashKey: Character?, window: KittyWindow,
                      run: @escaping HostCommand.Runner,
                      pause: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.15) }) -> PaneWriter.Outcome {
        guard let id = resolveID(window, run: run) else { return .notFound }
        let io = PaneWriter.IO(
            read: {
                guard let screen = run(getText(window, id: id)), screen.succeeded else { return nil }
                return screen.output
            },
            type: { run(sendText($0, window: window, id: id))?.succeeded == true },
            press: { run(key($0, window: window, id: id))?.succeeded == true }
        )
        return PaneWriter.write(line, stashKey: stashKey, io: io, pause: pause)
    }

    static func press(_ key: PaneWriter.Key, window: KittyWindow, run: @escaping HostCommand.Runner) -> Bool {
        guard let id = resolveID(window, run: run) else { return false }
        return run(self.key(key, window: window, id: id))?.succeeded == true
    }

    static func focus(_ window: KittyWindow, run: @escaping HostCommand.Runner) -> Bool {
        guard let id = resolveID(window, run: run) else { return false }
        return run(focusWindow(window, id: id))?.succeeded == true
    }
}

// MARK: - WezTerm

struct WezTermPane: Equatable, Hashable, Sendable {
    /// `wezterm` from the running app's own bundle.
    let tool: String
    /// `$WEZTERM_UNIX_SOCKET`: the GUI instance the pane belongs to.
    let socket: String?
    /// `$WEZTERM_PANE`; nil when it has to be found by tty.
    let paneID: Int?
    let tty: String?
}

/// WezTerm's `wezterm cli`, which talks to the running GUI over its
/// socket, with no setting to turn on. `get-text` reads the screen,
/// `send-text --no-paste` types (from stdin, never parsed), `activate-tab`
/// and `activate-pane` bring the pane forward. `--no-auto-start` keeps it
/// from starting a server of its own when none answers.
enum WezTerm {
    struct Pane: Equatable {
        let paneID: Int
        let tabID: Int
        let tty: String?
    }

    static func locate(pid: pid_t, bundleURL: URL?, facts: ProcessFacts, isSafe: (String) -> Bool) -> WezTermPane? {
        let preferred = [HostTools.inBundle(bundleURL, "Contents/MacOS/wezterm")].compactMap { $0 }
        guard let tool = HostTools.resolve("wezterm", preferring: preferred, isSafe: isSafe) else { return nil }
        let pane = facts.inherited("WEZTERM_PANE", from: pid).flatMap { Int($0.value) }
        // `$WEZTERM_UNIX_SOCKET`; where the agent's environment can't be
        // read (macOS 27 keeps a system shell's to itself), the socket the
        // GUI the agent runs under opened for itself, `gui-sock-<its pid>`:
        // `wezterm cli` alone only tries the default `sock`.
        let socket = facts.inherited("WEZTERM_UNIX_SOCKET", from: pid)?.value
            ?? facts.ancestor(named: "wezterm-gui", of: pid).flatMap { guiSocket(pid: $0.pid) }
        let tty = facts.tty(pid)
        guard pane != nil || tty != nil else { return nil }
        return WezTermPane(tool: tool, socket: socket, paneID: pane, tty: tty)
    }

    /// The socket a WezTerm GUI process listens on, where WezTerm puts it.
    static func guiSocket(pid: pid_t, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].map(URL.init(fileURLWithPath:))
        let places = [runtime?.appendingPathComponent("wezterm"), home.appendingPathComponent(".local/share/wezterm")]
        return places.compactMap { $0?.appendingPathComponent("gui-sock-\(pid)").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func command(_ pane: WezTermPane, _ arguments: [String], input: String? = nil) -> HostCommand {
        HostCommand(tool: pane.tool, arguments: ["cli", "--no-auto-start"] + arguments,
                    environment: pane.socket.map { ["WEZTERM_UNIX_SOCKET": $0] } ?? [:], input: input)
    }

    static func list(_ pane: WezTermPane) -> HostCommand { command(pane, ["list", "--format", "json"]) }

    static func getText(_ pane: WezTermPane, id: Int) -> HostCommand {
        command(pane, ["get-text", "--pane-id", String(id)])
    }

    static func sendText(_ text: String, pane: WezTermPane, id: Int) -> HostCommand {
        command(pane, ["send-text", "--pane-id", String(id), "--no-paste"], input: text)
    }

    static func key(_ key: PaneWriter.Key, pane: WezTermPane, id: Int) -> HostCommand {
        sendText(String(UnicodeScalar(PaneWriter.byte(key))), pane: pane, id: id)
    }

    static func parseList(_ json: String) -> [Pane] {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let pane = (row["pane_id"] as? NSNumber)?.intValue,
                  let tab = (row["tab_id"] as? NSNumber)?.intValue else { return nil }
            let tty = (row["tty_name"] as? String).map(ProcessTable.normalizeTTY)
            return Pane(paneID: pane, tabID: tab, tty: tty)
        }
    }

    /// `$WEZTERM_PANE`'s pane unless its tty says otherwise; else the one
    /// on the agent's tty.
    static func match(_ panes: [Pane], pane: WezTermPane) -> Pane? {
        if let id = pane.paneID, let row = panes.first(where: { $0.paneID == id }),
           row.tty == nil || pane.tty == nil || row.tty == pane.tty {
            return row
        }
        guard let tty = pane.tty else { return nil }
        return panes.first { $0.tty == tty }
    }

    static func find(_ pane: WezTermPane, run: @escaping HostCommand.Runner) -> Pane? {
        guard let listed = run(list(pane)), listed.succeeded else { return nil }
        return match(parseList(listed.output), pane: pane)
    }

    static func write(_ line: String, stashKey: Character?, pane: WezTermPane,
                      run: @escaping HostCommand.Runner,
                      pause: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.15) }) -> PaneWriter.Outcome {
        guard let row = find(pane, run: run) else { return .notFound }
        let id = row.paneID
        let io = PaneWriter.IO(
            read: {
                guard let screen = run(getText(pane, id: id)), screen.succeeded else { return nil }
                return screen.output
            },
            type: { run(sendText($0, pane: pane, id: id))?.succeeded == true },
            press: { run(key($0, pane: pane, id: id))?.succeeded == true }
        )
        return PaneWriter.write(line, stashKey: stashKey, io: io, pause: pause)
    }

    static func press(_ key: PaneWriter.Key, pane: WezTermPane, run: @escaping HostCommand.Runner) -> Bool {
        guard let row = find(pane, run: run) else { return false }
        return run(self.key(key, pane: pane, id: row.paneID))?.succeeded == true
    }

    static func focus(_ pane: WezTermPane, run: @escaping HostCommand.Runner) -> Bool {
        guard let row = find(pane, run: run) else { return false }
        return PaneHosts.all([
            command(pane, ["activate-tab", "--tab-id", String(row.tabID)]),
            command(pane, ["activate-pane", "--pane-id", String(row.paneID)]),
        ], run: run)
    }
}
