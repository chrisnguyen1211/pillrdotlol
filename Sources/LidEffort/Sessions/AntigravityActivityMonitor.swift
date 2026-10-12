import Combine
import Foundation
import SQLite3

/// Notices when Antigravity is working.
///
/// Its transcripts are appended to as an agent runs, so a file written moments
/// ago is a turn in progress. The step *statuses* cannot be used for this —
/// every one of them says `DONE`, because a step is only written once it is
/// finished. Recency is the signal there is.
///
/// Without this the Gemini ring never showed the working state that Claude,
/// Cursor and Codex all had, and the store never learned Antigravity was busy,
/// so it stayed on its slow idle poll while usage was actively being spent.
final class AntigravityActivityMonitor: AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let roots: [URL]
    private let interval: TimeInterval
    /// How recently a transcript must have been written to count as live.
    /// Generous, because a model can think for a while between two lines.
    private let staleAfter: TimeInterval
    private var timer: Timer?
    /// When each conversation was first seen waiting on a permission.
    private var permissionSince: [String: Date] = [:]

    /// How long a step must sit waiting on a permission before it is said
    /// to be: one Antigravity runs on its own, because the person already
    /// allowed it, passes through that status for an instant, and the card
    /// came up and went at once.
    static let permissionHold: TimeInterval = 4

    init(roots: [URL] = AntigravityActivity.transcriptRoots,
         interval: TimeInterval = 2,
         staleAfter: TimeInterval = 45) {
        self.roots = roots
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        stop()
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let found = Self.settle(Self.read(roots: roots, staleAfter: staleAfter), since: &permissionSince)
        guard found != sessions else { return }
        sessions = found
    }

    /// A wait on a permission counts only once it has lasted
    /// `permissionHold`; until then the session reads as working.
    static func settle(_ found: [AgentSession], since: inout [String: Date], now: Date = Date(),
                       hold: TimeInterval = permissionHold) -> [AgentSession] {
        let permission = L10n.t("Permission")
        let waiting = Set(found.filter { $0.state == .waiting && $0.waitingFor == permission }.map(\.id))
        since = since.filter { waiting.contains($0.key) }
        return found.map { session in
            guard waiting.contains(session.id) else { return session }
            let first = since[session.id] ?? now
            since[session.id] = first
            guard now.timeIntervalSince(first) < hold else { return session }
            var working = AgentSession(id: session.id, name: session.name, detail: L10n.t("Working"), state: .busy,
                                       waitingFor: nil, since: session.since, processID: session.processID,
                                       doing: session.doing, tokens: session.tokens).keepingModel(of: session)
            working.appThreadID = session.appThreadID
            return working
        }
    }

    /// The most recent turn across every install — the same reasoning as
    /// `AntigravityActivity.transcriptRoots`. Watching one directory meant the
    /// ring never span for anyone whose Antigravity wrote to another.
    static func read(roots: [URL], staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        roots
            .flatMap { read(root: $0, staleAfter: staleAfter, now: now) }
            .max { $0.since < $1.since }
            .map { [$0] } ?? []
    }

    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        guard let trajectories = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var newest: (url: URL, modified: Date)?
        for trajectory in trajectories {
            let transcript = trajectory
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let modified = (try? manager.attributesOfItem(atPath: transcript.path))?[.modificationDate] as? Date
            else { continue }
            if newest == nil || modified > newest!.modified {
                newest = (transcript, modified)
            }
        }

        guard let newest, let session = session(trajectory: newest.url,
                                                modified: newest.modified,
                                                staleAfter: staleAfter, now: now)
        else { return [] }
        return [session]
    }

    static func tail(of url: URL, bytes: Int = 64 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    static func parseState(inTail data: Data) -> (state: AgentSession.State, waitingFor: String?) {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        
        var isTurnOver = false
        
        for line in lines.reversed() {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            
            if type == "USER_INPUT" {
                if isTurnOver {
                    return (.idle, nil)
                } else {
                    return (.busy, nil)
                }
            } else if type == "PLANNER_RESPONSE" {
                if let toolCalls = json["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    for call in toolCalls {
                        guard let name = call["name"] as? String else { continue }
                        if name.contains("ask_question") {
                            return (.waiting, L10n.t("Question"))
                        }
                        if name.contains("multi_replace_file_content") || name.contains("write_to_file") || name.contains("replace_file_content") {
                            if let args = call["arguments"] as? [String: Any],
                               let meta = args["ArtifactMetadata"] as? [String: Any],
                               meta["RequestFeedback"] as? Bool == true {
                                return (.waiting, L10n.t("Approval"))
                            }
                        }
                    }
                    if !isTurnOver {
                        return (.busy, nil)
                    }
                } else {
                    isTurnOver = true
                }
            } else if type == "EPHEMERAL_MESSAGE" || type == "CONVERSATION_HISTORY" || type == "KNOWLEDGE_ARTIFACTS" || type == "CHECKPOINT" {
                continue
            } else {
                if !isTurnOver {
                    return (.busy, nil) // A tool response
                }
            }
        }
        
        return (.idle, nil)
    }

    /// Only a transcript written within the window counts. An older one is a
    /// finished turn, and showing it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        trajectory: URL, modified: Date, staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        var (state, waitingFor) = tail(of: trajectory).map(parseState(inTail:)) ?? (.idle, nil)
        
        if state == .busy {
            let conversationID = trajectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let dbURL = trajectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("conversations/" + conversationID + ".db")
            
            if let db = SQLiteStore.open(dbURL) {
                defer { sqlite3_close(db) }
                let rows = SQLiteStore.rows(in: db, sql: "SELECT status FROM steps ORDER BY idx DESC LIMIT 1")
                if let first = rows.first, first.first == "2" {
                    state = .waiting
                    waitingFor = L10n.t("Permission")
                }
            }
        }
        
        let age = now.timeIntervalSince(modified)
        
        if state == .idle {
            if age <= 9 {
                state = .success
            } else {
                return nil
            }
        } else if state == .busy {
            // Fallback timeout for busy state, just in case the file stops updating
            // due to a crash but the state didn't become idle.
            guard age <= staleAfter + 15 else { return nil }
        }
        // If state == .waiting, we do not expire it, it remains indefinitely.

        // The trajectory's own directory names it; the file is always
        // `transcript.jsonl`.
        let id = trajectory.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            
        let detail: String
        switch state {
        case .busy: detail = L10n.t("Working")
        case .waiting: detail = waitingFor ?? L10n.t("Waiting")
        case .success: detail = L10n.t("Complete")
        case .idle: detail = L10n.t("Idle")
        }

        return AgentSession(
            id: "antigravity.\(id)",
            name: "Antigravity",
            detail: detail,
            state: state,
            waitingFor: waitingFor,
            since: modified
        )
    }
}
