import AppKit
import LidEffortCore
import Foundation

/// The "turn finished" signal from every agent that has one, so the done
/// card is said the moment an answer ends rather than guessed from files:
///
/// * **Claude Code** — a `Stop` hook in `~/.claude/settings.json`
///   (`ClaudeHookInstaller`).
/// * **Grok** — a `Stop` hook in a file of pillr's own, `~/.grok/hooks/pillr.json`;
///   Grok runs it once per turn, on a genuine completion only.
/// * **Cursor** — a `stop` hook in `~/.cursor/hooks.json`.
/// * **Droid** — a Claude-style `Stop` hook under `hooks` in `~/.factory/settings.json`.
/// * **Antigravity** — a `Stop` hook named `pillr` in `~/.gemini/config/hooks.json`.
/// * **Copilot CLI** — an `agentStop` hook in a file of pillr's own, `~/.copilot/hooks/pillr.json`.
/// * **Kimi Code** — a `[[hooks]]` block with `event = "Stop"` in `~/.kimi-code/config.toml`.
/// * **Gemini CLI** — an `AfterAgent` hook under `hooks` in `~/.gemini/settings.json`.
/// * **OpenCode** — a plugin of pillr's own, `~/.config/opencode/plugins/pillr.js`.
///
/// Only for an agent that is on this Mac, only once the person has seen
/// what they are (`HookConsent`), and all of it undone by `removeEverything`.
/// * **Codex** (CLI and app) — its `notify` program, called after every
///   turn. Codex takes one; if another is set (Codex Computer Use sets
///   one), pillr goes first and hands every call on to it unchanged.
///
/// Each install adds only pillr's own entry and each removal takes only
/// that out — other tools' hooks are never touched. Every hook runs
/// `pillr --stop-hook --agent <name>` (or `--codex-notify`), which passes
/// the event to the app and exits at once.
enum AgentHooks {
    static let codexMarker = "--codex-notify"
    static let thenMarker = "--then"

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func stopCommand(executable: String, agent: String) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' \(ClaudeHookInstaller.stopMarker) --agent \(agent)"
    }

    /// Every agent present on this Mac, in or out together.
    /// Claude Code's own folder, made by Claude Code — pillr never makes it.
    static var claudePresent: Bool {
        FileManager.default.fileExists(atPath: ClaudeHookInstaller.settingsURL.deletingLastPathComponent().path)
    }

    static func installAll(executable: String) {
        if claudePresent { try? ClaudeHookInstaller.installStop(executable: executable) }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path) {
            try? installGrok(executable: executable)
        }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path) {
            try? installCursor(executable: executable)
        }
        if FileManager.default.fileExists(atPath: codexConfigURL.path) {
            try? installCodex(executable: executable)
        }
        if BuiltInTargets.droid.isPresent(exists: FileManager.default.fileExists(atPath:)) {
            try? installClaudeStyle(at: droidSettingsURL, event: "Stop", agent: "droid", executable: executable)
        }
        if antigravityPresent {
            try? installAntigravity(executable: executable)
        }
        if BuiltInTargets.copilot.isPresent(exists: FileManager.default.fileExists(atPath:)) {
            try? installCopilot(executable: executable)
        }
        if BuiltInTargets.kimi.isPresent(exists: FileManager.default.fileExists(atPath:)) {
            try? installKimi(executable: executable)
        }
        if geminiCLIPresent {
            try? installClaudeStyle(at: geminiSettingsURL, event: "AfterAgent", agent: "gemini-cli", executable: executable,
                                    timeout: ClaudeHookInstaller.stopTimeoutSeconds * 1000, matcher: "*")
        }
        if openCodePresent {
            try? installOpenCode(executable: executable)
        }
    }

    /// One agent as the setup page lists it: on this Mac or not, whether
    /// pillr's done hook is in, and whether it can ask for approvals at all.
    struct Link: Identifiable, Equatable {
        let id: String
        let name: String
        let present: Bool
        let doneHooked: Bool
        /// Nil: the agent has no hook that can hold a question open.
        let approvalsHooked: Bool?
    }

    /// Every agent with a turn-finished signal, in the same order and the
    /// same shape — the ones not on this Mac included, marked so.
    static func links() -> [Link] {
        let fm = FileManager.default
        let claude = claudePresent
        let codex = fm.fileExists(atPath: codexConfigURL.path)
        let grok = fm.fileExists(atPath: home.appendingPathComponent(".grok").path)
        let cursor = fm.fileExists(atPath: home.appendingPathComponent(".cursor").path)
        let droid = BuiltInTargets.droid.isPresent(exists: fm.fileExists(atPath:))
        let copilot = BuiltInTargets.copilot.isPresent(exists: fm.fileExists(atPath:))
        let kimi = BuiltInTargets.kimi.isPresent(exists: fm.fileExists(atPath:))
        return [
            Link(id: "claude", name: "Claude Code", present: claude,
                 doneHooked: ClaudeHookInstaller.isStopInstalled(), approvalsHooked: ClaudeHookInstaller.isInstalled()),
            Link(id: "codex", name: "Codex", present: codex, doneHooked: isCodexInstalled(), approvalsHooked: nil),
            Link(id: "grok", name: "Grok", present: grok, doneHooked: fm.fileExists(atPath: grokHookURL.path), approvalsHooked: nil),
            Link(id: "cursor", name: "Cursor", present: cursor, doneHooked: isCursorInstalled(), approvalsHooked: nil),
            Link(id: "droid", name: "Droid", present: droid,
                 doneHooked: isClaudeStyleInstalled(at: droidSettingsURL, event: "Stop"), approvalsHooked: nil),
            Link(id: "antigravity", name: "Antigravity", present: antigravityPresent,
                 doneHooked: isAntigravityInstalled(), approvalsHooked: nil),
            Link(id: "copilot", name: "Copilot CLI", present: copilot,
                 doneHooked: fm.fileExists(atPath: copilotHookURL.path), approvalsHooked: nil),
            Link(id: "kimi", name: "Kimi Code", present: kimi, doneHooked: isKimiInstalled(), approvalsHooked: nil),
            Link(id: "gemini-api", name: "Gemini CLI", present: geminiCLIPresent,
                 doneHooked: isClaudeStyleInstalled(at: geminiSettingsURL, event: "AfterAgent"), approvalsHooked: nil),
            Link(id: "opencode", name: "OpenCode", present: openCodePresent,
                 doneHooked: fm.fileExists(atPath: openCodePluginURL.path), approvalsHooked: nil),
        ]
    }

    static func isCodexInstalled(at url: URL = codexConfigURL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return notifyArray(in: text)?.dropFirst().first == codexMarker
    }

    static func isCursorInstalled(at url: URL = cursorHooksURL) -> Bool {
        guard let hooks = read(url)?["hooks"] as? [String: Any],
              let stop = hooks["stop"] as? [[String: Any]] else { return false }
        return stop.contains { isOurs($0["command"]) }
    }

    /// Everything pillr ever added to an agent, taken out — every done hook,
    /// Claude Code's approval hook, and Codex's notify put back as it was —
    /// and no more until the person turns them on again. Before the app goes
    /// to the Trash; `pillr --uninstall` does the same from a terminal.
    /// Returns the agents it took something out of.
    @discardableResult
    static func removeEverything(defaults: UserDefaults = .standard) -> [String] {
        let before = links().filter(\.doneHooked).map(\.name)
        let approvals = ClaudeHookInstaller.isInstalled()
        removeAll()
        if approvals { try? ClaudeHookInstaller.remove() }
        defaults.set(false, forKey: HookConsent.key)
        let names = before + (approvals && !before.contains("Claude Code") ? ["Claude Code"] : [])
        return names
    }

    static func removeAll() {
        if ClaudeHookInstaller.isStopInstalled() { try? ClaudeHookInstaller.removeStop() }
        try? removeGrok()
        try? removeCursor()
        try? removeCodex()
        try? removeClaudeStyle(at: droidSettingsURL, event: "Stop")
        try? removeAntigravity()
        try? removeCopilot()
        try? removeKimi()
        try? removeClaudeStyle(at: geminiSettingsURL, event: "AfterAgent")
        try? removeOpenCode()
    }

    // MARK: Grok

    static var grokHookURL: URL { home.appendingPathComponent(".grok/hooks/pillr.json") }

    static func installGrok(executable: String, at url: URL = grokHookURL) throws {
        let json: [String: Any] = ["hooks": ["Stop": [["hooks": [[
            "type": "command", "command": stopCommand(executable: executable, agent: "grok"),
            "timeout": ClaudeHookInstaller.stopTimeoutSeconds,
        ]]]]]]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(json, to: url)
    }

    static func removeGrok(at url: URL = grokHookURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Cursor

    static var cursorHooksURL: URL { home.appendingPathComponent(".cursor/hooks.json") }

    static func installCursor(executable: String, at url: URL = cursorHooksURL) throws {
        guard var json = read(url) ?? (FileManager.default.fileExists(atPath: url.path) ? nil : ["version": 1]) else {
            return   // there, but not JSON pillr can read: left alone rather than replaced
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var stop = (hooks["stop"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"]) }
        stop.append(["command": stopCommand(executable: executable, agent: "cursor")])
        hooks["stop"] = stop
        json["hooks"] = hooks
        try write(json, to: url)
    }

    static func removeCursor(at url: URL = cursorHooksURL) throws {
        guard var json = read(url), var hooks = json["hooks"] as? [String: Any],
              let stop = hooks["stop"] as? [[String: Any]], stop.contains(where: { isOurs($0["command"]) }) else { return }
        let kept = stop.filter { !isOurs($0["command"]) }
        if kept.isEmpty { hooks.removeValue(forKey: "stop") } else { hooks["stop"] = kept }
        json["hooks"] = hooks
        try write(json, to: url)
    }

    private static func isOurs(_ command: Any?) -> Bool {
        (command as? String)?.contains(ClaudeHookInstaller.stopMarker) == true
    }

    // MARK: Claude-style hooks (Droid)

    /// Factory Droid reads Claude Code's hook shape under `hooks` in
    /// `~/.factory/settings.json`: `Stop` once a turn is over, with
    /// `session_id`, `cwd` and `hook_event_name` on stdin.
    static var droidSettingsURL: URL { home.appendingPathComponent(".factory/settings.json") }

    /// `timeout` in the agent's own unit — seconds for Droid, milliseconds
    /// for Gemini CLI.
    static func installClaudeStyle(at url: URL, event: String, agent: String, executable: String,
                                   timeout: Int = ClaudeHookInstaller.stopTimeoutSeconds, matcher: String? = nil) throws {
        guard var json = read(url) ?? (FileManager.default.fileExists(atPath: url.path) ? nil : [:]) else { return }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !isOursEntry($0) }
        var entry: [String: Any] = ["hooks": [[
            "type": "command", "command": stopCommand(executable: executable, agent: agent),
            "timeout": timeout, "name": "pillr",
        ]]]
        if let matcher { entry["matcher"] = matcher }
        entries.append(entry)
        hooks[event] = entries
        json["hooks"] = hooks
        try write(json, to: url)
    }

    static func removeClaudeStyle(at url: URL, event: String) throws {
        guard var json = read(url), var hooks = json["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]], entries.contains(where: isOursEntry) else { return }
        let kept = entries.filter { !isOursEntry($0) }
        if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        json["hooks"] = hooks
        try write(json, to: url)
    }

    static func isClaudeStyleInstalled(at url: URL, event: String) -> Bool {
        guard let hooks = read(url)?["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return false }
        return entries.contains(where: isOursEntry)
    }

    private static func isOursEntry(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"]) }
    }

    // MARK: Antigravity

    /// Antigravity's global hooks, keyed by a name of the hook's own — pillr's
    /// is `pillr`. `Stop` carries `conversationId`, `workspacePaths` and
    /// `fullyIdle`; only a fully idle stop is the answer's end.
    static var antigravityHooksURL: URL { home.appendingPathComponent(".gemini/config/hooks.json") }

    /// The app itself, not only the folder it leaves behind in `~/.gemini`.
    static var antigravityPresent: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") != nil
            && ["antigravity", "antigravity-ide"].contains {
                FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/\($0)").path)
            }
    }

    static func installAntigravity(executable: String, at url: URL = antigravityHooksURL) throws {
        guard var json = read(url) ?? (FileManager.default.fileExists(atPath: url.path) ? nil : [:]) else { return }
        json["pillr"] = ["enabled": true, "Stop": [[
            "type": "command", "command": stopCommand(executable: executable, agent: "antigravity"),
            "timeout": ClaudeHookInstaller.stopTimeoutSeconds,
        ]]]
        try write(json, to: url)
    }

    static func removeAntigravity(at url: URL = antigravityHooksURL) throws {
        guard var json = read(url), json["pillr"] != nil else { return }
        json.removeValue(forKey: "pillr")
        try write(json, to: url)
    }

    static func isAntigravityInstalled(at url: URL = antigravityHooksURL) -> Bool {
        (read(url)?["pillr"] as? [String: Any])?["enabled"] as? Bool == true
    }

    // MARK: Copilot CLI

    /// A hooks file of pillr's own among Copilot CLI's: `agentStop` once the
    /// agent has finished its turn, with `sessionId` and `cwd` on stdin.
    static var copilotHookURL: URL { home.appendingPathComponent(".copilot/hooks/pillr.json") }

    static func installCopilot(executable: String, at url: URL = copilotHookURL) throws {
        let json: [String: Any] = ["version": 1, "hooks": ["agentStop": [[
            "type": "command", "bash": stopCommand(executable: executable, agent: "copilot"),
            "timeoutSec": ClaudeHookInstaller.stopTimeoutSeconds,
        ]]]]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(json, to: url)
    }

    static func removeCopilot(at url: URL = copilotHookURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Gemini CLI

    /// Gemini CLI's `AfterAgent` hook, Claude's shape under `hooks` in
    /// `~/.gemini/settings.json`: once per turn, after the final answer,
    /// never for a subagent. Its timeout is in milliseconds.
    static var geminiSettingsURL: URL { home.appendingPathComponent(".gemini/settings.json") }

    /// The CLI itself: `~/.gemini` alone is also Antigravity's, and other
    /// tools write hooks there too.
    static var geminiCLIPresent: Bool {
        ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "~/.local/bin/gemini", "~/.npm-global/bin/gemini",
         "~/.gemini/tmp", "~/.gemini/projects.json"]
            .contains { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) }
    }

    // MARK: OpenCode

    /// OpenCode has no hook file, only plugins: pillr's is one small file of
    /// its own in `~/.config/opencode/plugins/`. When a session goes idle —
    /// not a subagent's child session — it hands the hook client the same
    /// JSON every other agent's stop sends.
    static var openCodePluginURL: URL { home.appendingPathComponent(".config/opencode/plugins/pillr.js") }

    static var openCodePresent: Bool {
        ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "~/.opencode/bin/opencode", "~/.local/bin/opencode",
         "~/.local/share/opencode/opencode.db"]
            .contains { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) }
    }

    static func openCodePlugin(executable: String) -> String {
        let exe = String(data: (try? JSONSerialization.data(withJSONObject: [executable])) ?? Data(), encoding: .utf8)
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        // pillr: says in the notch when an OpenCode session is done. Written by
        // pillr; removed when its done cards are switched off. \(ClaudeHookInstaller.stopMarker)
        const pillr = \(exe)

        export const Pillr = async ({ $, client, directory }) => ({
          event: async ({ event }) => {
            if (event.type !== "session.status" || event.properties?.status?.type !== "idle") return
            const id = event.properties.sessionID
            try {
              const session = await client.session.get({ path: { id } })
              if (session?.data?.parentID) return
            } catch {}
            const payload = JSON.stringify({ session_id: id, cwd: directory, hook_event_name: "Stop" })
            await $`printf %s ${payload} | ${pillr} --stop-hook --agent opencode`.quiet().nothrow()
          },
        })

        """
    }

    static func installOpenCode(executable: String, at url: URL = openCodePluginURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EffortTargetWriter.replaceContents(of: url, with: openCodePlugin(executable: executable))
    }

    /// Only a file pillr wrote: one that carries its marker.
    static func removeOpenCode(at url: URL = openCodePluginURL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains(ClaudeHookInstaller.stopMarker) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Kimi Code

    /// Kimi Code's hooks are `[[hooks]]` tables in `~/.kimi-code/config.toml`;
    /// pillr's is one block — `event = "Stop"` — appended at the end, and the
    /// only one ever taken out.
    static var kimiConfigURL: URL { home.appendingPathComponent(".kimi-code/config.toml") }

    static func installKimi(executable: String, at url: URL = kimiConfigURL) throws {
        let text = removingKimiBlock(from: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        let body = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        let block = "[[hooks]]\nevent = \"Stop\"\ncommand = \(tomlString(stopCommand(executable: executable, agent: "kimi")))\n"
            + "timeout = \(ClaudeHookInstaller.stopTimeoutSeconds)\n"
        try EffortTargetWriter.replaceContents(of: url, with: body + (body.isEmpty ? "" : "\n") + block)
    }

    static func removeKimi(at url: URL = kimiConfigURL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8), isKimiInstalled(at: url) else { return }
        try EffortTargetWriter.replaceContents(of: url, with: removingKimiBlock(from: text))
    }

    static func isKimiInstalled(at url: URL = kimiConfigURL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text != removingKimiBlock(from: text)
    }

    /// The text without pillr's `[[hooks]]` block: from its header to the next
    /// header, the blank line before it included.
    static func removingKimiBlock(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard lines[index].trimmingCharacters(in: .whitespaces) == "[[hooks]]" else { index += 1; continue }
            var end = index + 1
            // To the next header — or the file's end, short of its last line
            // break, which belongs to the file and not to the block.
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("["),
                  !(end == lines.count - 1 && lines[end].isEmpty) { end += 1 }
            let block = lines[index..<end].joined(separator: "\n")
            if block.contains(ClaudeHookInstaller.stopMarker) && block.contains("--agent kimi") {
                var start = index
                if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
                lines.removeSubrange(start..<end)
                index = start
            } else {
                index = end
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Codex

    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }

    static func installCodex(executable: String, at url: URL = codexConfigURL) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let current = notifyArray(in: text)
        if let current, current.first == executable, current.dropFirst().first == codexMarker { return }
        var value = [executable, codexMarker]
        // Someone else's notify program goes on being called, after pillr.
        if let current, !current.isEmpty, !(current.dropFirst().first == codexMarker) {
            value += [thenMarker] + current
        }
        try EffortTargetWriter.replaceContents(of: url, with: settingNotify(value, in: text))
    }

    static func removeCodex(at url: URL = codexConfigURL) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let current = notifyArray(in: text), current.dropFirst().first == codexMarker else { return }
        // What was there before pillr, or nothing.
        let original = current.firstIndex(of: thenMarker).map { Array(current[($0 + 1)...]) } ?? []
        try EffortTargetWriter.replaceContents(of: url, with: settingNotify(original.isEmpty ? nil : original, in: text))
    }

    /// The top-level `notify = [ … ]` array, across lines, as strings.
    static func notifyArray(in text: String) -> [String]? {
        guard let range = notifyRange(in: text) else { return nil }
        return parseStrings(String(text[range]))
    }

    /// `notify` set to `value` (or removed, for nil), in place when it was
    /// there, else before the first table — where a top-level key belongs.
    static func settingNotify(_ value: [String]?, in text: String) -> String {
        let line = value.map { "notify = [" + $0.map(tomlString).joined(separator: ", ") + "]" }
        if let range = notifyRange(in: text) {
            var out = text
            if let line {
                out.replaceSubrange(range, with: line)
            } else {
                var end = range.upperBound
                if end < out.endIndex, out[end] == "\n" { end = out.index(after: end) }
                out.removeSubrange(range.lowerBound..<end)
            }
            return out
        }
        guard let line else { return text }
        if let table = text.range(of: #"(?m)^\s*\["#, options: .regularExpression) {
            var out = text
            out.insert(contentsOf: line + "\n\n", at: table.lowerBound)
            return out
        }
        return text.isEmpty || text.hasSuffix("\n") ? text + line + "\n" : text + "\n" + line + "\n"
    }

    /// From `notify` to its closing bracket, if it is a top-level key.
    private static func notifyRange(in text: String) -> Range<String.Index>? {
        let firstTable = text.range(of: #"(?m)^\s*\["#, options: .regularExpression)?.lowerBound ?? text.endIndex
        guard let start = text.range(of: #"(?m)^notify\s*=\s*\["#, options: .regularExpression),
              start.lowerBound < firstTable else { return nil }
        var index = start.upperBound
        var quote: Character?
        while index < text.endIndex {
            let c = text[index]
            if let q = quote {
                if c == "\\" && q == "\"" { index = text.index(after: index) }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "]" {
                return start.lowerBound..<text.index(after: index)
            }
            if index < text.endIndex { index = text.index(after: index) }
        }
        return nil
    }

    private static func parseStrings(_ array: String) -> [String] {
        var out: [String] = []
        var current: String?
        var quote: Character?
        var escaped = false
        for c in array {
            if let q = quote {
                if escaped { current?.append(c == "n" ? "\n" : c == "t" ? "\t" : c); escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q { out.append(current ?? ""); current = nil; quote = nil }
                else { current?.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; current = ""
            }
        }
        return out
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: JSON files

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func write(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try EffortTargetWriter.replaceContents(of: url, with: String(decoding: data, as: UTF8.self) + "\n")
    }
}
