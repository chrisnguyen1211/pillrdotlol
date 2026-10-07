import Foundation

extension AgentSession {
    /// What a busy session is doing this moment — "Editing PromptPanel.swift",
    /// "$ swift test" — and since when, read from the end of its transcript.
    ///
    /// `since` is the transcript's own timestamp for the step, so it holds
    /// still from one tick to the next: the elapsed time is drawn by the
    /// view's clock, never published (a value that moved every tick would
    /// redraw the notch every tick).
    struct Doing: Equatable {
        enum Kind: Equatable {
            /// A tool is running.
            case tool
            /// Between tools: the model is thinking or writing.
            case thinking
        }
        let text: String
        let kind: Kind
        let since: Date
    }
}

/// Reads "what is it doing" from the tails of the three transcript formats
/// pillr follows: Claude Code's JSONL, Codex's rollout, Grok's ACP updates.
/// Each reader walks back from the last line to the first one that says
/// something about the current step, and stops there.
enum SessionDoing {
    // MARK: Claude Code

    /// The last tool Claude asked for, while its result has not come back;
    /// "Thinking" once it has, until the next one. Sidechains (subagents'
    /// own work) are skipped: the main thread is waiting on them, and the
    /// Task call that started them already says so.
    static func claude(tail: String) -> AgentSession.Doing? {
        for line in tail.split(separator: "\n").reversed() {
            guard let json = object(line), json["isSidechain"] as? Bool != true else { continue }
            let type = json["type"] as? String
            let at = date(json["timestamp"])
            let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                if let use = content.last(where: { $0["type"] as? String == "tool_use" }),
                   let name = use["name"] as? String {
                    return AgentSession.Doing(text: describeClaude(tool: name, input: use["input"] as? [String: Any] ?? [:]),
                                              kind: .tool, since: at ?? .distantPast)
                }
                return AgentSession.Doing(text: L10n.t("Thinking"), kind: .thinking, since: at ?? .distantPast)
            }
            if type == "user" {
                if content.contains(where: { $0["type"] as? String == "tool_result" }) {
                    return AgentSession.Doing(text: L10n.t("Thinking"), kind: .thinking, since: at ?? .distantPast)
                }
                // Your own message: Claude has not started on it yet.
                return AgentSession.Doing(text: L10n.t("Reading your message"), kind: .thinking, since: at ?? .distantPast)
            }
        }
        return nil
    }

    static func describeClaude(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String {
            ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        }
        switch tool {
        case "Bash":
            if let description = (input["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                return description
            }
            return shell(input["command"] as? String)
        case "Edit", "MultiEdit": return L10n.t("Editing \(file("file_path"))")
        case "Write": return L10n.t("Writing \(file("file_path"))")
        case "Read": return L10n.t("Reading \(file("file_path"))")
        case "NotebookEdit": return L10n.t("Editing \(file("notebook_path"))")
        case "Grep": return L10n.t("Searching for “\(clip(input["pattern"] as? String ?? "", 40))”")
        case "Glob": return L10n.t("Finding \(clip(input["pattern"] as? String ?? "", 40))")
        case "WebFetch": return L10n.t("Fetching \(host(input["url"] as? String))")
        case "WebSearch": return L10n.t("Searching the web: \(clip(input["query"] as? String ?? "", 40))")
        case "Task", "Agent":
            return L10n.t("Agent: \(clip(input["description"] as? String ?? tool, 48))")
        case "TodoWrite": return L10n.t("Updating the plan")
        case "AskUserQuestion": return L10n.t("Asking you")
        default:
            // mcp__server__tool → "server · tool"
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                return "\(parts[1]) · \(parts[2...].joined(separator: "__"))"
            }
            return tool
        }
    }

    // MARK: Codex

    /// The last call Codex made, until its output is in; "Thinking" between
    /// calls; nothing once the turn is complete.
    static func codex(tail: String) -> AgentSession.Doing? {
        for line in tail.split(separator: "\n").reversed() {
            guard let json = object(line), let payload = json["payload"] as? [String: Any] else { continue }
            let at = date(json["timestamp"]) ?? .distantPast
            switch payload["type"] as? String {
            case "task_complete", "turn_aborted":
                return nil
            case "function_call", "custom_tool_call", "local_shell_call":
                return AgentSession.Doing(text: describeCodex(payload), kind: .tool, since: at)
            case "function_call_output", "custom_tool_call_output", "reasoning", "agent_reasoning",
                 "user_message", "task_started":
                return AgentSession.Doing(text: L10n.t("Thinking"), kind: .thinking, since: at)
            default:
                continue
            }
        }
        return nil
    }

    static func describeCodex(_ payload: [String: Any]) -> String {
        let name = payload["name"] as? String ?? "shell"
        var arguments: [String: Any] = [:]
        if let text = payload["arguments"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            arguments = parsed
        }
        if let action = payload["action"] as? [String: Any] { arguments.merge(action) { a, _ in a } }
        switch name {
        case "exec_command", "shell", "local_shell", "container.exec":
            if let words = arguments["command"] as? [String] { return shell(words.joined(separator: " ")) }
            return shell((arguments["cmd"] as? String) ?? (arguments["command"] as? String))
        case "apply_patch":
            let input = (payload["input"] as? String) ?? (arguments["input"] as? String) ?? ""
            if let file = input.split(separator: "\n").first(where: { $0.hasPrefix("*** Update File: ") || $0.hasPrefix("*** Add File: ") }) {
                let path = String(file.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
                return L10n.t("Editing \((path as NSString).lastPathComponent)")
            }
            return L10n.t("Editing files")
        case "exec":
            let input = (payload["input"] as? String) ?? ""
            return shell(input.split(separator: "\n").first.map(String.init))
        case "update_plan": return L10n.t("Updating the plan")
        case "web_search": return L10n.t("Searching the web: \(clip(arguments["query"] as? String ?? "", 40))")
        default: return name
        }
    }

    // MARK: Grok

    /// Grok writes Agent Client Protocol updates: a `tool_call` carries a
    /// title meant for people; it runs until a `tool_call_update` marks it
    /// done. Thought chunks between calls are thinking.
    static func grok(tail: String) -> AgentSession.Doing? {
        for line in tail.split(separator: "\n").reversed() {
            guard let json = object(line),
                  let update = (json["params"] as? [String: Any])?["update"] as? [String: Any] else { continue }
            let at = date(json["timestamp"]) ?? .distantPast
            switch update["sessionUpdate"] as? String {
            case "turn_completed":
                return nil
            case "tool_call_update":
                // The latest step finished and nothing has started since:
                // between steps. Still running: its tool_call names it.
                if ["completed", "failed"].contains(update["status"] as? String ?? "") {
                    return AgentSession.Doing(text: L10n.t("Thinking"), kind: .thinking, since: at)
                }
            case "tool_call":
                let title = (update["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return AgentSession.Doing(text: title.isEmpty ? L10n.t("Working") : clip(title, 60), kind: .tool, since: at)
            case "agent_thought_chunk", "agent_message_chunk":
                return AgentSession.Doing(text: L10n.t("Thinking"), kind: .thinking, since: at)
            default:
                continue
            }
        }
        return nil
    }

    // MARK: Reading tails

    /// The last 64 KB of a file, cached by its size and modification time —
    /// a tick that finds the file unchanged costs one `stat`.
    static func cached(_ url: URL, parse: (String) -> AgentSession.Doing?) -> AgentSession.Doing? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        cacheLock.lock()
        let hit = cache[url.path]
        cacheLock.unlock()
        if let hit, hit.modified == modified, hit.size == size { return hit.doing }
        let doing = parse(tail(of: url))
        cacheLock.lock()
        if cache.count > 200 { cache.removeAll() }
        cache[url.path] = (modified, size, doing)
        cacheLock.unlock()
        return doing
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (modified: Date, size: UInt64, doing: AgentSession.Doing?)] = [:]

    static func tail(of url: URL, bytes: UInt64 = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        // The first line is cut where the window started; it is not a line.
        if end > bytes, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }

    // MARK: Helpers

    private static func object(_ line: Substring) -> [String: Any]? {
        guard line.first == "{" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return iso.date(from: text) ?? isoPlain.date(from: text) }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        }
        return nil
    }

    /// `$ ` and the command's first line, shortened.
    static func shell(_ command: String?) -> String {
        let first = (command ?? "").split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? L10n.t("Running a command") : "$ " + clip(trimmed, 56)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > limit ? String(one.prefix(limit - 1)) + "…" : one
    }

    private static func host(_ url: String?) -> String {
        url.flatMap { URL(string: $0)?.host } ?? (url ?? "")
    }
}
