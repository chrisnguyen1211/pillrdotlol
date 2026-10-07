import XCTest
@testable import LidEffort

/// Every API key is drawn in one cell: which ids gather into it, where it
/// stands, what its ring shows and what its card says.
@MainActor
final class APIKeyGroupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cell(_ id: String, _ windows: [LimitWindow] = [], status: ProviderStatus = .ok,
                      name: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name ?? id, glyph: .apiKey, fidelity: .official,
                         status: status, windows: windows, headlineID: windows.first?.id)
    }

    private func share(_ fraction: Double, text: String? = nil) -> LimitWindow {
        LimitWindow(id: "usage", label: "Usage", usedFraction: fraction, usedText: text)
    }

    private func balance(_ text: String, left: Double? = nil) -> LimitWindow {
        LimitWindow(id: "balance", label: "Balance", usedText: text, detail: "\(text) left",
                    money: left.map { UsageMoneyBreakdown(currency: "USD", spent: 0, remaining: $0) },
                    prefersUsedText: true)
    }

    // MARK: Who belongs

    func testEverythingReadWithAKeyBelongsAndNothingLocal() {
        for id in ["apikey_openrouter-k00001", "glm-k00a01", "ollama-k00ff1", "glm", "minimax", "ollama", "apify"] {
            XCTAssertTrue(APIKeyGroup.isMember(id), id)
        }
        for id in ["ollama-local", "ollama-local:model:qwen", "lmstudio", "lmstudio:model:qwen",
                   "custom-endpoint-1", "claude", "gemini-api", APIKeyGroup.id] {
            XCTAssertFalse(APIKeyGroup.isMember(id), id)
        }
        XCTAssertFalse(APIKeyGroup.isAddedKey("glm"), "a base provider's own reading is not an added key")
        XCTAssertTrue(APIKeyGroup.isAddedKey("glm-k00a01"))
    }

    func testTheGroupIdIsNoAgentAndNoGlyph() {
        XCTAssertEqual(EffortState.targetID(forProviderID: APIKeyGroup.id), APIKeyGroup.id)
        XCTAssertNil(ProviderGlyph.forProvider(APIKeyGroup.id))
        XCTAssertNil(ExtraKey.base(fromProviderID: APIKeyGroup.id))
    }

    // MARK: The cell

    func testKeysCollapseIntoOneCellWhereTheFirstStood() {
        let cells = [cell("claude"), cell("apikey_openrouter-k00001"), cell("apify"), cell("ollama-local"),
                     cell("glm-k00a01"), cell("glm"), cell("codex"), cell("custom-endpoint-1")]
        let grouped = APIKeyGroup.collapse(cells, memberOrder: ["glm-k00a01", "apikey_openrouter-k00001"])
        XCTAssertEqual(grouped.map(\.id), ["claude", APIKeyGroup.id, "ollama-local", "codex", "custom-endpoint-1"])
        let group = grouped[1]
        XCTAssertEqual(group.glyph, .apiKey)
        XCTAssertEqual(group.displayName, APIKeyGroup.displayName)
        XCTAssertEqual(group.keyGroup?.map(\.id), ["glm", "apify", "glm-k00a01", "apikey_openrouter-k00001"],
                       "the API tab's order: the base providers' own, then the keys as they were added")
    }

    func testNoKeysNoCell() {
        let cells = [cell("claude"), cell("ollama-local")]
        XCTAssertEqual(APIKeyGroup.collapse(cells).map(\.id), ["claude", "ollama-local"])
        XCTAssertNil(APIKeyGroup.collapse(cells).first?.keyGroup)
    }

    func testAKeyThatCanOnlyBeCheckedHasALineInTheCell() {
        let groq = cell("apikey_groq-k00004", [APIReading.keyWorks(.noUsageAPI).window(providerName: "Groq", currency: nil)])
        let grouped = APIKeyGroup.collapse([groq])
        XCTAssertEqual(grouped.map(\.id), [APIKeyGroup.id], "one check-only key still gives the keys a place")
        let figures = APIKeyGroup.figures(for: groq, now: now)
        XCTAssertEqual(figures.map(\.text), [L10n.t("Key works · \("Groq") doesn't share usage through its API")])
        XCTAssertNil(figures.first?.usedFraction)
    }

    // MARK: Order

    func testAnOldOrderPutsTheGroupWhereTheFirstKeyWas() {
        XCTAssertEqual(APIKeyGroup.groupedOrder(["claude", "glm", "codex", "glm-k00a01", "apikey_openrouter-k00001"]),
                       ["claude", APIKeyGroup.id, "codex"])
    }

    func testTheGroupKeepsItsOwnPlaceOnceItHasOne() {
        XCTAssertEqual(APIKeyGroup.groupedOrder(["apikey_openrouter-k00001", "codex", APIKeyGroup.id, "claude"]),
                       ["codex", APIKeyGroup.id, "claude"])
        XCTAssertEqual(APIKeyGroup.groupedOrder(["claude"]), ["claude"])
    }

    func testTheStoreDrawsOneCellInTheRememberedPlace() async {
        let defaults = UserDefaults(suiteName: "APIKeyGroupTests.\(UUID().uuidString)")!
        let providers: [UsageProvider] = [
            GroupStub(id: "claude", share: 0.2), GroupStub(id: "codex", share: 0.1),
            GroupStub(id: "apikey_openrouter-k00001", share: 0.4), GroupStub(id: "glm", share: 0.5),
            GroupStub(id: "glm-k00a01", share: 0.7),
        ]
        // Someone who dragged single rings about in an older version.
        let store = UsageStore(providers: providers, archive: UsageArchive(defaults: defaults),
                               order: ["glm-k00a01", "claude", "glm", "codex"])
        await store.refresh()
        XCTAssertEqual(store.notchSnapshots.map(\.id), [APIKeyGroup.id, "claude", "codex"])
        XCTAssertEqual(store.notchSnapshots.first?.keyGroup?.map(\.id), ["glm", "apikey_openrouter-k00001", "glm-k00a01"])
        XCTAssertEqual(store.notchSnapshots.first?.usedFraction, 0.7)
        XCTAssertEqual(Set(store.snapshots.map(\.id)).count, 5, "each key is still read, and alerted on, alone")

        store.order = ["claude", APIKeyGroup.id, "codex"]
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["claude", APIKeyGroup.id, "codex"])

        store.disconnected = [APIKeyGroup.id]
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["claude", "codex"], "hidden from the pill")
        XCTAssertEqual(store.snapshots.count, 5, "hiding the cell does not stop reading the keys")

        store.disconnected = ["apikey_openrouter-k00001", "glm-k00a01", "glm"]
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["claude", "codex"], "every key off: no cell")
    }

    func testTheStoreShowsTheEmptyCellUntilAKeyIsAdded() async {
        let defaults = UserDefaults(suiteName: "APIKeyGroupTests.\(UUID().uuidString)")!
        let store = UsageStore(providers: [GroupStub(id: "claude", share: 0.2)], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["claude", APIKeyGroup.id], "a place for keys, before any")
        XCTAssertEqual(store.notchSnapshots.last?.keyGroup, [])
        store.disconnected = [APIKeyGroup.id]
        XCTAssertEqual(store.notchSnapshots.map(\.id), ["claude"], "and it can be hidden")
    }

    func testSettingsListsOneRowInPlaceOfTheKeys() {
        let account = ProviderAccount(label: nil, plan: nil, source: "pillr", manageURL: nil)
        let rows = ["claude", "apikey_openrouter-k00001", "glm", "glm-k00a01", "codex", "apify"].map {
            ProviderSummary(id: $0, name: $0, glyph: .apiKey, account: account, signIn: .guidance(""))
        }
        XCTAssertEqual(SettingsView.accountRows(rows, order: []).map(\.id), ["claude", APIKeyGroup.id, "codex"])
        XCTAssertEqual(SettingsView.accountRows(rows, order: ["codex", "glm-k00a01", "claude"]).map(\.id),
                       ["codex", APIKeyGroup.id, "claude"])
        XCTAssertEqual(SettingsView.accountRows(rows, order: ["glm", "codex", "claude", APIKeyGroup.id]).map(\.id),
                       ["codex", "claude", APIKeyGroup.id])
        // A base provider switched off keeps its own row, Connect and all;
        // an added key switched off is still folded in — it is switched under API.
        let off: Set<String> = ["apify", "apikey_openrouter-k00001"]
        XCTAssertEqual(SettingsView.accountRows(rows, order: [], isConnected: { !off.contains($0) }).map(\.id),
                       ["claude", APIKeyGroup.id, "codex", "apify"])
    }

    // MARK: The ring

    func testTheRingIsTheKeyClosestToRunningOut() {
        let group = APIKeyGroup.snapshot(members: [
            cell("a", [share(0.2, text: "$16.00")]),
            cell("b", [share(0.85, text: "$1.50")]),
            cell("c", [balance("$3.00", left: 3)]),
        ])
        XCTAssertEqual(group.usedFraction, 0.85)
        XCTAssertEqual(group.headlineText, "$1.50")
        XCTAssertEqual(group.status, .ok)
        XCTAssertEqual(APIKeyGroup.ringMember(of: group.keyGroup!)?.id, "b")
    }

    func testASharedTopGoesToTheFirstKey() {
        let members = [cell("a", [share(0.5)]), cell("b", [share(0.5)])]
        XCTAssertEqual(APIKeyGroup.ringMember(of: members)?.id, "a")
        XCTAssertEqual(APIKeyGroup.snapshot(members: members).headlineText, APIKeyGroup.countText(2),
                       "no amount to print: the number of keys")
    }

    func testBalancesOnlyShowTheLowest() {
        let group = APIKeyGroup.snapshot(members: [
            cell("a", [balance("$40.00", left: 40)]),
            cell("b", [balance("$7.50", left: 7.5)]),
            cell("c", [balance("¥49.58")]),
        ])
        XCTAssertNil(group.usedFraction)
        XCTAssertEqual(group.headline?.prefersUsedText, true)
        XCTAssertEqual(group.headlineText, "$7.50")
    }

    func testNoAmountAnywhereCountsTheKeys() {
        let check = APIReading.keyWorks(.noUsageAPI).window(providerName: "Groq", currency: nil)
        let group = APIKeyGroup.snapshot(members: [cell("a", [check]), cell("b", [check]), cell("c", [check])])
        XCTAssertEqual(group.headlineText, L10n.t("\(3) keys"))
        XCTAssertTrue(group.hasReading)
    }

    func testAFailingKeyDimsTheCellWithoutHidingTheOthers() {
        let group = APIKeyGroup.snapshot(members: [
            cell("a", [share(0.3)]),
            cell("b", status: .needsAuth),
        ])
        XCTAssertTrue(group.status.isStale, "dimmed, the way a failing ring is")
        XCTAssertEqual(group.usedFraction, 0.3, "the working key still draws")
        XCTAssertEqual(group.keyGroup?.count, 2)
    }

    func testNothingReadYetIsSaid() {
        let group = APIKeyGroup.snapshot(members: [cell("a", status: .stale(since: .distantPast))])
        XCTAssertFalse(group.hasReading)
        XCTAssertEqual(APIKeyGroup.placeholderLine(for: group.keyGroup![0]), L10n.t("Not read yet"))
    }

    // MARK: The card

    func testTheCardSaysHowManyAndHowOld() {
        let members = [
            cell("a", [share(0.3)]),
            cell("b", [share(0.3)], status: .stale(since: now.addingTimeInterval(-120))),
        ]
        XCTAssertEqual(APIKeyGroup.note(for: members, now: now),
                       "\(APIKeyGroup.countText(2)) · \(ElapsedCopy.ago(since: now.addingTimeInterval(-120), now: now))")
        XCTAssertEqual(APIKeyGroup.note(for: [members[0]], now: now), L10n.t("1 key"))
    }

    func testEveryFigureAKeyHasIsALine() {
        let reading = APIReading.several([.balance(7.5, .money("USD")), .spend(3.2, .money("USD"), .month),
                                          .spend(41, .money("USD"), .total)])
        let key = cell("apikey_openrouter-k00001", reading.windows(providerName: "OpenRouter", currency: nil))
        XCTAssertEqual(APIKeyGroup.figures(for: key, now: now).map(\.text), [
            L10n.t("\("$7.50") left"),
            L10n.t("\("$3.20") spent this month"),
            L10n.t("\("$41.00") spent in total"),
        ])
    }

    func testAShareCarriesItsLabelBarAndReset() {
        let window = LimitWindow(id: "usage", label: "Usage", usedFraction: 0.32,
                                 detail: "3,200 of 10,000 characters used",
                                 resetsAt: now.addingTimeInterval(3 * 3600))
        let figure = APIKeyGroup.figures(for: cell("k", [window]), now: now).first
        XCTAssertEqual(figure?.label, "Usage")
        XCTAssertEqual(figure?.usedFraction, 0.32)
        XCTAssertEqual(figure?.text,
                       "3,200 of 10,000 characters used · \(ResetCopy.text(for: window.resetsAt!, now: now, format: .automatic))")
    }

    func testAFailingKeySaysWhy() {
        XCTAssertEqual(APIKeyGroup.problem(for: cell("a", status: .needsAuth)), L10n.t("That key was not accepted"))
        XCTAssertEqual(APIKeyGroup.problem(for: cell("a", status: .error("no reply"))), "no reply")
        XCTAssertNil(APIKeyGroup.problem(for: cell("a", [share(0.1)])))
        XCTAssertEqual(APIKeyGroup.menuLine(for: cell("a", status: .accessDenied, name: "Groq · Key 1"), now: now),
                       "Groq · Key 1: \(L10n.t("That key was not accepted"))")
    }

    func testALongListIsCutToTheCardAndCounted() {
        let keys = (0..<30).map { cell("apikey_openrouter-k\(String(format: "%05x", $0))", [share(0.1), balance("$1")]) }
        let budget = NotchLayout.defaultMaxCardHeight
        let plan = NotchLayout.keyGroupPlan(keys, cardBudget: budget)
        XCTAssertGreaterThan(plan.shown, 0)
        XCTAssertLessThan(plan.shown, keys.count)
        XCTAssertLessThanOrEqual(NotchLayout.cardHeight(windowCount: 1, keyGroupBody: plan.body), budget)

        let few = NotchLayout.keyGroupPlan(Array(keys.prefix(2)), cardBudget: budget)
        XCTAssertEqual(few.shown, 2)
        XCTAssertEqual(few.body, 2 * NotchLayout.keyRowHeight(keys[0]) + NotchLayout.blockSpacing, accuracy: 0.01)
    }

    func testAKeysAlertPointsAtTheGroupCell() {
        let model = NotchViewModel()
        model.updateSnapshots([cell("claude", [share(0.1)]),
                               APIKeyGroup.snapshot(members: [cell("glm-k00a01", [share(0.9)])])])
        let event = UsageResetEvent(providerID: "glm-k00a01", providerName: "GLM · Work", windowLabel: "Usage",
                                    glyph: .glm, previousFraction: 0.9, currentFraction: 0, resetsAt: nil)
        XCTAssertEqual(model.resetAlertIndex(for: event), 1)
        model.refreshing = ["glm-k00a01"]
        XCTAssertTrue(model.isRefreshing(model.snapshots[1]), "a key being read presses the cell in")
    }

    /// Along a side edge the session cap comes from the stack's length, and
    /// the stack's length from the tallest card. Sizing the keys card off
    /// that cap went round the loop until the app ran out of stack — on
    /// launch, on a real screen, which the other tests never give it.
    func testSizingTheKeysCardOnASideEdgeDoesNotGoRoundInCircles() {
        for edge in [NotchEdge.right, .left, .top] {
            let model = NotchViewModel()
            model.edge = edge
            model.screenSize = CGSize(width: 1920, height: 1080)
            model.updateSnapshots([cell("claude", [share(0.1)]),
                                   APIKeyGroup.snapshot(members: [cell("glm-k00a01", [share(0.9)]),
                                                                  cell("apikey_openrouter-k00001", [balance("$7")])])])
            XCTAssertGreaterThan(model.maxCardHeight(cellCount: 2), 0, "\(edge)")
            XCTAssertGreaterThan(model.sessionCap(cellCount: 2), 0, "\(edge)")
        }
    }
}

@MainActor
private final class GroupStub: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.apiKey
    let share: Double

    init(id: String, share: Double) {
        self.id = id
        self.displayName = id
        self.share = share
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "usage", label: "Usage", usedFraction: share)])
    }

    // MARK: Shown before any key

    func testTheNotchKeepsAnEmptyCellWhenAskedTo() {
        let claude = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                      status: .ok, windows: [])
        XCTAssertEqual(APIKeyGroup.collapse([claude]).map(\.id), ["claude"], "unchanged unless asked")
        let kept = APIKeyGroup.collapse([claude], keepEmpty: true)
        XCTAssertEqual(kept.map(\.id), ["claude", APIKeyGroup.id])
        XCTAssertEqual(kept.last?.keyGroup, [])
        XCTAssertEqual(kept.last?.headline?.usedText, L10n.t("Add key"))
        XCTAssertEqual(APIKeyGroup.note(for: [], now: Date()), "")
        XCTAssertEqual(NotchLayout.keyGroupPlan([]).shown, 0)
        XCTAssertGreaterThan(NotchLayout.keyGroupPlan([]).body, 0, "the card has its two lines")
    }

    func testTheAccountsListKeepsTheRowBeforeAnyKey() {
        let rows = [ProviderSummary(id: "claude", name: "Claude", glyph: .claude, account: nil, signIn: .guidance(""))]
        XCTAssertEqual(SettingsView.accountRows(rows, order: []).map(\.id), ["claude", APIKeyGroup.id])
    }
}
