import Foundation

/// Which command a person types to reach each Claude login.
///
/// A second login is reached through a command of the person's own — a
/// `claude-work` wrapper in `~/.local/bin`, an alias in `.zshrc` — that sets
/// `CLAUDE_CONFIG_DIR` and runs `claude`. Settings named the directory but not
/// the command, so two rows told you whose account each was and not how to
/// open it, nor which one plain `claude` lands in.
///
/// Found by reading, never running: a wrapper is a few lines of shell, and the
/// only thing taken from it is the directory it sets. Anything that does not
/// look like one — a binary, a script that never runs `claude` — is skipped.
enum ClaudeLaunchCommands {
    /// Where wrappers are kept. pillr is launched from Finder, so `PATH` is
    /// the bare system one and cannot be asked.
    static func defaultSearchDirectories(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin"), home.appendingPathComponent("bin"),
         URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    }

    static func defaultRCFiles(home: URL) -> [URL] {
        [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".aliases"].map { home.appendingPathComponent($0) }
    }

    /// Command names keyed by the configuration directory's path. Plain
    /// `claude` always opens `~/.claude`, so it is always listed there first.
    static func find(home: URL = ClaudeProfile.homeDirectory,
                     searchDirectories: [URL]? = nil,
                     rcFiles: [URL]? = nil,
                     fileManager: FileManager = .default) -> [String: [String]] {
        let defaultPath = ClaudeProfile.default(home: home).configDirectory.standardizedFileURL.path
        var found: [String: [String]] = [defaultPath: ["claude"]]
        func add(_ name: String, body: String) {
            guard runsClaude(body) else { return }
            let path = configDirectory(in: body, home: home)?.standardizedFileURL.path ?? defaultPath
            if found[path, default: []].contains(name) { return }
            found[path, default: []].append(name)
        }

        for directory in searchDirectories ?? defaultSearchDirectories(home: home) {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.hasPrefix("claude") && name != "claude" {
                let url = directory.appendingPathComponent(name)
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                let data = (try? handle.read(upToCount: 16_384)) ?? Data()
                try? handle.close()
                guard data.starts(with: Array("#!".utf8)),
                      let text = String(data: data, encoding: .utf8) else { continue }
                add(name, body: uncommented(text))
            }
        }

        for rc in rcFiles ?? defaultRCFiles(home: home) {
            guard let text = try? String(contentsOf: rc, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let (name, body) = alias(in: String(line)) else { continue }
                add(name, body: body)
            }
        }
        return found
    }

    // MARK: - Reading shell

    private static func uncommented(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// `claude` run as a command: on its own or as a path's last part.
    private static func runsClaude(_ body: String) -> Bool {
        body.range(of: #"(^|[\s;/"'&|(])claude($|[\s;"'&|)])"#, options: .regularExpression) != nil
    }

    /// `alias name='body'` or `alias name="body"`, nil for anything else.
    private static func alias(in line: String) -> (String, String)? {
        let pattern = #"^\s*alias\s+([A-Za-z0-9_.-]+)=(['"])(.*)\2\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let name = Range(match.range(at: 1), in: line), let body = Range(match.range(at: 3), in: line)
        else { return nil }
        return (String(line[name]), String(line[body]))
    }

    /// The directory `CLAUDE_CONFIG_DIR=` sets, with `~`, `$HOME` and
    /// `${HOME}` expanded and the quotes taken off.
    static func configDirectory(in body: String, home: URL) -> URL? {
        let pattern = #"CLAUDE_CONFIG_DIR=(?:"([^"]*)"|'([^']*)'|([^\s;&|"']+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else { return nil }
        let value = (1...3).lazy.compactMap { Range(match.range(at: $0), in: body).map { String(body[$0]) } }.first ?? ""
        var path = value.replacingOccurrences(of: "${HOME}", with: home.path)
            .replacingOccurrences(of: "$HOME", with: home.path)
        if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}

extension ClaudeProfile {
    /// The line under this login's row: the commands that open it, and for
    /// `~/.claude` that it is the one plain `claude` opens. A login nobody has
    /// written a command for gets the one that always works.
    func launchLine(commands: [String: [String]]) -> String {
        let list = launchCommands(commands).joined(separator: ", ")
        return slug == nil ? L10n.t("Default login · open with \(list)") : L10n.t("Open with \(list)")
    }

    /// The commands alone, for drawing them apart from the words around them.
    func launchCommands(_ commands: [String: [String]]) -> [String] {
        let found = commands[configDirectory.standardizedFileURL.path] ?? []
        return found.isEmpty ? [signInCommand] : found
    }
}
