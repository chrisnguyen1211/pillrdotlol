import Darwin
import Foundation

/// Notices a prompt the notch is holding that was answered somewhere else:
/// in the terminal, or in the Claude app.
///
/// Claude Code puts its own dialog up while the PermissionRequest hook runs
/// and keeps whichever answer comes first. When the dialog wins, it does not
/// stop the hook: the hook process stays connected until its own timeout,
/// which is a day (`ClaudeHookInstaller.timeoutSeconds`), so the broker never
/// sees it go. Left alone, the card would stay in the notch, reminders and
/// all, for a question nobody is asking any more.
///
/// So the app looks, every few seconds, at what Claude Code writes down
/// anyway, most trusted first:
///
/// - the session's process has exited;
/// - its registry entry (`~/.claude/sessions/<pid>.json`) said it was
///   waiting on a prompt after this one arrived, and no longer does;
/// - its transcript holds the result of the very tool call that asked.
///
/// A settled prompt is let go of with no answer at all (`PromptBroker.release`):
/// a hook that hands back no decision is no opinion to Claude Code, which has
/// its answer by then anyway. Even a wrong guess here costs only the card,
/// never a decision: Claude's own dialog is still there.
struct PromptSettlement {
    /// What the session's registry entry says it is doing.
    enum SessionStatus: Equatable {
        /// A dialog is up: a permission, a question, some other request.
        case waiting
        /// Working or idle: no dialog.
        case movedOn
        /// No entry, no status in it, or one that is not this session's.
        case unknown
    }

    /// One look at a prompt's session.
    struct Observation: Equatable {
        /// Whether the session's process is still running; nil when the
        /// prompt names no process.
        var processAlive: Bool? = nil
        var status: SessionStatus = .unknown
        /// The end of the transcript, only when it changed since the last
        /// look: nil is "nothing new", not "nothing there".
        var transcriptTail: String? = nil
    }

    /// Where Claude Code keeps one file per running session.
    let sessionsDirectory: URL

    /// Prompts whose session has been seen waiting since they arrived. Only
    /// after that does a session that is not waiting mean an answer: the
    /// hook can reach the app before Claude Code has written down that its
    /// dialog is up, and "busy" then is from before the prompt.
    private var sawWaiting: Set<UUID> = []
    /// The tool call each prompt turned out to be, once found in its
    /// transcript: its result then settles it even after a long output has
    /// pushed the call itself out of the part that is read.
    private var toolUseIDs: [UUID: String] = [:]
    /// The transcript's size and date at the last read, per prompt.
    private var transcriptStamps: [UUID: TranscriptStamp] = [:]

    private struct TranscriptStamp: Equatable {
        let size: UInt64
        let modified: Date?
    }

    /// How much of a transcript's end is read: more than the card's context
    /// needs, so a call followed by a long result is still found.
    static let tailBytes = 1024 * 1024

    init(sessionsDirectory: URL? = nil) {
        self.sessionsDirectory = sessionsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }

    /// Whether this look shows the prompt answered elsewhere. Remembers what
    /// it saw for the next look.
    mutating func isSettled(_ prompt: PendingPrompt, seeing observation: Observation) -> Bool {
        if observation.processAlive == false { return true }
        switch observation.status {
        case .waiting:
            sawWaiting.insert(prompt.id)
        case .movedOn:
            if sawWaiting.contains(prompt.id) { return true }
        case .unknown:
            break
        }
        if let tail = observation.transcriptTail {
            switch PromptTranscript.find(prompt, knownToolUseID: toolUseIDs[prompt.id], in: tail) {
            case .answered: return true
            case .pending(let id): toolUseIDs[prompt.id] = id
            case .unknown: break
            }
        }
        return false
    }

    /// Drops what is remembered about prompts that are no longer held.
    mutating func keep(only ids: Set<UUID>) {
        sawWaiting.formIntersection(ids)
        toolUseIDs = toolUseIDs.filter { ids.contains($0.key) }
        transcriptStamps = transcriptStamps.filter { ids.contains($0.key) }
    }

    // MARK: - Looking

    /// Reads, now, what Claude Code has written about the prompt's session.
    /// The transcript is read only when it has changed since the last look.
    mutating func observe(_ prompt: PendingPrompt) -> Observation {
        var observation = Observation()
        if let pid = prompt.pid {
            observation.processAlive = Self.isRunning(pid)
            let record = sessionsDirectory.appendingPathComponent("\(pid).json")
            if let data = try? Data(contentsOf: record),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                observation.status = Self.status(record: json, sessionID: prompt.sessionID)
            }
        }
        if let path = prompt.transcriptPath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            let stamp = TranscriptStamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                                        modified: attributes[.modificationDate] as? Date)
            if transcriptStamps[prompt.id] != stamp {
                transcriptStamps[prompt.id] = stamp
                observation.transcriptTail = Self.readTail(of: path, bytes: Self.tailBytes)
            }
        }
        return observation
    }

    /// The registry entry's `status`, as Claude Code's terminal interface
    /// writes it: "waiting" for as long as any dialog is up.
    static func status(record json: [String: Any], sessionID: String?) -> SessionStatus {
        if let sessionID, let theirs = json["sessionId"] as? String, theirs != sessionID { return .unknown }
        switch json["status"] as? String {
        case "waiting": return .waiting
        case "busy", "idle", "shell": return .movedOn
        default: return .unknown
        }
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
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

/// Finds a prompt's tool call in its session's transcript, and whether that
/// call has a result yet.
///
/// The hook's payload carries no tool call id, so the call is recognised by
/// what it asks: the same tool, with the same command, path or question.
enum PromptTranscript {
    enum Finding: Equatable {
        /// No call like it, or only an older one that had finished before
        /// the prompt arrived: nothing to go on yet.
        case unknown
        /// The call is there and has no result: still being asked.
        case pending(toolUseID: String)
        /// Its result is written: answered, wherever that was.
        case answered
    }

    /// A clock step between the hook's arrival and the transcript's own
    /// timestamps is not an answer from before the prompt.
    static let clockSlack: TimeInterval = 2

    static func find(_ prompt: PendingPrompt, knownToolUseID: String?, in tail: String) -> Finding {
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        // A tail read mid-file starts part-way through a line.
        if !tail.hasPrefix("{") { lines = Array(lines.dropFirst()) }

        var latestCall: String?
        var results: [String: Date?] = [:]
        for line in lines {
            // Cheap first: most lines are neither a call nor a result.
            guard line.contains("tool_use") || line.contains("tool_result"),
                  let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    if knownToolUseID == nil, let id = block["id"] as? String,
                       let name = block["name"] as? String,
                       matches(prompt, name: name, input: block["input"] as? [String: Any] ?? [:]) {
                        latestCall = id
                    }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String {
                        results.updateValue((entry["timestamp"] as? String).flatMap(date), forKey: id)
                    }
                default:
                    break
                }
            }
        }

        if let knownToolUseID {
            return results.keys.contains(knownToolUseID) ? .answered : .pending(toolUseID: knownToolUseID)
        }
        guard let latestCall else { return .unknown }
        guard let result = results[latestCall] else { return .pending(toolUseID: latestCall) }
        // Finished before the prompt arrived: an earlier run of the same
        // command, and this prompt's own call is not written yet.
        guard let at = result, at >= prompt.receivedAt.addingTimeInterval(-clockSlack) else { return .unknown }
        return .answered
    }

    /// Whether a call in the transcript is the one the prompt is about.
    static func matches(_ prompt: PendingPrompt, name: String, input: [String: Any]) -> Bool {
        guard name == prompt.toolName else { return false }
        if prompt.isQuestion {
            let asked = (input["questions"] as? [[String: Any]] ?? []).compactMap { $0["question"] as? String }
            return asked == prompt.questions.map(\.question)
        }
        // Every piece of text both sides carry must agree — the command,
        // the path, the address — and there must be at least one: a call
        // with nothing to compare is not recognised rather than guessed.
        var compared = 0
        for (key, value) in prompt.toolInput {
            guard let mine = value.base as? String, let theirs = input[key] as? String else { continue }
            guard mine == theirs else { return false }
            compared += 1
        }
        return compared > 0
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    private static func date(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }
}
