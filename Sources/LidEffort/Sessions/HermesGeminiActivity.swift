import Foundation
import SQLite3

/// Notices when a Hermes session is spending a `GEMINI_API_KEY` right now.
///
/// Hermes keeps its own state beside the usage totals, in the same
/// `~/.hermes/state.db` (schema_version 30):
///
/// ```
/// sessions(id, source, started_at REAL, ended_at REAL, last_activity_at REAL,
///          billing_provider, cwd, title, model, …)
/// session_turn_leases(conversation_id TEXT PRIMARY KEY, holder,
///                     acquired_at REAL, expires_at REAL)
/// ```
///
/// `ended_at IS NULL` on its own says almost nothing: a desktop session stays
/// open for hours after the last question, and a crashed one never closes at
/// all. What narrows it to work in flight is either half of the `OR`:
///
/// - `last_activity_at` inside `staleAfter`, the same recency substitute Gemini
///   CLI and Cursor stand on, or
/// - a row in `session_turn_leases` that has not expired. That table is
///   Hermes's own "a turn is running" marker, and because the lease carries a
///   wall-clock `expires_at` it stops lying by itself when the process dies —
///   which is why a long model think, quiet on `last_activity_at`, still reads
///   as busy.
///
/// `billing_provider = 'gemini'` is the same id `HermesGeminiUsage` matches:
/// Google AI Studio through a bare API key, and it survives a
/// `GEMINI_BASE_URL` override.
///
/// Hermes records no "waiting for you" state on disk, so the answer is busy or
/// nothing, like Cursor and Antigravity rather than Claude.
enum HermesGeminiActivity {
    static func read(
        database: URL = HermesGeminiUsage.database,
        staleAfter: TimeInterval,
        now: Date = Date()
    ) -> [AgentSession] {
        guard let db = SQLiteStore.open(database) else { return [] }
        defer { sqlite3_close(db) }

        // A prepare that fails is indistinguishable from a query that matched
        // nothing through `SQLiteStore.rows`, so the schema is asked about
        // first: pre-30 databases have no `sessions` at all, and the leases
        // table arrived separately. Naming a missing table would otherwise turn
        // an old install into a silent, permanent "nothing running".
        let tables = Set(SQLiteStore.rows(
            in: db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name IN ('sessions', 'session_turn_leases')
            """
        ))
        guard tables.contains("sessions") else { return [] }

        // Epoch seconds as REAL, and `SQLiteStore` has no parameter binding, so
        // the bounds go in as integer literals.
        let nowSeconds = Int(now.timeIntervalSince1970)
        let cutoffSeconds = nowSeconds - Int(staleAfter)
        let lease = tables.contains("session_turn_leases")
            ? """

                     OR EXISTS (SELECT 1 FROM session_turn_leases l
                                WHERE l.conversation_id = s.id AND l.expires_at > \(nowSeconds))
            """
            : ""

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT s.id, s.title, s.cwd, s.started_at, s.last_activity_at
            FROM sessions s
            WHERE s.billing_provider = 'gemini' AND s.ended_at IS NULL
              AND (s.last_activity_at >= \(cutoffSeconds)\(lease))
            ORDER BY s.last_activity_at DESC
            """,
            columns: 5
        )

        return rows.map { row in
            let cwd = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if !cwd.isEmpty {
                detail = "Working in \(URL(fileURLWithPath: cwd).lastPathComponent)"
            } else if !title.isEmpty {
                detail = title
            } else {
                detail = "Working"
            }
            // A session that somehow lost its start time is still running; the
            // tooltip's elapsed time is the only thing that suffers.
            let started = Double(row[3]).map(Date.init(timeIntervalSince1970:)) ?? now
            return AgentSession(
                id: "gemini-api.hermes.\(row[0])",
                name: "Hermes",
                detail: detail,
                state: .busy,
                waitingFor: nil,
                since: started
            )
        }
    }
}
