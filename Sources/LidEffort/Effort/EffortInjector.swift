import AppKit
import LidEffortCore
import Foundation
import OSLog

/// Best-effort live update of agent sessions that are already running —
/// Claude Code and Grok: finds the Terminal.app tab a session lives in and,
/// only when its prompt is provably idle, types `/effort <level>` via Terminal's own `do script in
/// <tab>` — straight to the tty, no window activation, no simulated
/// keystrokes, just Terminal.app's Apple Events consent.
///
/// Every failure mode does nothing and says why. Missing a live update is
/// harmless (the next session reads the level from settings.json); typing
/// over someone mid-sentence is not.
enum EffortInjector {
    enum Outcome: Equatable {
        case hostedBy(String)
        case noTTY
        case tabNotFound
        case contentUnreadable(String)
        case promptNotIdle
        case sent
        case appleScriptError(String)
    }

    struct Attempt: Equatable {
        let pid: pid_t
        let tty: String?
        let outcome: Outcome
    }

    private static let log = Logger(subsystem: "lol.spyx.app", category: "effort")

    /// One session and what to type into it: `/effort high` for Claude
    /// Code, Grok's own value for Grok.
    struct Target: Equatable {
        let session: EffortSessionRef
        let command: String
    }

    /// Types each target's command into its Terminal tab, where the prompt
    /// is provably idle. The tabs are read once for the lot.
    @discardableResult
    static func inject(_ targets: [Target]) -> [Attempt] {
        guard !targets.isEmpty else { return [] }
        let tabs = readAllTabs()
        return targets.map { target in
            let session = target.session
            guard let tty = session.tty else { return Attempt(pid: session.pid, tty: nil, outcome: .noTTY) }
            if session.hostBundleID != "com.apple.Terminal" {
                return Attempt(pid: session.pid, tty: tty, outcome: .hostedBy(session.hostName ?? session.hostBundleID ?? "another app"))
            }
            guard let match = tabs.first(where: { $0.tty == tty }) else {
                return Attempt(pid: session.pid, tty: tty, outcome: .tabNotFound)
            }
            if match.contents.hasPrefix("\u{3}") {
                return Attempt(pid: session.pid, tty: tty, outcome: .contentUnreadable(String(match.contents.dropFirst())))
            }
            guard PromptIdleDetector.isIdle(screenText: match.contents) else {
                return Attempt(pid: session.pid, tty: tty, outcome: .promptNotIdle)
            }
            return Attempt(pid: session.pid, tty: tty, outcome: send(target.command, tty: tty))
        }
    }

    /// Agents running in a terminal, found in the process table rather than
    /// in any one agent's own registry: Claude Code and Grok alike, whichever
    /// tab or window they are in. Sessions without a tty — Claude Desktop's
    /// — are not here; nothing can be typed into them.
    static func terminalSessions(agents: Set<String> = ["claude", "grok"]) -> [(pid: pid_t, tty: String, agent: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let table = ProcessTable(psOutput: String(decoding: data, as: UTF8.self))
        return table.interactiveSessions(commands: agents).map { ($0.pid, $0.tty, $0.agent) }
    }

    /// Frontmost app and — for Terminal.app, the one host with a scripting
    /// interface — the tty of its selected tab.
    static func focus() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        var tty: String? = nil
        if app == "Terminal" {
            tty = runAppleScript("tell application \"Terminal\" to get tty of selected tab of front window")
                .map(normalizeTTY)
        }
        return FocusContext(frontmostApp: app, focusedTTY: tty)
    }

    static func normalizeTTY(_ raw: String) -> String {
        raw.hasPrefix("/dev/") ? String(raw.dropFirst("/dev/".count)) : raw
    }

    /// Every Terminal.app tab's tty + rendered contents in one pass, by index
    /// (`tab ti of window wi`) rather than a held reference — a Terminal.app
    /// scripting trap with heavily-redrawing tabs. `tty` and `contents` fail
    /// independently; a content failure carries the real AppleScript message
    /// behind an `ASCII character 3` prefix.
    private static func readAllTabs() -> [(tty: String, contents: String)] {
        let script = """
        tell application "Terminal"
            set AppleScript's text item delimiters to (ASCII character 2)
            set recs to {}
            set wCount to count of windows
            repeat with wi from 1 to wCount
                try
                    set tCount to count of tabs of window wi
                    repeat with ti from 1 to tCount
                        set tTty to missing value
                        try
                            set tTty to tty of tab ti of window wi
                        end try
                        if tTty is not missing value then
                            set tContents to ""
                            try
                                set tContents to contents of tab ti of window wi
                            on error errMsg
                                set tContents to (ASCII character 3) & errMsg
                            end try
                            set end of recs to (tTty & (ASCII character 2) & tContents)
                        end if
                    end repeat
                end try
            end repeat
            set AppleScript's text item delimiters to (ASCII character 1)
            return recs as string
        end tell
        """
        guard let raw = runAppleScript(script) else { return [] }
        return raw.components(separatedBy: "\u{1}").compactMap { record in
            let fields = record.components(separatedBy: "\u{2}")
            guard fields.count == 2 else { return nil }
            return (normalizeTTY(fields[0]), fields[1])
        }
    }

    /// A message you wrote in spyx, typed into the session's Terminal tab —
    /// only at an idle, empty prompt, the same rule as `/effort`. One line:
    /// a line break would send the first half on its own.
    static func typeMessage(_ text: String, tty: String) -> Outcome {
        guard let line = SessionCommander.oneLine(text) else { return .appleScriptError("empty") }
        guard tty.range(of: #"^ttys?[0-9]+$"#, options: .regularExpression) != nil else { return .noTTY }
        let tabs = readAllTabs()
        guard let match = tabs.first(where: { $0.tty == tty }) else { return .tabNotFound }
        if match.contents.hasPrefix("\u{3}") { return .contentUnreadable(String(match.contents.dropFirst())) }
        guard PromptIdleDetector.isIdle(screenText: match.contents) else { return .promptNotIdle }
        let literal = SessionCommander.appleScriptLiteral(line)
        let script = """
        tell application "Terminal"
            set wCount to count of windows
            repeat with wi from 1 to wCount
                try
                    set tCount to count of tabs of window wi
                    repeat with ti from 1 to tCount
                        try
                            if (tty of tab ti of window wi) is "/dev/\(tty)" then
                                do script \(literal) in tab ti of window wi
                                return "sent"
                            end if
                        end try
                    end repeat
                end try
            end repeat
            return "not-found"
        end tell
        """
        switch runAppleScript(script) {
        case "sent":
            log.notice("message (\(line.count, privacy: .public) chars) -> \(tty, privacy: .public)")
            return .sent
        case let other:
            return other == "not-found" ? .tabNotFound : .appleScriptError(other ?? "no result")
        }
    }

    /// `/effort <value>` and nothing else: what is typed into a session is
    /// sent by it, so a command that is not exactly this is not typed.
    static func isEffortCommand(_ command: String) -> Bool {
        // The one two-word form: switching the Claude app's ultracode off.
        if command == "/effort ultracode off" { return true }
        return command.hasPrefix("/effort ") && EffortValue.isPlain(String(command.dropFirst("/effort ".count)))
    }

    private static func send(_ command: String, tty: String) -> Outcome {
        guard isEffortCommand(command),
              tty.range(of: #"^ttys?[0-9]+$"#, options: .regularExpression) != nil else {
            log.error("refused to type \(command, privacy: .public) into \(tty, privacy: .public)")
            return .appleScriptError("refused")
        }
        let script = effortScript(command, tty: tty)
        switch runAppleScript(script) {
        case "sent":
            log.notice("live \(command, privacy: .public) -> \(tty, privacy: .public)")
            return .sent
        case let other:
            return .appleScriptError(other ?? "no result")
        }
    }

    /// Whether macOS already lets spyx script Terminal — asked without a
    /// dialog. A lid gesture is no moment for macOS's consent prompt; that
    /// is asked in Setup → Terminals, with the reason beside it.
    /// The script that types `/effort …` into the tab on `tty` — that tab
    /// only. The tty is matched whole: `contains` let `ttys01` match
    /// `/dev/ttys010` too, and typed into a stranger's tab.
    static func effortScript(_ command: String, tty: String) -> String {
        """
        tell application "Terminal"
            set wCount to count of windows
            repeat with wi from 1 to wCount
                try
                    set tCount to count of tabs of window wi
                    repeat with ti from 1 to tCount
                        try
                            if (tty of tab ti of window wi) is "/dev/\(tty)" then
                                do script "\(command)" in tab ti of window wi
                                return "sent"
                            end if
                        end try
                    end repeat
                end try
            end repeat
            return "not-found"
        end tell
        """
    }

    static var terminalAllowed: Bool { allowed("com.apple.Terminal") }

    /// iTerm2 answers Apple Events only once you have allowed spyx — asked
    /// first, so a reply says so rather than raising macOS's prompt halfway
    /// through, or reading as a tab that could not be found.
    static var itermAllowed: Bool { allowed("com.googlecode.iterm2") }

    private static func allowed(_ bundleID: String) -> Bool {
        if let cached = allowedCache[bundleID], cached.until > Date() { return cached.value }
        let target = AutomationTarget.all.first { $0.bundleID == bundleID }
        let value = target.map { AutomationAccess.status(of: $0, ask: false) == .granted } ?? false
        allowedCache[bundleID] = (value, Date().addingTimeInterval(value ? 60 : 5))
        return value
    }
    nonisolated(unsafe) private static var allowedCache: [String: (value: Bool, until: Date)] = [:]

    private static func runAppleScript(_ source: String) -> String? {
        guard terminalAllowed else { return nil }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            log.error("AppleScript: \(error, privacy: .public)")
            return nil
        }
        return result.stringValue
    }
}
