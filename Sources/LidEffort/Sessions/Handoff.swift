import AppKit
import OSLog

/// Handing a session's work to another agent — when one has hit its limit,
/// or is simply the wrong tool for what is left. A short brief is written
/// from the end of the session's transcript (what you last asked, what it
/// last said, the folder and branch), you read and edit it, and the other
/// agent starts in a new Terminal window, in the same folder, with the
/// brief as its first message.
@MainActor
enum Handoff {
    enum Agent: String, CaseIterable, Identifiable {
        case claude, codex, grok
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .grok: return "Grok"
            }
        }
        /// The command that starts it with a first message.
        var command: String { rawValue }
    }

    private static let log = Logger(subsystem: "lol.pillr.app", category: "sessions")

    /// Which agent a session belongs to, from its id.
    static func source(of session: AgentSession) -> Agent? {
        let prefix = session.id.split(separator: ".").first.map(String.init) ?? ""
        return Agent(rawValue: EffortState.targetID(forProviderID: prefix))
    }

    /// The agents installed on this Mac, found once through a login shell —
    /// the PATH a Terminal window will have. Empty until `warmUp` has run.
    private(set) static var installed: [Agent] = []

    static func warmUp() {
        Task.detached(priority: .utility) {
            let found = Self.lookUp()
            await MainActor.run { installed = found }
        }
    }

    nonisolated private static func lookUp() -> [Agent] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "for c in claude codex grok; do command -v $c >/dev/null 2>&1 && echo $c; done"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { Agent(rawValue: String($0)) }
    }

    /// Where the session can be handed: installed agents other than its own,
    /// when its folder is known.
    static func targets(for session: AgentSession) -> [Agent] {
        guard let pid = session.processID, SessionFocus.currentDirectory(of: pid) != nil else { return [] }
        let own = source(of: session)
        return installed.filter { $0 != own }
    }

    // MARK: The brief

    static func brief(for session: AgentSession) -> String {
        let pid = session.processID
        let cwd = pid.flatMap(SessionFocus.currentDirectory(of:))
        let from = source(of: session)?.displayName ?? L10n.t("Another agent")
        var context: PromptContext?
        if from == Agent.claude.displayName, let pid, let cwd, let transcript = claudeTranscript(pid: pid, cwd: cwd) {
            context = PromptContext.load(transcript: transcript.path, cwd: cwd)
        } else if let cwd {
            context = PromptContext(branch: GitBranch.read(at: cwd))
        }
        return compose(from: from, folder: cwd.map { ($0 as NSString).lastPathComponent },
                       branch: context?.branch, ask: context?.ask, lead: context?.lead)
    }

    nonisolated static func compose(from: String, folder: String?, branch: String?, ask: String?, lead: String?) -> String {
        func quote(_ text: String) -> String { SessionDoing.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), 600) }
        var parts = [String]()
        var place = folder.map { L10n.t("I'm picking up work \(from) was doing in \($0)") } ?? L10n.t("I'm picking up work \(from) was doing here")
        if let branch, !branch.isEmpty { place += L10n.t(", on branch \(branch)") }
        parts.append(place + ".")
        if let ask, !ask.isEmpty { parts.append(L10n.t("The last request was: “\(quote(ask))”.")) }
        if let lead, !lead.isEmpty { parts.append(L10n.t("Its last update: “\(quote(lead))”.")) }
        parts.append(L10n.t("Look at git status and the recent changes to see what is done, then carry on from there."))
        return parts.joined(separator: " ")
    }

    private static func claudeTranscript(pid: pid_t, cwd: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("sessions/\(pid).json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["sessionId"] as? String else { return nil }
        let recordedCWD = (json["cwd"] as? String) ?? cwd
        return ClaudeTranscript.transcript(forSessionID: sessionID, cwd: recordedCWD,
                                           in: home.appendingPathComponent("projects"), scanning: true)
    }

    // MARK: Launching

    /// A new Terminal window: `cd '<folder>' && <agent> '<brief>'`. Every
    /// quote in the brief and the folder is escaped for the shell, then the
    /// whole line again for AppleScript — the brief is text, never script.
    @discardableResult
    static func launch(_ agent: Agent, brief: String, for session: AgentSession) -> Bool {
        guard let pid = session.processID, let cwd = SessionFocus.currentDirectory(of: pid),
              let line = SessionCommander.oneLine(brief) else { return false }
        let command = "cd \(shellQuote(cwd)) && \(agent.command) \(shellQuote(line))"
        let source = """
        tell application "Terminal"
            activate
            do script \(SessionCommander.appleScriptLiteral(command))
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log.error("handoff: \(error, privacy: .public)"); return false }
        log.notice("handoff to \(agent.rawValue, privacy: .public) in \(cwd, privacy: .public)")
        return true
    }

    /// Single-quoted for zsh/bash: inside single quotes nothing is special
    /// but the quote itself, which is closed, escaped and reopened.
    nonisolated static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
