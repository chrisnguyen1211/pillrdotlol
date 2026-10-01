import Foundation

/// Which model a running agent session is using right now — read from what
/// each agent writes about its own sessions, since a session can switch
/// model after it starts and the config only names the default.
enum SessionModels {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Grok: `~/.grok/active_sessions.json` maps a pid to its session, and
    /// the session's `summary.json` names its `current_model_id`.
    static func grok(home: URL = SessionModels.home) -> [pid_t: String] {
        let grok = home.appendingPathComponent(".grok")
        guard let data = try? Data(contentsOf: grok.appendingPathComponent("active_sessions.json")),
              let active = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: grok.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)) ?? []
        var result: [pid_t: String] = [:]
        for session in active {
            guard let id = session["session_id"] as? String,
                  let pid = (session["pid"] as? NSNumber)?.int32Value else { continue }
            for folder in folders {
                let summary = folder.appendingPathComponent(id).appendingPathComponent("summary.json")
                guard let data = try? Data(contentsOf: summary),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let model = json["current_model_id"] as? String else { continue }
                result[pid] = model
                break
            }
        }
        return result
    }

    /// A Claude Code session Claude Desktop runs: which of Desktop's own
    /// session records it is, when Desktop last showed it, whether it is
    /// idle, and its model.
    struct DesktopSession: Equatable {
        let pid: pid_t
        let lastFocusedAt: Double
        let isIdle: Bool
        let model: String?
        /// Claude Desktop's id for it (`local_…`) — what its window shows
        /// in the address of the page that holds the session.
        var hostSessionID = ""
        /// Its title in Claude Desktop's sidebar.
        var title: String? = nil
    }

    /// `~/.claude/sessions/<pid>.json` says the session belongs to Claude
    /// Desktop (`hostSessionId`) and whether it is idle; Desktop's own
    /// record for it says when it was last in front and on which model.
    static func desktop(pid: pid_t, home: URL = SessionModels.home) -> DesktopSession? {
        let claude = home.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: claude.appendingPathComponent("sessions/\(pid).json")),
              let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = session["hostSessionId"] as? String else { return nil }
        let idle = (session["status"] as? String) == "idle"
        let records = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var record: [String: Any]?
        let fm = FileManager.default
        outer: for account in (try? fm.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let file = org.appendingPathComponent("\(host).json")
                if let data = try? Data(contentsOf: file),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    record = json
                    break outer
                }
            }
        }
        let focused = (record?["lastFocusedAt"] as? NSNumber)?.doubleValue ?? 0
        let model = (record?["model"] as? String) ?? SessionModels.claude(pid: pid, home: home)
        return DesktopSession(pid: pid, lastFocusedAt: focused, isIdle: idle, model: model,
                              hostSessionID: host, title: record?["title"] as? String)
    }

    /// The running Claude Desktop session with this id, found among every
    /// session Claude Code has registered — the notch's list leaves out
    /// sessions idle for hours, and one of those can still be on screen.
    static func desktop(hostSessionID: String, home: URL = SessionModels.home) -> DesktopSession? {
        let sessions = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let pid = pid_t(file.deletingPathExtension().lastPathComponent), kill(pid, 0) == 0,
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["hostSessionId"] as? String == hostSessionID else { continue }
            return desktop(pid: pid, home: home)
        }
        return nil
    }

    /// Claude Code: `~/.claude/sessions/<pid>.json` names the session and its
    /// cwd; the transcript's newest reply carries the model that wrote it.
    static func claude(pid: pid_t, home: URL = SessionModels.home) -> String? {
        let claude = home.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: claude.appendingPathComponent("sessions/\(pid).json")),
              let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = session["sessionId"] as? String else { return nil }
        let projects = claude.appendingPathComponent("projects")
        var transcript: URL?
        if let cwd = session["cwd"] as? String {
            let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let candidate = projects.appendingPathComponent(slug).appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { transcript = candidate }
        }
        if transcript == nil {
            let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            transcript = folders.map { $0.appendingPathComponent("\(id).jsonl") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let transcript else { return nil }
        return latestModel(inTranscriptTail: tail(of: transcript, bytes: 256 * 1024))
    }

    /// The last `"model":"claude-…"` in a transcript's tail — the reply
    /// written most recently.
    static func latestModel(inTranscriptTail text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #""model"\s*:\s*"(claude-[^"]+)""#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }

    private static func tail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
