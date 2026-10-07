import Foundation

/// A forty-second showcase of what 1.1 added, on the real notch with made-up
/// sessions: `open -a pillr --args --demo`. It borrows the tour's stand-ins —
/// real notes and prompts wait while it runs — and nothing in it is sent,
/// changed or launched: the reply and hand-off panels say what they would do.
@MainActor
final class FeatureDemo {
    private weak var fleet: NotchFleet?
    private var task: Task<Void, Never>?

    init(fleet: NotchFleet) { self.fleet = fleet }

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in await self?.run() }
    }

    private func run() async {
        guard let fleet else { return }
        let now = Date()
        fleet.isTouring = true
        fleet.showTourDemo(snapshots: TourDemo.snapshots(now: now), sessions: Self.sessions(now: now))
        // Claude's session window, burning 1% a minute: out well before it resets.
        UsageForecaster.shared.inject(providerID: "claude", windowID: "claude.session",
                                      samples: [(now.addingTimeInterval(-15 * 60), 0.47), (now, 0.62)])
        defer {
            UsageForecaster.shared.forget(providerID: "claude")
            ReplyPanelController.shared.close()
            fleet.releaseTourTooltip()
            fleet.endTourDemo()
            fleet.isTouring = false
        }

        // 1. What each session is doing, its tokens, when the limit runs out.
        fleet.holdTourTooltip()
        guard await pause(7) else { return }

        // 2. Reply, typed out, never sent.
        let idle = Self.sessions(now: now)["claude"]![2]
        // As in use: the tooltip folds away and the field takes its place.
        fleet.releaseTourTooltip()
        ReplyPanelController.shared.anchor = fleet.foldForReply()
        ReplyPanelController.shared.open(for: idle, demoText: L10n.t("Add a test for the empty cart, then open a PR"))
        // Typed, sent, opened into a card, closed.
        guard await pause(5.5) else { return }
        ReplyPanelController.shared.close()

        // 3. Hand-off: the brief, and the agents that could take it.
        ReplyPanelController.shared.openHandoff(for: idle, demoBrief: Handoff.compose(
            from: "Claude Code", folder: "shop-web", branch: "release-notes",
            ask: "Write the release notes for 2.4 from the merged PRs",
            lead: "Drafted Features and Fixes; Breaking changes still to do."))
        guard await pause(6) else { return }
        ReplyPanelController.shared.close()
        guard await pause(1) else { return }

        // 4. A session finishes: what it changed.
        let done = Self.sessions(now: now)["codex"]![1]
        fleet.showDoneToast(SessionCompletionWatcher.Event(session: done, reason: .finished, providerID: "codex"),
                            duration: 5, changes: "3 files · +42 −7 · 2 new")
        guard await pause(5.5) else { return }

        // 5. Auto-eco steps effort down, and says why.
        fleet.showEffortAlert(EffortChangeEvent(level: .medium, values: [("Claude Code", "medium")], at: Date(),
                                                forSession: false,
                                                reason: L10n.t("Auto-eco · \("Claude") is near its limit"),
                                                agent: "claude"), duration: 4)
        guard await pause(4.5) else { return }

        // 6. The day's recap.
        var recap = DailyRecap()
        recap.agents = [DailyRecap.Agent(name: "Claude Code", sessions: 9, toolCalls: 286, tokens: 14_200_000),
                        DailyRecap.Agent(name: "Codex", sessions: 3, toolCalls: 54, tokens: 3_900_000)]
        var event = UsageAlertEvent(kind: .recap, providerID: "recap", providerName: "", windowLabel: "",
                                    glyph: .claude, previousFraction: 0, currentFraction: 0, resetsAt: nil)
        event.recap = recap
        fleet.showResetAlert(event, duration: 6)
        _ = await pause(6.5)
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    /// The tour's sessions, with what they are doing and what they have cost.
    static func sessions(now: Date) -> [String: [AgentSession]] {
        var lists = TourDemo.sessions(now: now)
        func edit(_ provider: String, _ index: Int, _ change: (inout AgentSession) -> Void) {
            guard var list = lists[provider], list.indices.contains(index) else { return }
            change(&list[index])
            lists[provider] = list
        }
        edit("claude", 0) {
            $0.doing = AgentSession.Doing(text: "$ npm test -- checkout", kind: .tool, since: now.addingTimeInterval(-72))
            $0.tokens = "1.4M tokens"
        }
        edit("claude", 1) { $0.tokens = "640k tokens" }
        edit("claude", 2) { $0.tokens = "312k tokens" }
        edit("codex", 0) {
            $0.doing = AgentSession.Doing(text: L10n.t("Editing \("invoice.ts")"), kind: .tool, since: now.addingTimeInterval(-9))
            $0.tokens = "2.1M tokens"
        }
        edit("codex", 1) { $0.tokens = "880k tokens" }
        return lists
    }
}
