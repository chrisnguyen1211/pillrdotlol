import Foundation
import SQLite3

/// How your agents spent their time, kept so a day, a week or a month can
/// be looked back on: when each session went busy, waited on you, finished
/// or went away; what its folder's tree looked like when it finished; and
/// how long each question the notch held took you to answer.
///
/// Numbers, ids and folders only. No message, no command, no file
/// name. Nothing here is sent anywhere.
final class ActivityLedger {
    static let shared: ActivityLedger? = Runtime.isUnderTest
        ? nil : ActivityLedger(url: CostPaths.directory.appendingPathComponent("activity.sqlite"))

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lol.pillr.app.costs.activity-ledger")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// The state each session was last written in, so only changes are kept.
    private var known: [String: AgentSession.State] = [:]

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else { return nil }
        db = handle
        let ok = queue.sync { () -> Bool in
            exec("PRAGMA journal_mode=WAL;")
            exec("PRAGMA synchronous=NORMAL;")
            return exec("""
                CREATE TABLE IF NOT EXISTS state_change(
                  ts INTEGER NOT NULL, agent TEXT NOT NULL, session TEXT NOT NULL, state TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS ix_state ON state_change(session, ts);
                CREATE INDEX IF NOT EXISTS ix_state_ts ON state_change(ts);
                CREATE TABLE IF NOT EXISTS completion(
                  ts INTEGER NOT NULL, agent TEXT NOT NULL, session TEXT NOT NULL, reason TEXT NOT NULL,
                  folder TEXT, files INTEGER, added INTEGER, removed INTEGER);
                CREATE INDEX IF NOT EXISTS ix_completion ON completion(ts);
                CREATE TABLE IF NOT EXISTS prompt_wait(
                  asked INTEGER NOT NULL, answered INTEGER NOT NULL, agent TEXT NOT NULL, kind TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS ix_wait ON prompt_wait(answered);
                """)
        }
        guard ok else { sqlite3_close(handle); return nil }
    }

    deinit { if let db { sqlite3_close(db) } }

    func flush() { queue.sync {} }

    // MARK: Writing

    /// One agent's sessions as the notch shows them: a session whose state
    /// changed, or that is no longer there, is written down.
    func observe(agent: String, sessions: [AgentSession], at date: Date = Date()) {
        let prefix = agent + "|"
        queue.async { [self] in
            var seen: Set<String> = []
            for session in sessions {
                let key = prefix + session.id
                seen.insert(key)
                guard known[key] != session.state else { continue }
                known[key] = session.state
                // When it changed, if that was just now; a session found long
                // into a state (pillr only just started) began it, as far as
                // anything here knows, when it was found.
                let at = session.since >= date.addingTimeInterval(-300) && session.since <= date ? session.since : date
                run("INSERT INTO state_change(ts, agent, session, state) VALUES (?1, ?2, ?3, ?4)",
                    [.int(Int(at.timeIntervalSince1970)), .text(agent), .text(session.id), .text(Self.name(session.state))])
            }
            for key in known.keys where key.hasPrefix(prefix) && !seen.contains(key) {
                known[key] = nil
                run("INSERT INTO state_change(ts, agent, session, state) VALUES (?1, ?2, ?3, 'gone')",
                    [.int(Int(date.timeIntervalSince1970)), .text(agent), .text(String(key.dropFirst(prefix.count)))])
            }
        }
    }

    /// A session finished, or stopped to ask; with its folder's uncommitted
    /// tree at that moment, where there is one.
    func completed(agent: String, session: String, blocked: Bool, folder: String?, tree: GitChanges.Stats?,
                   at date: Date = Date()) {
        queue.async { [self] in
            run("""
                INSERT INTO completion(ts, agent, session, reason, folder, files, added, removed)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                """, [.int(Int(date.timeIntervalSince1970)), .text(agent), .text(session), .text(blocked ? "blocked" : "finished"),
                      folder.map(Value.text) ?? .null, tree.map { .int($0.files) } ?? .null,
                      tree.map { .int($0.added) } ?? .null, tree.map { .int($0.removed) } ?? .null])
        }
    }

    /// A question or a permission the notch held, and when you answered it.
    func answered(agent: String, question: Bool, asked: Date, at date: Date = Date()) {
        queue.async { [self] in
            run("INSERT INTO prompt_wait(asked, answered, agent, kind) VALUES (?1, ?2, ?3, ?4)",
                [.int(Int(asked.timeIntervalSince1970)), .int(Int(date.timeIntervalSince1970)), .text(agent),
                 .text(question ? "question" : "approval")])
        }
    }

    // MARK: Reading

    struct Summary: Equatable {
        /// Seconds some agent was working, added up across sessions.
        var busy: TimeInterval = 0
        /// Seconds with two or more sessions working at once.
        var parallel: TimeInterval = 0
        /// Seconds sessions stood waiting on you.
        var waiting: TimeInterval = 0
        var finished = 0
        var sessions = 0
        /// Lines added and removed, as the trees grew between finishes.
        var added = 0
        var removed = 0
        var answered = 0
        /// The middle of how long you took to answer.
        var medianAnswer: TimeInterval?
        /// Busy seconds by agent.
        var busyByAgent: [String: TimeInterval] = [:]
        /// Busy seconds in each local hour of the day, 0–23.
        var busyByHour: [TimeInterval] = Array(repeating: 0, count: 24)
        /// Busy seconds per local day, by the day's start.
        var busyByDay: [Date: TimeInterval] = [:]
        /// When the ledger's knowledge starts, where that is after the range does.
        var since: Date?
    }

    func summary(from: Date, to: Date, now: Date = Date(), calendar: Calendar = .current) -> Summary {
        queue.sync { () -> Summary in
            var summary = Summary()
            let end = min(to, now)
            // Each session's changes, from the one before the range on.
            var intervals: [(agent: String, state: String, start: Date, end: Date)] = []
            var touched: Set<String> = []
            for (agent, session) in sessionsTouching(from: from, to: end) {
                var changes = stateChanges(agent: agent, session: session, from: from, to: end)
                guard !changes.isEmpty else { continue }
                touched.insert(agent + "|" + session)
                changes.append((end, "end"))
                for (current, next) in zip(changes, changes.dropFirst()) {
                    let start = max(current.0, from), stop = min(next.0, end)
                    guard stop > start else { continue }
                    intervals.append((agent, current.1, start, stop))
                }
            }
            summary.sessions = touched.count
            var busyEdges: [(Date, Int)] = []
            for interval in intervals {
                let length = interval.end.timeIntervalSince(interval.start)
                switch interval.state {
                case "busy":
                    summary.busy += length
                    summary.busyByAgent[interval.agent, default: 0] += length
                    busyEdges += [(interval.start, 1), (interval.end, -1)]
                    Self.spread(interval.start, interval.end, calendar: calendar) { hour, day, seconds in
                        summary.busyByHour[hour] += seconds
                        summary.busyByDay[day, default: 0] += seconds
                    }
                case "waiting":
                    summary.waiting += length
                default:
                    break
                }
            }
            // Two or more at once: walk the edges in time order.
            var running = 0
            var last: Date?
            for (time, step) in busyEdges.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }) {
                if let last, running >= 2 { summary.parallel += time.timeIntervalSince(last) }
                running += step
                last = time
            }
            let (finished, added, removed) = completions(from: from, to: end)
            summary.finished = finished
            summary.added = added
            summary.removed = removed
            let waits = answerTimes(from: from, to: end).sorted()
            summary.answered = waits.count
            if !waits.isEmpty { summary.medianAnswer = waits[waits.count / 2] }
            if let first = firstRecord(), first > from { summary.since = first }
            return summary
        }
    }

    /// Days in a row, up to and including today, with any agent at work.
    func streak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.date(byAdding: .day, value: -60, to: calendar.startOfDay(for: now))!
        let days = summary(from: start, to: now, now: now, calendar: calendar).busyByDay.filter { $0.value >= 60 }.keys
        var count = 0
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        while days.contains(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    /// Calls `add` for each piece of an interval that falls in one local
    /// hour, with that hour and the start of its day.
    static func spread(_ start: Date, _ end: Date, calendar: Calendar, add: (Int, Date, TimeInterval) -> Void) {
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)!
            let stop = min(end, hourStart.end)
            add(calendar.component(.hour, from: cursor), calendar.startOfDay(for: cursor), stop.timeIntervalSince(cursor))
            cursor = stop
        }
    }

    // MARK: Queries (queue-confined)

    private func sessionsTouching(from: Date, to: Date) -> [(String, String)] {
        // Sessions with a change in the range, or busy or waiting going into it.
        guard let st = prepare("""
            SELECT DISTINCT agent, session FROM state_change WHERE ts < ?2 AND session IN (
              SELECT session FROM state_change WHERE ts >= ?1 AND ts < ?2
              UNION SELECT session FROM state_change s WHERE ts < ?1 AND state IN ('busy', 'waiting')
                AND ts = (SELECT max(ts) FROM state_change t WHERE t.session = s.session AND t.agent = s.agent AND t.ts < ?1))
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, [.int(Int(from.timeIntervalSince1970)), .int(Int(to.timeIntervalSince1970))])
        var out: [(String, String)] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append((column(st, 0), column(st, 1))) }
        return out
    }

    private func stateChanges(agent: String, session: String, from: Date, to: Date) -> [(Date, String)] {
        guard let st = prepare("""
            SELECT ts, state FROM state_change WHERE agent = ?1 AND session = ?2 AND ts < ?4 AND ts >= coalesce(
              (SELECT max(ts) FROM state_change WHERE agent = ?1 AND session = ?2 AND ts < ?3), ?3)
            ORDER BY ts, rowid
            """) else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, [.text(agent), .text(session), .int(Int(from.timeIntervalSince1970)), .int(Int(to.timeIntervalSince1970))])
        var out: [(Date, String)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))), column(st, 1)))
        }
        return out
    }

    /// Finishes in the range, and the lines the trees grew by: each folder's
    /// tree against its last finish before, a smaller tree (a commit, a
    /// revert) counting from nothing.
    private func completions(from: Date, to: Date) -> (Int, Int, Int) {
        guard let st = prepare("""
            SELECT ts, reason, folder, added, removed FROM completion WHERE ts < ?2 AND (ts >= ?1 OR (folder IS NOT NULL
              AND ts = (SELECT max(ts) FROM completion c WHERE c.folder = completion.folder AND c.ts < ?1 AND c.added IS NOT NULL)))
            ORDER BY ts
            """) else { return (0, 0, 0) }
        defer { sqlite3_finalize(st) }
        bind(st, [.int(Int(from.timeIntervalSince1970)), .int(Int(to.timeIntervalSince1970))])
        var finished = 0, added = 0, removed = 0
        var lastTree: [String: (Int, Int)] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            let at = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0)))
            let inRange = at >= from
            if inRange, column(st, 1) == "finished" { finished += 1 }
            guard sqlite3_column_type(st, 2) != SQLITE_NULL, sqlite3_column_type(st, 3) != SQLITE_NULL else { continue }
            let folder = column(st, 2)
            let tree = (Int(sqlite3_column_int64(st, 3)), Int(sqlite3_column_int64(st, 4)))
            if inRange {
                let before = lastTree[folder] ?? (0, 0)
                added += tree.0 >= before.0 ? tree.0 - before.0 : tree.0
                removed += tree.1 >= before.1 ? tree.1 - before.1 : tree.1
            }
            lastTree[folder] = tree
        }
        return (finished, added, removed)
    }

    private func answerTimes(from: Date, to: Date) -> [TimeInterval] {
        guard let st = prepare("SELECT answered - asked FROM prompt_wait WHERE answered >= ?1 AND answered < ?2") else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, [.int(Int(from.timeIntervalSince1970)), .int(Int(to.timeIntervalSince1970))])
        var out: [TimeInterval] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(max(0, TimeInterval(sqlite3_column_int64(st, 0)))) }
        return out
    }

    private func firstRecord() -> Date? {
        guard let st = prepare("SELECT min(t) FROM (SELECT min(ts) AS t FROM state_change UNION ALL SELECT min(ts) FROM completion)")
        else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0)))
    }

    static func name(_ state: AgentSession.State) -> String {
        switch state {
        case .busy: return "busy"
        case .waiting: return "waiting"
        case .success: return "success"
        case .idle: return "idle"
        }
    }

    // MARK: SQLite

    private enum Value { case int(Int), text(String), null }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK ? st : nil
    }

    private func bind(_ st: OpaquePointer?, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(st, i, Int64(v))
            case .text(let v): sqlite3_bind_text(st, i, v, -1, Self.transient)
            case .null: sqlite3_bind_null(st, i)
            }
        }
    }

    private func run(_ sql: String, _ values: [Value]) {
        guard let st = prepare(sql) else { return }
        defer { sqlite3_finalize(st) }
        bind(st, values)
        sqlite3_step(st)
    }

    private func column(_ st: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
    }
}
