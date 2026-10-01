import Foundation

public struct ProcessRow: Equatable {
    public let pid: Int32
    public let ppid: Int32
    /// Normalized tty name without a `/dev/` prefix, or `??` for none.
    public let tty: String
    public let command: String

    public init(pid: Int32, ppid: Int32, tty: String, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.command = command
    }
}

/// One interactive coding-agent CLI attached to a terminal.
public struct InteractiveSession: Equatable {
    public let pid: Int32
    public let tty: String
    /// Executable name: "claude", "codex", "grok", …
    public let agent: String
    /// Name of the .app bundle that owns the tty ("Terminal", "Claude", …),
    /// or nil when no ancestor lives inside an .app (ssh, tmux, bare login).
    public let host: String?

    public init(pid: Int32, tty: String, agent: String, host: String?) {
        self.pid = pid
        self.tty = tty
        self.agent = agent
        self.host = host
    }
}

/// A parsed snapshot of `ps -axo pid=,ppid=,tty=,comm=`.
///
/// Parsing is whitespace-tolerant on purpose: `ps` right-aligns pids with
/// leading spaces and pads columns with runs of spaces, and `comm` itself
/// can contain spaces ("Claude Helper"). Splitting on every run of spaces
/// and re-joining the tail is the only shape that survives all three.
public struct ProcessTable {
    /// Agent CLIs worth tracking as sessions. Only claude/codex/grok have
    /// effort targets today; the rest still show up in the registry so the
    /// focused-terminal logic knows what's there.
    public static let knownAgents: Set<String> = [
        "claude", "codex", "grok", "gemini", "copilot", "cursor-agent", "amp", "droid", "kimi", "opencode",
    ]

    public let rows: [ProcessRow]
    private let byPID: [Int32: ProcessRow]

    public init(psOutput: String) {
        var rows: [ProcessRow] = []
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            rows.append(ProcessRow(
                pid: pid,
                ppid: ppid,
                tty: ProcessTable.normalizeTTY(String(parts[2])),
                command: parts[3...].joined(separator: " ")
            ))
        }
        self.rows = rows
        self.byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func normalizeTTY(_ raw: String) -> String {
        raw.hasPrefix("/dev/") ? String(raw.dropFirst("/dev/".count)) : raw
    }

    /// Walks up the parent chain to the first ancestor whose executable
    /// lives inside an .app bundle and returns that bundle's name.
    public func hostApp(of pid: Int32) -> String? {
        var current = byPID[pid]?.ppid
        var hops = 0
        while let pid = current, pid > 1, hops < 16, let row = byPID[pid] {
            if let range = row.command.range(of: ".app/") {
                return row.command[..<range.lowerBound].split(separator: "/").last.map(String.init)
            }
            current = row.ppid
            hops += 1
        }
        return nil
    }

    /// Processes attached to a real tty whose executable name (last path
    /// component) is one of `commands`, with their host app resolved.
    public func interactiveSessions(commands: Set<String>) -> [InteractiveSession] {
        rows.compactMap { row in
            guard row.tty != "??",
                  let name = row.command.split(separator: "/").last.map(String.init),
                  commands.contains(name) else { return nil }
            return InteractiveSession(pid: row.pid, tty: row.tty, agent: name, host: hostApp(of: row.pid))
        }
    }

    public func interactiveSessions(command: String) -> [InteractiveSession] {
        interactiveSessions(commands: [command])
    }
}
