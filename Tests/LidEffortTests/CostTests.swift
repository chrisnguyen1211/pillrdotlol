import XCTest
@testable import LidEffort

/// The cost layer's seams into the app: the hover card reserves room for
/// the project rows, the money math anchors on the allowance rather than on
/// token prices, and the store splits each rise in the limit across the
/// projects whose turns fell in that interval.
final class CostTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spyx-cost-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func event(_ ts: Int, project: String, input: Int = 0, output: Int = 0, key: String? = nil,
                       session: String = "s1", model: String = "claude-opus-5") -> UsageEvent {
        UsageEvent(ts: ts, sessionId: session, dedupeKey: key ?? "k:\(project):\(ts)", project: project, cwd: project,
                   branch: nil, model: model, input: input, output: output, cacheRead: 0, cacheWrite: 0, ccVersion: nil)
    }

    private func store() throws -> CostStore {
        try XCTUnwrap(CostStore(url: dir.appendingPathComponent("test.sqlite")))
    }

    // MARK: Card

    /// Cost rows on the card add exactly what the section draws.
    func testCardHeightGrowsWithCostRows() {
        let base = NotchLayout.cardHeight(windowCount: 2)
        let withRows = NotchLayout.cardHeight(windowCount: 2, costRows: 3)
        // The divider that sets it apart from the sessions, then the rows.
        let expected = NotchLayout.blockSpacing + NotchLayout.hairline
            + NotchLayout.blockSpacing + NotchLayout.cardBodyLineHeight
            + 3 * (NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap)
        XCTAssertEqual(withRows - base, expected, accuracy: 0.01)
        XCTAssertEqual(NotchLayout.cardHeight(windowCount: 2, costRows: 0), base)
    }

    /// The suite's cards never pick up the machine's own cost rows.
    @MainActor func testNoCostRowsUnderTest() {
        let snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude,
                                        fidelity: .official, status: .ok, windows: [])
        XCTAssertEqual(CostSection.rowCount(for: snapshot), 0)
    }

    // MARK: Money

    /// Money for subscription work is the weekly share of the plan; a credit
    /// seat prices credits; an API account prices tokens.
    func testCostEstimatorModes() {
        let pricer = Pricer(prices: [ModelPrice(model: "claude-opus-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)], rate: 5)
        let period = (start: 0, end: 7 * 86_400, usedPct: 40.0, weight: 100.0)
        let plan = CostEstimator(billing: .subscription, monthlyPrice: 435, periods: [period], pricer: pricer)
        // Week = 435 ÷ 4.35 = 100; 40 % used = 40; this session was half the week's weight → 20.
        XCTAssertEqual(plan.cost(at: 10, weight: 50, model: "claude-opus-5", input: 0, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 20, accuracy: 0.01)
        let credits = CostEstimator(billing: .subscription, monthlyPrice: 0, creditPointValue: 25, periods: [period], pricer: pricer)
        // 40 % of the cycle's credits × 25 per point = 1000; half the weight → 500.
        XCTAssertEqual(credits.cost(at: 10, weight: 50, model: "x", input: 0, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 500, accuracy: 0.01)
        let api = CostEstimator(billing: .api, monthlyPrice: 0, periods: [], pricer: pricer)
        // 1M input at $5 + 1M output at $25 = $30 × rate 5 = 150.
        XCTAssertEqual(api.cost(at: 10, weight: 1, model: "claude-opus-5", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite: 0) ?? 0, 150, accuracy: 0.01)
    }

    /// No month spread and no plan price means no number, never a zero.
    func testSubscriptionWithoutPriceHasNoCost() {
        let pricer = Pricer(prices: [], rate: 1)
        let plan = CostEstimator(billing: .subscription, monthlyPrice: 0, periods: [], pricer: pricer)
        XCTAssertNil(plan.cost(at: 10, weight: 50, model: "x", input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    /// The longest matching prefix prices a model; an unknown rate prices nothing.
    func testPricerMatchesLongestPrefixAndNeedsARate() {
        let prices = [ModelPrice(model: "claude", input: 1, output: 1, cacheRead: 0, cacheWrite: 0),
                      ModelPrice(model: "claude-opus-5", input: 5, output: 25, cacheRead: 0, cacheWrite: 0)]
        XCTAssertEqual(Pricer(prices: prices, rate: 1).local(model: "claude-opus-5-1", input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0) ?? 0, 5, accuracy: 0.001)
        XCTAssertNil(Pricer(prices: prices, rate: 0).local(model: "claude-opus-5", input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(Pricer(prices: prices, rate: 1).local(model: "gpt-5", input: 1, output: 1, cacheRead: 0, cacheWrite: 0))
    }

    func testOpenRouterListIsReadAsUSDPerMillion() {
        let json = """
        {"data":[
          {"id":"anthropic/claude-opus-5.1","pricing":{"prompt":"0.000005","completion":"0.000025","input_cache_read":"0.0000005","input_cache_write":"0.00000625"}},
          {"id":"anthropic/claude-opus-5:beta","pricing":{"prompt":"1","completion":"1"}},
          {"id":"mistral/large","pricing":{"prompt":"1","completion":"1"}}
        ]}
        """
        let prices = PriceTable.parseOpenRouter(Data(json.utf8))
        XCTAssertEqual(prices.count, 1)
        XCTAssertEqual(prices.first?.model, "claude-opus-5-1")
        XCTAssertEqual(prices.first?.input ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(prices.first?.cacheWrite ?? 0, 6.25, accuracy: 0.0001)
    }

    /// The catalog prices a plan in the Mac's currency when it lists one,
    /// else converts the US price — and says nothing without a rate.
    @MainActor func testPlanCatalogPrices() {
        let catalog = PlanCatalog.shared
        XCTAssertEqual(catalog.monthly(for: "default_claude_max_5x", currency: "BRL", rate: 0), 550)
        XCTAssertEqual(catalog.monthly(for: "default_claude_pro", currency: "EUR", rate: 0.5), 10)
        XCTAssertNil(catalog.monthly(for: "default_claude_pro", currency: "EUR", rate: 0))
        XCTAssertEqual(catalog.name(for: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(catalog.creditUSD(for: "business"), 1)
    }

    /// Market data reaches hosts that are not an agent's own: off unless asked for.
    @MainActor func testMarketDataIsOffByDefault() {
        let saved = UserDefaults.standard.object(forKey: PriceTable.marketDataKey)
        defer { UserDefaults.standard.set(saved, forKey: PriceTable.marketDataKey) }
        UserDefaults.standard.removeObject(forKey: PriceTable.marketDataKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: PriceTable.marketDataKey))
    }

    // MARK: Attribution

    /// A rise in the weekly limit is split across the projects whose turns
    /// fell in the interval, by token weight; a fall marks a new period.
    func testRiseIsSplitByWeightAndResetStartsAPeriod() throws {
        let s = try store()
        let t0 = 1_800_000_000
        s.recordSample(window: .weekly, pct: 10, at: Date(timeIntervalSince1970: TimeInterval(t0)))
        s.commit(events: [event(t0 + 10, project: "/a", input: 300),
                          event(t0 + 20, project: "/b", input: 100)],
                 path: "/x.jsonl", inode: 1, size: 1, offset: 1, mtime: 0)
        s.recordSample(window: .weekly, pct: 18, at: Date(timeIntervalSince1970: TimeInterval(t0 + 60)))

        let rows = s.attributedWeeklyPct(from: t0, to: t0 + 60)
        XCTAssertEqual(rows["/a"] ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(rows["/b"] ?? 0, 2, accuracy: 0.001)

        // Nothing local in the next interval: the rise is "elsewhere".
        s.recordSample(window: .weekly, pct: 20, at: Date(timeIntervalSince1970: TimeInterval(t0 + 120)))
        XCTAssertEqual(s.attributedWeeklyPct(from: t0, to: t0 + 120)[CostStore.unexplainedKey] ?? 0, 2, accuracy: 0.001)

        // The limit resets: no negative attribution, the next period starts clean.
        s.recordSample(window: .weekly, pct: 1, at: Date(timeIntervalSince1970: TimeInterval(t0 + 180)))
        XCTAssertTrue(s.currentPeriod(window: .weekly).allSatisfy { $0.pct >= 0 })
    }

    /// The rows add up to the card's percentage: whatever was used while spyx
    /// was not watching is spread over the turns of the period.
    func testCurrentPeriodFillsTheGap() throws {
        let s = try store()
        let now = Int(Date().timeIntervalSince1970)
        let resets = Date(timeIntervalSince1970: TimeInterval(now + 86_400))
        s.commit(events: [event(now - 3_600, project: "/a", input: 100),
                          event(now - 1_800, project: "/b", input: 100)],
                 path: "/x.jsonl", inode: 1, size: 1, offset: 1, mtime: 0)
        s.recordSample(window: .weekly, pct: 30, resetsAt: resets, at: Date(timeIntervalSince1970: TimeInterval(now)))
        let rows = s.currentPeriod(window: .weekly)
        XCTAssertEqual(rows.map(\.pct).reduce(0, +), 30, accuracy: 0.01)
        XCTAssertEqual(rows.first { $0.project == "/a" }?.pct ?? 0, 15, accuracy: 0.01)
    }

    /// Claude Code writes a turn several times while streaming; it counts once,
    /// at its final size.
    func testStreamedTurnCountsOnceAtItsLargestSize() throws {
        let s = try store()
        s.commit(events: [event(100, project: "/a", output: 10, key: "r:1")], path: "/x", inode: 1, size: 1, offset: 1, mtime: 0)
        s.commit(events: [event(101, project: "/a", output: 40, key: "r:1")], path: "/x", inode: 1, size: 2, offset: 2, mtime: 0)
        XCTAssertEqual(s.stats().events, 1)
        XCTAssertEqual(s.sessions(from: 0, to: 1_000).first?.output, 40)
    }

    func testPresentableKeepsTopRowsMergesTheRestAndPutsElsewhereLast() {
        let rows = (1...6).map { ProjectCost(project: "/p\($0)", pct: Double(10 - $0), cost: 1) }
            + [ProjectCost(project: CostStore.unexplainedKey, pct: 3, isUnexplained: true)]
        let shown = rows.presentable()
        XCTAssertEqual(shown.count, 6)
        XCTAssertEqual(shown[4].mergedCount, 2)
        XCTAssertEqual(shown[4].cost ?? 0, 2, accuracy: 0.001)
        XCTAssertTrue(shown.last?.isUnexplained ?? false)
    }

    func testGenericFolderKeepsItsParent() {
        XCTAssertEqual(ProjectCost.shortName(for: "/Users/x/nodes/src"), "nodes/src")
        XCTAssertEqual(ProjectCost.shortName(for: "/Users/x/spyx"), "spyx")
    }

    // MARK: Indexing

    /// Only token counts are read from a Claude transcript: user turns,
    /// synthetic placeholders and repeats of a streamed turn are not events.
    func testIndexerReadsClaudeTokenCounts() throws {
        let s = try store()
        let root = dir.appendingPathComponent("projects/-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","message":{"content":"secret"},"cwd":"/tmp/proj","sessionId":"s1","timestamp":"2026-10-01T10:00:00.000Z"}"#,
            #"{"type":"assistant","requestId":"req1","cwd":"/tmp/proj","sessionId":"s1","timestamp":"2026-10-01T10:00:05.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","requestId":"req1","cwd":"/tmp/proj","sessionId":"s1","timestamp":"2026-10-01T10:00:06.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":50,"cache_read_input_tokens":7}}}"#,
            #"{"type":"assistant","cwd":"/tmp/proj","sessionId":"s1","timestamp":"2026-10-01T10:00:07.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let indexer = try XCTUnwrap(CostIndexer(store: s, root: dir.appendingPathComponent("projects")))
        let done = expectation(description: "indexed")
        indexer.onChange = { done.fulfill() }
        indexer.scan()
        wait(for: [done], timeout: 5)

        let sessions = s.sessions(from: 0, to: Int.max / 2)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.turns, 1)
        XCTAssertEqual(sessions.first?.output, 50)
        XCTAssertEqual(sessions.first?.cacheRead, 7)
        XCTAssertEqual(sessions.first?.model, "claude-opus-5")
    }

    /// Codex rollouts: the session and model come from earlier lines, the
    /// tokens from `token_count`; cached input is split out of input.
    func testIndexerReadsCodexRollouts() throws {
        let s = try store()
        let root = dir.appendingPathComponent("sessions/2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-10-01T10:00:00.000Z","type":"session_meta","payload":{"id":"c1","cwd":"/tmp/codexproj"}}"#,
            #"{"timestamp":"2026-10-01T10:00:01.000Z","type":"turn_context","payload":{"type":"turn_context","cwd":"/tmp/codexproj","model":"gpt-5"}}"#,
            #"{"timestamp":"2026-10-01T10:00:09.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}}}"#,
            #"{"timestamp":"2026-10-01T10:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("rollout-c1.jsonl"), atomically: true, encoding: .utf8)

        let indexer = try XCTUnwrap(CostIndexer(store: s, root: dir.appendingPathComponent("sessions"), format: .codex))
        let done = expectation(description: "indexed")
        indexer.onChange = { done.fulfill() }
        indexer.scan()
        wait(for: [done], timeout: 5)

        let session = try XCTUnwrap(s.sessions(from: 0, to: Int.max / 2).first)
        XCTAssertEqual(session.sessionID, "c1")
        XCTAssertEqual(session.model, "gpt-5")
        XCTAssertEqual(session.input, 60)
        XCTAssertEqual(session.cacheRead, 40)
        XCTAssertEqual(session.output, 20)
    }

    // MARK: Model

    /// The card's range follows the account's allowance, never "all time".
    @MainActor func testCostRangeNeverStartsOnAllTime() {
        UserDefaults.standard.set("allTime", forKey: CostModel.rangeKey)
        defer { UserDefaults.standard.removeObject(forKey: CostModel.rangeKey) }
        let account = CostAccount(id: "test-x", provider: "claude", name: "Test", configDirectory: URL(fileURLWithPath: "/nonexistent"))
        let model = CostModel(account: account)
        XCTAssertNotEqual(model.range, .allTime)
        XCTAssertEqual(model.state, .unavailable)
    }

    /// Settings has a Costs pane, and searching for what it holds finds it.
    func testCostsPaneIsInSettings() {
        XCTAssertTrue(SettingsSection.allCases.contains(.costs))
        XCTAssertTrue(SettingsIndex.search("openrouter").contains { $0.section == .costs })
    }
}

/// A plan lookup that cannot succeed is not retried on every refresh: once
/// an hour per account, found or not.
@MainActor
final class PlanLookupThrottleTests: XCTestCase {
    func testALookupIsMadeAtMostOnceAnHourPerAccount() {
        let store = CostAccountStore.shared
        let id = "test-\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.takePlanLookup(id, now: start))
        XCTAssertFalse(store.takePlanLookup(id, now: start.addingTimeInterval(1)), "the next refresh, a second later")
        XCTAssertFalse(store.takePlanLookup(id, now: start.addingTimeInterval(59 * 60)))
        XCTAssertTrue(store.takePlanLookup(id, now: start.addingTimeInterval(61 * 60)))
        XCTAssertTrue(store.takePlanLookup("other-\(id)", now: start.addingTimeInterval(1)), "each account on its own")
    }
}
