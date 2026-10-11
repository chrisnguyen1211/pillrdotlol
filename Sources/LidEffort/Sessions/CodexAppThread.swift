import Foundation
import SQLite3

/// Which of Codex's threads the Codex app holds, and what it calls them.
///
/// The Codex app (ChatGPT.app, `com.openai.codex`) runs Codex's own app
/// server against `~/.codex`: its threads are rollouts in `sessions/` like
/// the CLI's, listed in its catalogue (`sqlite/codex-dev.db`), named in
/// `session_index.jsonl`. A thread is the app's when the app wrote it —
/// the rollout's `originator` is "Codex Desktop" — or when its catalogue
/// lists it as something other than a terminal's. Only those are opened in
/// the app or written to there: a CLI thread still open in a terminal must
/// not be answered from a second place at once.
enum CodexAppThread {
    /// A thread id as the app writes one and as its link takes one: a UUID.
    static func isThreadID(_ id: String) -> Bool {
        id.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                  options: .regularExpression) != nil
    }

    /// The thread id a rollout is named after:
    /// `rollout-2026-07-16T12-42-39-<uuid>.jsonl`.
    static func threadID(inRolloutName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropLast(".jsonl".count)
        guard stem.count >= 36 else { return nil }
        let id = String(stem.suffix(36))
        return isThreadID(id) ? id : nil
    }

    /// Whoever wrote the rollout, as Codex records it: "Codex Desktop" and
    /// "codex_work_desktop" are the app; "codex-tui", "codex_exec" and the
    /// editor extensions are not.
    static func isAppOriginator(_ originator: String?) -> Bool {
        guard let originator else { return false }
        return originator.lowercased().contains("desktop")
    }

    /// A catalogue row the app can be asked to show: anything but a
    /// terminal's (`cli`) or a script's (`exec`). An unknown kind, from a
    /// catalogue too old to say, is the app's own.
    static func isAppSource(kind: String?) -> Bool {
        guard let kind = kind?.lowercased(), !kind.isEmpty else { return true }
        return kind != "cli" && kind != "exec"
    }

    // MARK: Rollouts

    /// The rollout's first line says who wrote it. Read once per file: it
    /// never changes, and the monitor asks every two seconds.
    static func originator(ofRollout url: URL) -> String? {
        if let known = originators[url.path] { return known }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        let firstLine = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first ?? head[...]
        guard let json = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else { return nil }
        let payload = json["payload"] as? [String: Any] ?? json
        let originator = payload["originator"] as? String
        if let originator { originators[url.path] = originator }
        return originator
    }

    private static var originators: [String: String] = [:]

    /// The day a thread was started, from its id: Codex's ids are UUIDv7,
    /// whose first 48 bits are the time in milliseconds. Nil for any other kind.
    static func creationDate(ofThread id: String) -> Date? {
        guard isThreadID(id) else { return nil }
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex[hex.index(hex.startIndex, offsetBy: 12)] == "7",
              let millis = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// The rollout of a thread, under `sessions/YYYY/MM/DD/`: the folders of
    /// the day its id was made, and the days either side for a time zone.
    static func rollout(forThread id: String, under sessions: URL,
                        fileManager: FileManager = .default) -> URL? {
        guard let made = creationDate(ofThread: id) else { return nil }
        let suffix = "-\(id.lowercased()).jsonl"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for offset in [0, -1, 1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: made) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, date))
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            if let name = names.first(where: { $0.lowercased().hasSuffix(suffix) && $0.hasPrefix("rollout-") }) {
                return folder.appendingPathComponent(name)
            }
        }
        return nil
    }

    // MARK: The app's own records

    /// The kind the app's catalogue lists a thread as ("" when it doesn't
    /// say); nil when the catalogue doesn't list it.
    static func catalogKind(ofThread id: String, store: URL) -> String? {
        guard isThreadID(id), let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT coalesce(source_kind, '') FROM local_thread_catalog WHERE thread_id = ? LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
    }

    /// Whether the thread a Codex hook named is one the app holds: by its
    /// rollout's author, or failing that by the app's catalogue.
    static func isAppThread(_ id: String, profile: CodexProfile = .default()) -> Bool {
        guard profile.slug == nil, isThreadID(id) else { return false }
        if let rollout = rollout(forThread: id, under: profile.configDirectory.appendingPathComponent("sessions")),
           let originator = originator(ofRollout: rollout) {
            return isAppOriginator(originator)
        }
        if let kind = catalogKind(ofThread: id, store: profile.desktopStoreURL) {
            return isAppSource(kind: kind)
        }
        return false
    }

    /// What the app may call each thread in its sidebar: the name in
    /// `session_index.jsonl` (the last one written, as a rename appends)
    /// and the title its catalogue shows.
    static func titles(profile: CodexProfile = .default()) -> [String: [String]] {
        var titles: [String: [String]] = [:]
        let index = profile.configDirectory.appendingPathComponent("session_index.jsonl")
        if let text = try? String(contentsOf: index, encoding: .utf8) {
            titles = indexTitles(text)
        }
        if let db = SQLiteStore.open(profile.desktopStoreURL) {
            defer { sqlite3_close(db) }
            for row in SQLiteStore.rows(in: db, sql: "SELECT thread_id, display_title FROM local_thread_catalog", columns: 2)
            where !row[0].isEmpty && !row[1].isEmpty {
                if !(titles[row[0]] ?? []).contains(row[1]) { titles[row[0], default: []].append(row[1]) }
            }
        }
        return titles
    }

    /// `{"id": …, "thread_name": …}` per line; a later line renames.
    static func indexTitles(_ text: String) -> [String: [String]] {
        var latest: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = json["id"] as? String, let name = json["thread_name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            latest[id] = name
        }
        return latest.mapValues { [$0] }
    }
}
