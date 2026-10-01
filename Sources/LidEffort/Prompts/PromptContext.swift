import Foundation

/// Which piece of work a prompt belongs to, for when several sessions are
/// running: what you last asked that session, what Claude said just before
/// it asked, the session's own name, and the branch it is on.
///
/// Read once, when the prompt arrives, from the tail of the transcript the
/// hook names — the whole file can run to tens of megabytes.
struct PromptContext: Equatable {
    /// The session's title — "PillLid".
    var title: String?
    /// Your last message to that session.
    var ask: String?
    /// What Claude said just before asking: usually why it asks.
    var lead: String?
    /// The git branch of the session's folder.
    var branch: String?

    var isEmpty: Bool { ask == nil && lead == nil }

    /// How much of the transcript's end is read.
    static let tailBytes = 256 * 1024

    static func load(transcript path: String?, cwd: String?) -> PromptContext? {
        var context = PromptContext()
        if let path, let tail = readTail(of: path, bytes: tailBytes) {
            context = parse(transcriptTail: tail)
        }
        context.branch = cwd.flatMap(GitBranch.read(at:))
        return context == PromptContext() ? nil : context
    }

    /// The transcript's last lines, JSON per line, newest last.
    static func parse(transcriptTail text: String) -> PromptContext {
        var context = PromptContext()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail read mid-file starts part-way through a line.
        if !text.hasPrefix("{") { lines = Array(lines.dropFirst()) }
        // Newest first. Claude's words count only until your own message is
        // reached; `last-prompt` is written again and again at the end, so
        // it cannot be the place to stop.
        var reachedYourMessage = false
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if entry["isSidechain"] as? Bool == true { continue }
            switch entry["type"] as? String {
            case "custom-title":
                if context.title == nil { context.title = entry["customTitle"] as? String }
            case "agent-name":
                if context.title == nil { context.title = entry["agentName"] as? String }
            case "last-prompt":
                if context.ask == nil { context.ask = clean(entry["lastPrompt"] as? String) }
            case "assistant":
                if !reachedYourMessage, context.lead == nil,
                   let text = texts(of: entry).last(where: { !$0.isEmpty }) {
                    context.lead = clean(text)
                }
            case "user":
                if entry["isMeta"] as? Bool != true,
                   let text = texts(of: entry).last, !text.hasPrefix("<") {
                    reachedYourMessage = true
                    if context.ask == nil { context.ask = clean(text) }
                }
            default:
                break
            }
            if reachedYourMessage, context.title != nil { break }
        }
        return context
    }

    /// The text blocks of a message, whichever shape it was written in.
    private static func texts(of entry: [String: Any]) -> [String] {
        let content = (entry["message"] as? [String: Any])?["content"]
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    }

    /// One line of plain words: markdown marks and runs of space gone, cut
    /// to a length a card line can carry.
    static func clean(_ text: String?) -> String? {
        guard var text else { return nil }
        for mark in ["**", "__", "`", "#"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "*-• ").union(.whitespaces))
        guard !text.isEmpty else { return nil }
        return text.count > 160 ? String(text.prefix(159)) + "…" : text
    }

    private static func readTail(of path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The branch a folder is checked out on, read from `.git/HEAD` — no git
/// process. Worktrees, whose `.git` is a file pointing elsewhere, too.
enum GitBranch {
    static func read(at folder: String) -> String? {
        var url = URL(fileURLWithPath: folder)
        for _ in 0..<12 {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDir = dotGit
                if !isDirectory.boolValue {
                    guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = pointer.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, relativeTo: url)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                return parse(head: head)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    static func parse(head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
        return line.count >= 7 ? String(line.prefix(7)) : nil
    }
}
