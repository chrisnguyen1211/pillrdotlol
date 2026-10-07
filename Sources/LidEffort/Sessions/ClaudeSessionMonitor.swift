import AppKit
import Combine
import Foundation

/// Watches one profile's `sessions` directory — `~/.claude/sessions` by
/// default — and publishes the Claude Code sessions that are actually running.
/// One monitor per `ClaudeProfile`; see `AppDelegate`.
///
/// The directory is watched rather than polled, because a session file appears
/// and disappears the moment a session starts and stops. The timer alongside it
/// covers the two things no file event will report: a process that died without
/// touching the directory, and — for sessions the Claude desktop app hosts —
/// what the session is *doing*, which is not in the directory at all and has to
/// be read from the transcript. See `ClaudeTranscript` for why.
@MainActor
final class ClaudeSessionMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let directory: URL
    private let livenessInterval: TimeInterval
    /// Nil leaves the monitor reading nothing but the registry, which is what
    /// the tests that only care about the registry want.
    private let transcripts: ClaudeTranscriptReader?

    /// Sessions to leave out because pillr started them, not the user.
    ///
    /// Renewing the OAuth token runs the Claude CLI, and the CLI registers a
    /// session file for the second or so it is alive, exactly like any other
    /// session. Without this the notch grows a seventh row that nobody asked
    /// for, and — worse — `isBusy` can read it as work in progress and start
    /// polling usage hard on the strength of it.
    ///
    /// The pid alone is enough: checked on this machine, the file the CLI
    /// writes carries the pid of the process pillr spawned, with no fork in
    /// between. See `ClaudeTokenRefresher`.
    var ignoredPIDs: () -> Set<Int32> = { [] }

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var livenessTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    /// `livenessInterval` doubles as how often a running session's transcript
    /// is looked at, so it matches the Codex monitor's two seconds rather than
    /// the five it used when the registry was the only thing being read. The
    /// cost of a tick is a `stat` per live session; the tail is read only when
    /// the file has grown.
    init(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions"),
        projects: URL? = nil,
        livenessInterval: TimeInterval = 2
    ) {
        self.directory = directory
        self.livenessInterval = livenessInterval
        self.transcripts = projects.map { ClaudeTranscriptReader(projects: $0) }
    }

    func start() {
        // Not idempotent by construction: a second descriptor and a second
        // timer would stack on the first pair, so stop whatever is running.
        // (`AntigravityActivityMonitor` does the same.)
        stop()
        rescan()
        watchDirectory()

        let timer = Timer(timeInterval: livenessInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    func stop() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        debounce?.cancel()
        source?.cancel()
        source = nil
    }

    private func watchDirectory() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // no directory yet; the timer still covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source.resume()
        self.source = source
    }

    /// A single state change can produce several file events; coalesce them.
    private func scheduleRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func rescan() {
        let found = Self.read(directory: directory, transcripts: transcripts,
                              ignoring: ignoredPIDs())
        guard found != sessions else { return }   // don't churn SwiftUI for nothing
        // Only on a change, so this is a handful of lines an hour rather than a
        // firehose. It is the one way to see what the notch thinks is running
        // without hovering over it:
        //
        //     log stream --predicate 'category == "sessions"' --level debug
        let summary = found.map { "\($0.name)=\($0.state)" }.joined(separator: " ")
        Log.sessions.debug("\(ClaudeProfile.tilde(self.directory.path), privacy: .public): \(summary, privacy: .public)")
        sessions = found
    }

    static func read(directory: URL,
                     transcripts: ClaudeTranscriptReader? = nil,
                     ignoring: Set<Int32> = []) -> [AgentSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let live = names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> ClaudeSessionRecord? in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let record = ClaudeSessionRecord(json: json),
                      !ignoring.contains(record.pid),
                      ProcessLiveness.isAlive(pid: record.pid, startedAt: record.startedAt)
                else { return nil }
                return record
            }
        return deduplicated(live)
            .map { record in state(of: record, transcripts: transcripts) }
            // A session in a Superset pane is named by its workspace and
            // branch, not by the folder its worktree happens to be in.
            .map(Superset.labelled)
            // The id breaks ties so the order cannot flicker between two ticks
            // that read the same thing.
            .sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The record's own answer where it has one, the transcript's where it does
    /// not. Desktop sessions always take the second path; terminal ones never
    /// do, which is what keeps their `waiting` state — the one thing only the
    /// terminal interface knows — exactly as it was.
    static func state(of record: ClaudeSessionRecord,
                      transcripts: ClaudeTranscriptReader?) -> AgentSession {
        // While it works, the step it is on — read from the transcript for
        // terminal sessions too, which otherwise never open it.
        func doing() -> AgentSession.Doing? {
            guard let sessionID = record.sessionID,
                  let url = transcripts?.transcriptURL(sessionID: sessionID, cwd: record.cwd) else { return nil }
            return SessionDoing.cached(url, parse: SessionDoing.claude(tail:))
        }
        var session = Self.session(of: record, transcripts: transcripts, doing: doing)
        // Said idle, but a command it started is still running in the
        // background and will wake it again: not finished, and not to be
        // announced as finished each time it stops between wake-ups.
        if session.state == .idle || session.state == .success,
           BackgroundShells.count(under: record.pid) > 0 {
            session = record.session(state: .busy, since: session.since,
                                     doing: AgentSession.Doing(text: L10n.t("Background task running"),
                                                               kind: .tool, since: session.since))
        }
        if let sessionID = record.sessionID,
           let url = transcripts?.transcriptURL(sessionID: sessionID, cwd: record.cwd) {
            let read = TokenTally.read(url, format: .claude)
            session.tokens = read.flatMap { $0.total > 0 ? $0.text : nil }
            session.model = read?.model
        }
        return session
    }

    private static func session(of record: ClaudeSessionRecord, transcripts: ClaudeTranscriptReader?,
                                doing: () -> AgentSession.Doing?) -> AgentSession {
        guard !record.reportsStatus,
              let sessionID = record.sessionID,
              let activity = transcripts?.activity(sessionID: sessionID, cwd: record.cwd)
        else {
            guard record.session.state == .busy else { return record.session }
            return record.session(state: .busy, since: record.session.since, doing: doing())
        }
        let busy = activity.turn == .inFlight
        return record.session(state: busy ? .busy : .idle, since: activity.since, doing: busy ? doing() : nil)
    }

    /// One session can hold two registry records at once: resuming after a
    /// crash registers a new pid while the old process is still winding down,
    /// and for a moment both files pass the liveness check. Claude Code settles
    /// this by keeping the most recently started record, so the notch does the
    /// same rather than drawing one session twice.
    static func deduplicated(_ records: [ClaudeSessionRecord]) -> [ClaudeSessionRecord] {
        var newest: [String: ClaudeSessionRecord] = [:]
        var unidentified: [ClaudeSessionRecord] = []
        for record in records {
            guard let id = record.sessionID else { unidentified.append(record); continue }
            let candidate = record.startedAt ?? .distantPast
            if let held = newest[id], (held.startedAt ?? .distantPast) >= candidate { continue }
            newest[id] = record
        }
        return Array(newest.values) + unidentified
    }
}
