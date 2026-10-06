import Foundation

/// The day with your agents, in one card at six in the evening: how many
/// sessions, how many tool calls, how many tokens, and which agent did the
/// most. Read from the agents' own transcripts for today — Claude Code's,
/// Codex's rollouts, Grok's updates — once, off the main thread.
struct DailyRecap: Equatable {
    struct Agent: Equatable {
        let name: String
        var sessions = 0
        var toolCalls = 0
        var tokens = 0
    }

    var agents: [Agent] = []

    var sessions: Int { agents.reduce(0) { $0 + $1.sessions } }
    var toolCalls: Int { agents.reduce(0) { $0 + $1.toolCalls } }
    var tokens: Int { agents.reduce(0) { $0 + $1.tokens } }
    var isEmpty: Bool { sessions == 0 }

    var title: String { L10n.t("Today with your agents") }
    var subtitle: String {
        [Self.count(sessions, one: L10n.t("1 session"), many: L10n.t("\(sessions) sessions")),
         Self.count(toolCalls, one: L10n.t("1 tool call"), many: L10n.t("\(toolCalls) tool calls")),
         L10n.t("\(TokenCount.compact(tokens)) tokens")].joined(separator: " · ")
    }

    /// "1 session", never "1 sessions".
    static func count(_ n: Int, one: String, many: String) -> String { n == 1 ? one : many }
    var status: String {
        guard let top = agents.max(by: { ($0.toolCalls, $0.sessions) < ($1.toolCalls, $1.sessions) }) else { return "" }
        return L10n.t("Busiest: \(top.name) · \(Self.count(top.sessions, one: L10n.t("1 session"), many: L10n.t("\(top.sessions) sessions")))")
    }

    // MARK: Reading today

    static func read(day: Date = Date(), home: URL = FileManager.default.homeDirectoryForCurrentUser) -> DailyRecap {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        var recap = DailyRecap()
        let claude = tally(files: files(under: home.appendingPathComponent(".claude/projects"), depth: 2, since: start),
                           name: "Claude Code", since: start, format: .claude)
        let codex = tally(files: files(under: home.appendingPathComponent(".codex/sessions"), depth: 4, since: start),
                          name: "Codex", since: start, format: .codex)
        let grok = tally(files: files(under: home.appendingPathComponent(".grok/sessions"), depth: 3, since: start)
                            .filter { $0.lastPathComponent == "updates.jsonl" },
                         name: "Grok", since: start, format: .grok)
        recap.agents = [claude, codex, grok].filter { $0.sessions > 0 }
        return recap
    }

    /// `.jsonl` files at most `depth` folders down, touched since `start`.
    private static func files(under root: URL, depth: Int, since start: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if walker.level > depth { walker.skipDescendants(); continue }
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= start else { continue }
            found.append(url)
        }
        return found
    }

    /// Counts what happened since `start` in each file. A file with
    /// anything from today is a session today.
    static func tally(files: [URL], name: String, since start: Date, format: TokenTally.Format) -> Agent {
        var agent = Agent(name: name)
        for url in files {
            var touched = false
            var seen: Set<String> = []
            var codexFirst: Int?, codexLast: Int?
            forEachLine(of: url) { line in
                // Cheap filters before any JSON is parsed.
                let interesting: Bool
                switch format {
                case .claude: interesting = line.contains("\"assistant\"")
                case .codex: interesting = line.contains("function_call") || line.contains("token_count") || line.contains("custom_tool_call")
                case .grok: interesting = line.contains("tool_call\"") || line.contains("turn_completed")
                }
                guard interesting,
                      let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let at = SessionDoing.date(json["timestamp"]), at >= start else { return }
                touched = true
                func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
                switch format {
                case .claude:
                    guard let message = json["message"] as? [String: Any] else { return }
                    let content = message["content"] as? [[String: Any]] ?? []
                    agent.toolCalls += content.filter { $0["type"] as? String == "tool_use" }.count
                    if let usage = message["usage"] as? [String: Any],
                       seen.insert((message["id"] as? String) ?? UUID().uuidString).inserted {
                        agent.tokens += int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"])
                            + int(usage["cache_read_input_tokens"]) + int(usage["output_tokens"])
                    }
                case .codex:
                    guard let payload = json["payload"] as? [String: Any] else { return }
                    switch payload["type"] as? String {
                    case "function_call", "custom_tool_call", "local_shell_call": agent.toolCalls += 1
                    case "token_count":
                        let total = int(((payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any])?["total_tokens"])
                        if codexFirst == nil { codexFirst = total }
                        codexLast = total
                    default: break
                    }
                case .grok:
                    guard let update = (json["params"] as? [String: Any])?["update"] as? [String: Any] else { return }
                    switch update["sessionUpdate"] as? String {
                    case "tool_call": agent.toolCalls += 1
                    case "turn_completed": agent.tokens += int((update["usage"] as? [String: Any])?["totalTokens"])
                    default: break
                    }
                }
            }
            if touched { agent.sessions += 1 }
            // Running totals: today's share is the last minus the first seen today.
            if let first = codexFirst, let last = codexLast {
                // A rollout started today counts from zero; one carried over
                // from yesterday, from its first total seen today.
                let startedToday = url.path.contains(Self.dayPath(start))
                agent.tokens += max(0, last - (startedToday ? 0 : first))
            }
        }
        return agent
    }

    /// Codex files a rollout under `YYYY/MM/DD/` of the day it started.
    static func dayPath(_ day: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "/%04d/%02d/%02d/", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func forEachLine(of url: URL, _ body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                body(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { body(String(decoding: pending, as: UTF8.self)) }
    }
}

/// Shows the recap once a day, at or after six in the evening, when there
/// was anything to recap. Switched off in Settings → Notifications.
@MainActor
final class DailyRecapScheduler {
    static let enabledKey = "recap.enabled"
    static let shownKey = "recap.lastShown"
    nonisolated static let hour = 18

    private var timer: Timer?
    private let defaults: UserDefaults
    private let show: (DailyRecap) -> Void

    init(defaults: UserDefaults = .standard, show: @escaping (DailyRecap) -> Void) {
        self.defaults = defaults
        self.show = show
    }

    func start() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    /// Due: switched on, past six today, not yet shown today.
    nonisolated static func isDue(now: Date, enabled: Bool, lastShown: Date?, calendar: Calendar = .current) -> Bool {
        guard enabled, calendar.component(.hour, from: now) >= hour else { return false }
        if let lastShown, calendar.isDate(lastShown, inSameDayAs: now) { return false }
        return true
    }

    func check(now: Date = Date()) {
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        guard Self.isDue(now: now, enabled: enabled, lastShown: defaults.object(forKey: Self.shownKey) as? Date) else { return }
        defaults.set(now, forKey: Self.shownKey)
        Task.detached(priority: .utility) { [weak self] in
            let recap = DailyRecap.read(day: now)
            guard !recap.isEmpty else { return }
            await MainActor.run { self?.show(recap) }
        }
    }
}
