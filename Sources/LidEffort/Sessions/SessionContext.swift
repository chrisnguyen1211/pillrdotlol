import Foundation
import SQLite3

/// What you last asked a session, what it said at the end, and the name it
/// goes by, for the done card: several sessions can share a folder, and the
/// folder alone did not say which one to answer.
///
/// Every agent keeps its conversation its own way, and each reader here goes
/// to that agent's own record, reads at most the end of it, and writes
/// nothing. A shape that is not the one expected gives nothing rather than a
/// guess, and the card falls back to what it said before.
enum SessionContext {
    /// How much of a log's end is read.
    static let tailBytes = 256 * 1024

    @MainActor
    static func load(for session: AgentSession) -> PromptContext? {
        let parts = session.id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let agent = parts[0], rest = parts[1]
        let found: PromptContext?
        switch agent {
        case "claude":
            found = claude(session)
        case "codex", _ where agent.hasPrefix("codex-"):
            found = codex(profileID: agent, rest: rest)
        case "grok":
            found = grok(id: rest, cwd: session.processID.flatMap(SessionFocus.currentDirectory(of:)))
        case "kimi":
            found = kimi(sessionDirectory: rest)
        case "cursor":
            found = cursor(composerID: rest, name: session.name)
        case "antigravity":
            found = antigravity(id: rest)
        case "gemini-api":
            if rest.hasPrefix("opencode.") {
                found = openCode(id: String(rest.dropFirst("opencode.".count)))
            } else if rest.hasPrefix("hermes.") {
                found = hermes(id: String(rest.dropFirst("hermes.".count)))
            } else {
                found = geminiCLI(chat: rest)
            }
        default:
            found = nil
        }
        guard let found, found != PromptContext() else { return nil }
        return found
    }

    // MARK: - Shared

    /// One turn's worth, newest first: your messages and the agent's.
    struct Message: Equatable {
        let fromYou: Bool
        let text: String
    }

    /// Your newest message, and what the agent said after it: the end of
    /// the turn the card is about.
    static func fold(newestFirst messages: [Message], title: String? = nil) -> PromptContext {
        var context = PromptContext(title: PromptContext.clean(title))
        for message in messages {
            guard let text = PromptContext.clean(message.text) else { continue }
            if message.fromYou {
                context.ask = text
                break
            }
            if context.lead == nil { context.lead = text }
        }
        return context
    }

    /// The JSON objects on the last lines of a log, oldest first.
    static func tailLines(of url: URL, bytes: Int = tailBytes) -> [[String: Any]] {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Read from part-way through, the first line is the end of another.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// Text from a value written as a string, a list of `{text}` blocks, or a
    /// `{text}` object, whichever the agent chose.
    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let object = value as? [String: Any] { return text(object["text"]) }
        if let blocks = value as? [Any] {
            let joined = blocks.compactMap { block -> String? in
                guard let object = block as? [String: Any] else { return block as? String }
                if let kind = object["type"] as? String, !["text", "input_text", "output_text"].contains(kind) { return nil }
                return object["text"] as? String
            }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// An id that can sit inside a query without being bound: letters,
    /// digits, `-` and `_` only.
    static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: - Claude Code

    @MainActor
    private static func claude(_ session: AgentSession) -> PromptContext? {
        guard let pid = session.processID, let cwd = SessionFocus.currentDirectory(of: pid),
              let transcript = Handoff.claudeTranscript(pid: pid, cwd: cwd) else { return nil }
        return PromptContext.load(transcript: transcript.path, cwd: nil)
    }

    // MARK: - Codex

    /// `<profile>.rollout-2026-10-02T00-53-12-<uuid>.jsonl`: the file sits
    /// under that day's folder, and the thread's name is in the state store.
    private static func codex(profileID: String, rest: String) -> PromptContext? {
        guard rest.hasPrefix("rollout-"), rest.hasSuffix(".jsonl"),
              let profile = CodexProfile.discover().first(where: { $0.id == profileID }) else { return nil }
        let rollout = codexRollout(named: rest, under: profile.configDirectory.appendingPathComponent("sessions"))
            ?? codexRolloutFromState(named: rest, state: profile.stateURL)
        guard let rollout else { return nil }
        let title = codexTitle(rollout: rollout, state: profile.stateURL)
        return codex(lines: tailLines(of: rollout), title: title)
    }

    static func codexRollout(named name: String, under sessions: URL) -> URL? {
        // rollout-YYYY-MM-DDT…
        let date = name.dropFirst("rollout-".count).prefix(10).split(separator: "-")
        guard date.count == 3 else { return nil }
        let url = sessions.appendingPathComponent("\(date[0])/\(date[1])/\(date[2])/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func codexRolloutFromState(named name: String, state: URL) -> URL? {
        guard let db = SQLiteStore.open(state) else { return nil }
        defer { sqlite3Close(db) }
        let path = SQLiteStore.rows(in: db, sql: "SELECT rollout_path FROM threads WHERE rollout_path LIKE ? LIMIT 1",
                                    bind: "%/" + name).first
        return path.map(URL.init(fileURLWithPath:))
    }

    private static func codexTitle(rollout: URL, state: URL) -> String? {
        guard let db = SQLiteStore.open(state) else { return nil }
        defer { sqlite3Close(db) }
        // The name you gave the thread; Codex's own title is often just the
        // first message, which the card shows anyway.
        let name = SQLiteStore.rows(in: db, sql: "SELECT coalesce(name, '') FROM threads WHERE rollout_path = ? LIMIT 1",
                                    bind: rollout.path).first
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A rollout: `event_msg` lines carry your `user_message` and the agent's
    /// `agent_message`; `task_complete` repeats its last words.
    static func codex(lines: [[String: Any]], title: String?) -> PromptContext {
        var messages: [Message] = []
        for line in lines.reversed() {
            guard let payload = line["payload"] as? [String: Any], let kind = payload["type"] as? String else { continue }
            switch (line["type"] as? String, kind) {
            case ("event_msg", "user_message"):
                if let text = text(payload["message"]) { messages.append(Message(fromYou: true, text: text)) }
            case ("event_msg", "agent_message"):
                if let text = text(payload["message"]) { messages.append(Message(fromYou: false, text: text)) }
            case ("event_msg", "task_complete"):
                if let text = text(payload["last_agent_message"]) { messages.append(Message(fromYou: false, text: text)) }
            default:
                continue
            }
        }
        return fold(newestFirst: messages, title: title)
    }

    // MARK: - Grok

    /// `~/.grok/sessions/<cwd>/<id>/`: the conversation in `chat_history.jsonl`,
    /// the session's own summary line in `summary.json`.
    private static func grok(id: String, cwd: String?) -> PromptContext? {
        guard let folder = GrokActivity.sessionDirectory(id: id, cwd: cwd, under: GrokActivity.sessionsRoot) else { return nil }
        var title: String?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("summary.json")),
           let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = summary["session_summary"] as? String
        }
        return grok(lines: tailLines(of: folder.appendingPathComponent("chat_history.jsonl")), title: title)
    }

    /// Your messages are `user`, except the ones Grok writes in itself and
    /// marks with a `synthetic_reason`; its replies are `assistant`.
    static func grok(lines: [[String: Any]], title: String?) -> PromptContext {
        var messages: [Message] = []
        for line in lines.reversed() {
            switch line["type"] as? String {
            case "user" where line["synthetic_reason"] == nil:
                if let text = text(line["content"]) { messages.append(Message(fromYou: true, text: text)) }
            case "assistant":
                if let text = text(line["content"]) { messages.append(Message(fromYou: false, text: text)) }
            default:
                continue
            }
        }
        return fold(newestFirst: messages, title: title)
    }

    // MARK: - Kimi Code

    /// The session folder holds `state.json`, with its title and your last
    /// prompt, and the main agent's `wire.jsonl`, whose text parts after the
    /// last prompt are the reply.
    private static func kimi(sessionDirectory name: String) -> PromptContext? {
        let root = KimiActivity.root
        guard let folder = KimiActivity.index(root: root).values.first(where: { $0.lastPathComponent == name })
                ?? kimiScan(name, under: root.appendingPathComponent("sessions")) else { return nil }
        var state: [String: Any] = [:]
        if let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            state = object
        }
        return kimi(state: state, wire: tailLines(of: folder.appendingPathComponent("agents/main/wire.jsonl")))
    }

    private static func kimiScan(_ name: String, under sessions: URL) -> URL? {
        guard let buckets = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        return buckets.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func kimi(state: [String: Any], wire: [[String: Any]]) -> PromptContext {
        var ask: String?
        var reply = ""
        for line in wire {
            var record = line
            if record["type"] as? String == "context.append_loop_event", let event = record["event"] as? [String: Any] {
                record = event
            }
            if let agent = record["agentId"] as? String, agent != "main" { continue }
            switch record["type"] as? String {
            case "turn.prompt":
                ask = text(record["input"]) ?? ask
                reply = ""
            case "content.part":
                if let part = record["part"] as? [String: Any] {
                    if part["type"] as? String == "text", let piece = part["text"] as? String { reply += piece }
                } else if let piece = record["text"] as? String {
                    reply += piece
                }
            case "text":
                if let piece = record["text"] as? String { reply += piece }
            default:
                continue
            }
        }
        var context = PromptContext(title: PromptContext.clean(state["title"] as? String))
        context.ask = PromptContext.clean(state["lastPrompt"] as? String) ?? PromptContext.clean(ask)
        context.lead = PromptContext.clean(reply)
        return context
    }

    // MARK: - Cursor

    /// The chat's header names it; `composerData:<id>` lists its bubbles in
    /// order, type 1 yours and 2 the agent's, each `bubbleId:<id>:<bubble>`
    /// with its `text`.
    private static func cursor(composerID id: String, name: String) -> PromptContext? {
        let title = (name == "Untitled chat" || name == L10n.t("Untitled chat")) ? nil : name
        guard isPlainID(id), let db = SQLiteStore.open(CursorCredentials.storeURL) else {
            return title.map { PromptContext(title: $0) }
        }
        defer { sqlite3Close(db) }
        func value(_ key: String) -> [String: Any]? {
            guard let raw = SQLiteStore.rows(in: db, sql: "SELECT value FROM cursorDiskKV WHERE key = ?", bind: key).first,
                  let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
            return object
        }
        let headers = (value("composerData:\(id)")?["fullConversationHeadersOnly"] as? [[String: Any]]) ?? []
        var messages: [Message] = []
        for header in headers.reversed().prefix(40) {
            guard let bubble = header["bubbleId"] as? String, let kind = (header["type"] as? NSNumber)?.intValue,
                  kind == 1 || kind == 2, let body = value("bubbleId:\(id):\(bubble)"), let text = text(body["text"]) else { continue }
            messages.append(Message(fromYou: kind == 1, text: text))
            if kind == 1 { break }
        }
        return fold(newestFirst: messages, title: title)
    }

    // MARK: - Antigravity

    /// `brain/<id>/.system_generated/logs/transcript.jsonl`, whose records are
    /// `USER_INPUT` and `PLANNER_RESPONSE`. Partial: the field the words are
    /// in has not been seen, so the usual names are tried and nothing else.
    private static func antigravity(id: String) -> PromptContext? {
        guard isPlainID(id) else { return nil }
        for root in AntigravityActivity.transcriptRoots {
            let url = root.appendingPathComponent(id).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return antigravity(lines: tailLines(of: url)) }
        }
        return nil
    }

    static func antigravity(lines: [[String: Any]]) -> PromptContext {
        func words(_ line: [String: Any]) -> String? {
            for key in ["content", "text", "message", "user_input", "response"] {
                if let found = text(line[key]) { return found }
            }
            return nil
        }
        var messages: [Message] = []
        for line in lines.reversed() {
            switch line["type"] as? String {
            case "USER_INPUT":
                if let text = words(line) { messages.append(Message(fromYou: true, text: text)) }
            case "PLANNER_RESPONSE":
                if let text = words(line) { messages.append(Message(fromYou: false, text: text)) }
            default:
                continue
            }
        }
        return fold(newestFirst: messages)
    }

    // MARK: - Gemini CLI

    /// `~/.gemini/tmp/<project>/chats/<chat>.jsonl`: `user` and `gemini`
    /// records, each with its `content`.
    private static func geminiCLI(chat: String) -> PromptContext? {
        let root = GeminiCLIUsage.sessionsRoot
        guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let file = chat.hasSuffix(".jsonl") ? chat : chat + ".jsonl"
        guard let url = projects.map({ $0.appendingPathComponent("chats").appendingPathComponent(file) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return geminiCLI(lines: tailLines(of: url))
    }

    static func geminiCLI(lines: [[String: Any]]) -> PromptContext {
        var messages: [Message] = []
        for line in lines.reversed() {
            switch line["type"] as? String {
            case "user":
                if let text = text(line["content"]) { messages.append(Message(fromYou: true, text: text)) }
            case "gemini":
                if let text = text(line["content"]) { messages.append(Message(fromYou: false, text: text)) }
            default:
                continue
            }
        }
        return fold(newestFirst: messages)
    }

    // MARK: - OpenCode

    /// The session's `title`, and its messages' text parts, newest first.
    /// Partial: the `part` table is OpenCode's, not one pillr reads elsewhere.
    private static func openCode(id: String) -> PromptContext? {
        guard isPlainID(id), let db = SQLiteStore.open(OpenCodeGeminiUsage.database) else { return nil }
        defer { sqlite3Close(db) }
        let title = SQLiteStore.rows(in: db, sql: "SELECT coalesce(title, '') FROM session WHERE id = ?", bind: id).first
        let rows = SQLiteStore.rows(in: db, sql: """
            SELECT m.data, p.data FROM part p JOIN message m ON p.message_id = m.id
            WHERE p.session_id = '\(id)' ORDER BY p.id DESC LIMIT 200
            """, columns: 2)
        var messages: [Message] = []
        for row in rows {
            guard let message = try? JSONSerialization.jsonObject(with: Data(row[0].utf8)) as? [String: Any],
                  let part = try? JSONSerialization.jsonObject(with: Data(row[1].utf8)) as? [String: Any],
                  part["type"] as? String == "text", part["synthetic"] as? Bool != true,
                  let text = part["text"] as? String, !text.isEmpty else { continue }
            messages.append(Message(fromYou: message["role"] as? String == "user", text: text))
        }
        return fold(newestFirst: messages, title: title.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Hermes

    /// `~/.hermes/state.db`: the session's `title`, and `messages` with
    /// their `role` and `content`.
    private static func hermes(id: String) -> PromptContext? {
        guard isPlainID(id), let db = SQLiteStore.open(HermesGeminiUsage.database) else { return nil }
        defer { sqlite3Close(db) }
        let title = SQLiteStore.rows(in: db, sql: "SELECT coalesce(title, '') FROM sessions WHERE id = ?", bind: id).first
        let rows = SQLiteStore.rows(in: db, sql: """
            SELECT role, content FROM messages
            WHERE session_id = '\(id)' AND role IN ('user', 'assistant') AND coalesce(content, '') != ''
            ORDER BY timestamp DESC, id DESC LIMIT 60
            """, columns: 2)
        let messages = rows.map { Message(fromYou: $0[0] == "user", text: $0[1]) }
        return fold(newestFirst: messages, title: title.flatMap { $0.isEmpty ? nil : $0 })
    }
}

private func sqlite3Close(_ db: OpaquePointer) { sqlite3_close(db) }
