import Foundation

/// Adds and removes the `PermissionRequest` hook that routes Claude Code's
/// prompts to the notch, in `~/.claude/settings.json`.
///
/// Only ever touches its own entry — recognised by the `--prompt-hook` in
/// its command — and leaves every other hook and setting as it was. Off
/// until the person turns it on in Settings.
enum ClaudeHookInstaller {
    enum InstallError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let path): return "\(path) isn't valid JSON; left as it is" }
        }
    }

    static let marker = "--prompt-hook"
    /// A day: a question waits in the notch for someone who stepped away,
    /// rather than slipping back into a terminal nobody is looking at. The
    /// broker still lets go first (`PromptBroker.patience`), and much sooner
    /// whenever the person is there and goes to the session — see
    /// `AppDelegate.startPromptBroker`. If pillr quits, the hook's
    /// connection closes and Claude asks for itself at once.
    static let timeoutSeconds = 86_400

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func command(executable: String) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' \(marker)"
    }

    static func isInstalled(at url: URL = settingsURL) -> Bool {
        guard let json = read(url) else { return false }
        return entries(in: json).contains { ours($0) }
    }

    /// Installs, or re-points an existing entry at `executable`.
    static func install(executable: String, at url: URL = settingsURL) throws {
        // A file that is there but does not parse — mid-edit, a trailing
        // comma — is left alone: replacing it would take the person's
        // permissions, env and model with it.
        guard var json = read(url) ?? (FileManager.default.fileExists(atPath: url.path) ? nil : [:]) else {
            throw InstallError.unreadable(url.path)
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var groups = (hooks["PermissionRequest"] as? [[String: Any]] ?? []).filter { !ours($0) }
        groups.append([
            "matcher": "*",
            "hooks": [["type": "command", "command": command(executable: executable), "timeout": timeoutSeconds]],
        ])
        hooks["PermissionRequest"] = groups
        json["hooks"] = hooks
        try write(json, to: url)
    }

    static func remove(at url: URL = settingsURL) throws {
        guard var json = read(url), var hooks = json["hooks"] as? [String: Any] else { return }
        let groups = (hooks["PermissionRequest"] as? [[String: Any]] ?? []).filter { !ours($0) }
        if groups.isEmpty { hooks.removeValue(forKey: "PermissionRequest") } else { hooks["PermissionRequest"] = groups }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        try write(json, to: url)
    }

    // MARK: The Stop hook

    /// Claude Code runs Stop the moment the main agent has finished its
    /// answer: the done card's real-time signal, instead of a guess from
    /// the session's status file.
    static let stopMarker = "--stop-hook"
    static let stopTimeoutSeconds = 5

    static func stopCommand(executable: String) -> String {
        "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' \(stopMarker)"
    }

    static func isStopInstalled(at url: URL = settingsURL) -> Bool {
        guard let json = read(url) else { return false }
        return ((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []).contains { ours($0, marker: stopMarker) }
    }

    static func installStop(executable: String, at url: URL = settingsURL) throws {
        // A file that is there but does not parse — mid-edit, a trailing
        // comma — is left alone: replacing it would take the person's
        // permissions, env and model with it.
        guard var json = read(url) ?? (FileManager.default.fileExists(atPath: url.path) ? nil : [:]) else {
            throw InstallError.unreadable(url.path)
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var groups = (hooks["Stop"] as? [[String: Any]] ?? []).filter { !ours($0, marker: stopMarker) }
        groups.append(["hooks": [["type": "command", "command": stopCommand(executable: executable),
                                  "timeout": stopTimeoutSeconds]]])
        hooks["Stop"] = groups
        json["hooks"] = hooks
        try write(json, to: url)
    }

    static func removeStop(at url: URL = settingsURL) throws {
        guard var json = read(url), var hooks = json["hooks"] as? [String: Any] else { return }
        let groups = (hooks["Stop"] as? [[String: Any]] ?? []).filter { !ours($0, marker: stopMarker) }
        if groups.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = groups }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        try write(json, to: url)
    }

    // MARK: -

    private static func ours(_ group: [String: Any], marker: String) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func entries(in json: [String: Any]) -> [[String: Any]] {
        (json["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
    }

    private static func ours(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func write(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try EffortTargetWriter.replaceContents(of: url, with: String(decoding: data, as: UTF8.self) + "\n")
    }
}

/// Which running session a hook's `session_id` belongs to, from Claude
/// Code's own registry — the same files the session monitor reads.
enum ClaudeSessionLookup {
    static func pid(forSessionID id: String) -> pid_t? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["sessionId"] as? String == id else { continue }
            return (json["pid"] as? NSNumber)?.int32Value ?? Int32(file.deletingPathExtension().lastPathComponent)
        }
        return nil
    }
}
