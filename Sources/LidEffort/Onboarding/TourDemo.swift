import Foundation

/// What the notch shows while the tour runs, instead of the reader's own
/// readings: a first-time user has no limits used and no sessions yet, and a
/// tour of an empty notch shows nothing. Three agents part-way through their
/// limits, and a handful of sessions across them in every state.
enum TourDemo {
    /// Pids no real process has — a click on one of these sessions is the
    /// tour's to answer, not a window to raise.
    static let pids: Set<pid_t> = [990_001, 990_002, 990_003, 990_004, 990_005, 990_006]

    static func snapshots(now: Date = Date()) -> [ProviderSnapshot] {
        let sunday = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 11, weekday: 1),
                                               matchingPolicy: .nextTime) ?? now.addingTimeInterval(3 * 86_400)
        return [
            ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
                             windows: [
                                LimitWindow(id: "claude.session", label: L10n.t("Current session"), usedFraction: 0.62,
                                            resetsAt: now.addingTimeInterval(100 * 60)),
                                LimitWindow(id: "claude.week", label: L10n.t("All models"), usedFraction: 0.38, resetsAt: sunday),
                             ],
                             headlineID: "claude.session", weeklyID: "claude.week"),
            ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
                             windows: [
                                LimitWindow(id: "codex.session", label: L10n.t("5-hour limit"), usedFraction: 0.44,
                                            resetsAt: now.addingTimeInterval(3 * 3600)),
                                LimitWindow(id: "codex.week", label: L10n.t("Weekly limit"), usedFraction: 0.71, resetsAt: sunday),
                             ],
                             headlineID: "codex.session", weeklyID: "codex.week"),
            ProviderSnapshot(id: "cursor", displayName: "Cursor", glyph: .cursor, fidelity: .official, status: .ok,
                             windows: [
                                LimitWindow(id: "cursor.month", label: L10n.t("Monthly usage"), usedFraction: 0.29,
                                            resetsAt: now.addingTimeInterval(12 * 86_400)),
                             ],
                             headlineID: "cursor.month"),
        ]
    }

    static func sessions(now: Date = Date()) -> [String: [AgentSession]] {
        [
            "claude": [
                AgentSession(id: "demo-1", name: "checkout-redesign", detail: "Terminal · shop-web", state: .busy,
                             waitingFor: nil, since: now.addingTimeInterval(-7 * 60), processID: 990_001),
                AgentSession(id: "demo-2", name: "fix-flaky-tests", detail: "iTerm2 · api", state: .waiting,
                             waitingFor: L10n.t("approval"), since: now.addingTimeInterval(-2 * 60), processID: 990_002),
                AgentSession(id: "demo-3", name: "write-release-notes", detail: "Desktop", state: .idle,
                             waitingFor: nil, since: now.addingTimeInterval(-40 * 60), processID: 990_003),
            ],
            "codex": [
                AgentSession(id: "demo-4", name: "migrate-billing-v2", detail: "Terminal · billing", state: .busy,
                             waitingFor: nil, since: now.addingTimeInterval(-12 * 60), processID: 990_004),
                AgentSession(id: "demo-5", name: "refactor-auth", detail: "cmux · my-app", state: .success,
                             waitingFor: nil, since: now.addingTimeInterval(-60), processID: 990_005),
            ],
            "cursor": [
                AgentSession(id: "demo-6", name: "landing-page", detail: "Cursor · marketing", state: .idle,
                             waitingFor: nil, since: now.addingTimeInterval(-25 * 60), processID: 990_006),
            ],
        ]
    }

    /// A demo session by its pid.
    static func session(pid: pid_t) -> AgentSession? {
        sessions().values.flatMap { $0 }.first { $0.processID == pid }
    }

    /// The idle session the reply step writes to: idle, so spyx would type
    /// into it.
    static func replySession(now: Date = Date()) -> AgentSession? {
        sessions(now: now)["claude"]?.first { $0.state == .idle }
    }

    /// A handful of API keys, each showing off a kind of reading: what is
    /// left and spent, characters against a limit, a balance, a key that
    /// works and says how many requests it has left today.
    static func keys() -> [ProviderSnapshot] {
        func key(_ id: String, _ name: String, _ glyph: ProviderGlyph, _ reading: APIReading) -> ProviderSnapshot {
            let windows = reading.windows(providerName: name, currency: nil)
            return ProviderSnapshot(id: "\(ExtraKey.catalogPrefix)\(id)-k0tour", displayName: name, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: windows, headlineID: windows.first?.id)
        }
        return [
            key("openrouter", "OpenRouter", .openrouter,
                .several([.balance(7.5, .money("USD")), .spend(3.2, .money("USD"), .month),
                          .spend(41, .money("USD"), .total)])),
            key("elevenlabs", "ElevenLabs", .elevenlabs, .used(6_400, of: 10_000, .characters, resetsAt: nil)),
            key("deepseek", "DeepSeek", .deepseek, .balance(18.2, .money("USD"))),
            key("groq", "Groq", .groq, .keyWorks(.requestsLeft(remaining: 14_399, limit: 14_400, today: true))),
        ]
    }

    /// The pill's one cell for every key, as the notch draws it.
    static func keyGroup() -> ProviderSnapshot {
        APIKeyGroup.snapshot(members: keys())
    }

    /// The agents and, after them, the API keys cell — what the pill
    /// shows for the length of the tour.
    static func pill(now: Date = Date()) -> [ProviderSnapshot] {
        snapshots(now: now) + [keyGroup()]
    }
}
