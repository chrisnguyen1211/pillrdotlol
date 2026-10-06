import XCTest
@testable import LidEffort

/// The API tab's catalog: every entry is well-formed and safe to send a key
/// to, every readable answer is read the way its docs describe — strings as
/// numbers, cents and nano-dollars scaled, inverted ledgers turned round —
/// and anything else is refused rather than drawn. Nothing here reaches the
/// network or the keychain: requests stop at `CatalogEndpoint`.
@MainActor
final class APICatalogTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogEndpoint.self]
        session = URLSession(configuration: config)
        CatalogEndpoint.reset { _ in (500, [:], Data()) }
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        CatalogEndpoint.reset { _ in (500, [:], Data()) }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "APICatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private static let now = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03

    // MARK: Well-formed

    func testEveryEntryIsWellFormed() throws {
        let ids = APICatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        XCTAssertGreaterThan(ids.count, 60)
        for entry in APICatalog.entries {
            XCTAssertFalse(entry.name.isEmpty, entry.id)
            XCTAssertTrue(entry.id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }, entry.id)
            XCTAssertEqual(entry.consoleURL.scheme, "https", entry.id)
            XCTAssertNotNil(entry.consoleURL.host, entry.id)
            XCTAssertFalse(entry.note.isEmpty, entry.id)
            XCTAssertNotEqual(entry.regions.count, 1, "one region is no choice: \(entry.id)")
            XCTAssertEqual(Set(entry.regions.map(\.id)).count, entry.regions.count, entry.id)
            if entry.readability == .keyCheck {
                XCTAssertEqual(entry.measure, .keyCheck, entry.id)
            } else {
                XCTAssertNotEqual(entry.measure, .keyCheck, entry.id)
                XCTAssertFalse(entry.billedCheck, "only a key check may be billed: \(entry.id)")
            }
            if entry.readability == .adminKey { XCTAssertNotEqual(entry.keyKind, .normal, entry.id) }
            switch entry.route {
            case .existing:
                XCTAssertTrue(ExtraKey.bases.contains(entry.id), entry.id)
            case .catalog(let recipe):
                XCTAssertFalse(ExtraKey.bases.contains(entry.id), entry.id)
                // Every request the entry can make, in every region, is HTTPS
                // to a real host with nothing left unfilled.
                let regions: [APIRegion?] = entry.regions.isEmpty ? [nil] : entry.regions
                for region in regions {
                    var variables: [String: String] = [:]
                    for field in entry.fields { variables[field.id] = "value" }
                    for step in recipe.prefetch { variables[step.variable] = "value" }
                    let context = APIContext(entry: entry, region: region, variables: variables, now: Self.now)
                    for spec in recipe.prefetch.map(\.request) + [recipe.request] {
                        let request = try recipe.makeRequest(spec, key: "k", context: context)
                        XCTAssertEqual(request.url?.scheme, "https", entry.id)
                        XCTAssertNotNil(request.url?.host, entry.id)
                        XCTAssertFalse(request.url!.absoluteString.contains("{"), request.url!.absoluteString)
                        XCTAssertFalse(request.url!.absoluteString.contains("%7B"), request.url!.absoluteString)
                        XCTAssertEqual(request.timeoutInterval, CatalogKeyProvider.requestTimeout)
                        XCTAssertFalse(request.httpShouldHandleCookies)
                        if let body = request.httpBody {
                            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: body), entry.id)
                        }
                    }
                }
            }
        }
        for base in ExtraKey.bases { XCTAssertNotNil(APICatalog.entry(id: base), base) }
        // Left out on purpose: shut down, retired, a paid read, or cloud
        // signing keys rather than an API key.
        for gone in ["01ai", "lambda", "github", "githubmodels", "brave", "dashscope", "qianfan", "volcengine", "hunyuan"] {
            XCTAssertNil(APICatalog.entry(id: gone), gone)
        }
    }

    func testEveryRequiredFieldAndRegionShowsUpInTheRequest() throws {
        let fireworks = try XCTUnwrap(APICatalog.entry(id: "fireworks"))
        guard case .catalog(let recipe) = fireworks.route else { return XCTFail() }
        let context = APIContext(entry: fireworks, region: nil, variables: ["account": "my acct/x"], now: Self.now)
        let url = try recipe.makeRequest(recipe.request, key: "fw_k", context: context).url!.absoluteString
        XCTAssertTrue(url.contains("/v1/accounts/my%20acct%2Fx/billingUsage"), url)
        XCTAssertTrue(url.contains("startTime=2026-10-01T00:00:00Z"), url)

        let kimi = try XCTUnwrap(APICatalog.entry(id: "moonshot"))
        guard case .catalog(let kimiRecipe) = kimi.route else { return XCTFail() }
        for (region, host) in [("global", "api.moonshot.ai"), ("china", "api.moonshot.cn")] {
            let ctx = APIContext(entry: kimi, region: kimi.region(region), variables: [:], now: Self.now)
            XCTAssertEqual(try kimiRecipe.makeRequest(kimiRecipe.request, key: "sk", context: ctx).url?.host, host)
        }
    }

    func testOnlyHTTPSIsEverSentAKey() throws {
        let entry = try XCTUnwrap(APICatalog.entry(id: "poe"))
        let context = APIContext(entry: entry, region: nil, variables: [:], now: Self.now)
        for bad in ["http://api.poe.com/x", "https://user:pw@api.poe.com/x", "ftp://x", "https:///nohost"] {
            let recipe = APIRecipe(request: APIRequest(url: bad), parse: .keyWorks)
            XCTAssertThrowsError(try recipe.makeRequest(recipe.request, key: "k", context: context), bad)
        }
    }

    // MARK: Ids

    func testCatalogIDsRoundTripAndStayClearOfAgentsAndEffortTargets() {
        let agentTargets: Set<String> = ["claude", "codex", "grok", "gemini", "antigravity", "kimi", "cursor",
                                         "opencode", "copilot", "devin", "kilo", "kiro", "amp", "commandcode",
                                         "deepseek", "qianwenai", "ollama", "lmstudio", "glm", "minimax", "apify"]
        for entry in APICatalog.entries {
            let id = ExtraKey.makeID(base: entry.id)
            XCTAssertEqual(ExtraKey.base(fromProviderID: id), entry.id, id)
            XCTAssertTrue(ExtraKey.isExtraKey(providerID: id), id)
            XCTAssertEqual(APICatalog.entry(forProviderID: id)?.id, entry.id, id)
            if case .catalog = entry.route {
                XCTAssertTrue(id.hasPrefix("apikey_\(entry.id)-k"), id)
                let target = EffortState.targetID(forProviderID: id)
                XCTAssertFalse(agentTargets.contains(target), "\(id) would borrow \(target)'s effort")
                XCTAssertEqual(ProviderGlyph.forProvider(id), entry.glyph, id)
            } else {
                XCTAssertTrue(id.hasPrefix("\(entry.id)-k"), "a legacy base keeps its id's shape: \(id)")
            }
        }
        XCTAssertEqual(ProviderGlyph.forProvider("apikey_moonshot-k12345"), .kimi)
        XCTAssertEqual(ProviderGlyph.forProvider("apikey_poe-k12345"), .poe)
        // The one provider without a mark of its own keeps the key.
        XCTAssertEqual(ProviderGlyph.forProvider("apikey_leonardo-k12345"), .apiKey)
        for other in ["apikey_", "apikey_poe", "apikey_poe-k123", "apikey_nothere-k12345", "apikey_glm-k12345",
                      "apikey_poe-K12345", "poe-k12345", "kimi-k12345", "openrouter"] {
            XCTAssertNil(ExtraKey.base(fromProviderID: other), other)
        }
    }

    func testLegacyExtraKeysStillDecodeWithTheirIDsUnchanged() throws {
        let defaults = isolatedDefaults()
        // Exactly what 1.0 wrote: no `fields`.
        let stored = #"[{"id":"glm-k1a2b3","base":"glm","name":"Work","region":"china"},{"id":"apify-k00ff0","base":"apify","name":"Side"}]"#
        defaults.set(Data(stored.utf8), forKey: "extraKeys")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.extraKeys.map(\.id), ["glm-k1a2b3", "apify-k00ff0"])
        XCTAssertEqual(preferences.extraKeys.map(\.displayName), ["GLM · Work", "Apify · Side"])
        XCTAssertNil(preferences.extraKeys[0].fields)

        let neon = ExtraKey(id: "apikey_neon-k00001", base: "neon", name: "Prod", region: nil,
                            fields: ["project": "proj-1"])
        preferences.addExtraKey(neon)
        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.extraKeys.last, neon)
        XCTAssertEqual(reopened.extraKeys.last?.displayName, "Neon · Prod")
        XCTAssertTrue(reopened.isConnected(neon.id))

        // An entry the catalog no longer has is dropped, not trusted.
        let orphan = ExtraKey(id: "apikey_gone-k00002", base: "gone", name: "Old", region: nil)
        defaults.set(try JSONEncoder().encode([neon, orphan]), forKey: "extraKeys")
        XCTAssertEqual(Preferences(defaults: defaults).extraKeys, [neon])
    }

    func testDefaultNamesStartAtOneWhereThereIsNoOwnKey() {
        XCTAssertEqual(ExtraKey.defaultName(base: "openrouter", existing: []), L10n.t("Key \(1)"))
        let one = [ExtraKey(id: "apikey_openrouter-k00001", base: "openrouter", name: L10n.t("Key \(1)"), region: nil)]
        XCTAssertEqual(ExtraKey.defaultName(base: "openrouter", existing: one), L10n.t("Key \(2)"))
        XCTAssertEqual(ExtraKey.defaultName(base: "glm", existing: []), L10n.t("Key \(2)"))
        XCTAssertEqual(ExtraKey.defaultName(base: "glm", existing: [], hasOwnKey: false), L10n.t("Key \(1)"))
        XCTAssertEqual(ExtraKey.providerName(for: "moonshot"), "Kimi (Moonshot)")
        XCTAssertEqual(ExtraKey.defaultRegion(for: "siliconflow"), "global")
    }

    /// Every provider's mark is in the bundle, so none falls back to an
    /// empty outline.
    func testEveryProviderMarkIsInTheBundle() {
        for entry in APICatalog.entries where entry.glyph != .apiKey {
            XCTAssertTrue(Assets.image(named: entry.glyph.assetName) != nil || !entry.glyph.outline.isEmpty,
                          "\(entry.id): \(entry.glyph.assetName)")
        }
        XCTAssertEqual(APICatalog.entries.filter { $0.glyph == .apiKey }.map(\.id), ["leonardo"])
    }

    // MARK: Picker search

    func testSearchRanksTheBestMatchFirst() {
        func first(_ query: String) -> String? { APICatalog.search(query).first?.id }
        XCTAssertEqual(Set(APICatalog.search("open").prefix(2).map(\.id)), ["openai", "openrouter"])
        XCTAssertEqual(first("openr"), "openrouter")
        XCTAssertEqual(first("deeps"), "deepseek")
        XCTAssertEqual(first("kimi"), "moonshot")
        XCTAssertEqual(first("eleven"), "elevenlabs")
        // A name that starts with it beats one that only contains it.
        let groq = APICatalog.search("gr").map(\.id)
        XCTAssertLessThan(groq.firstIndex(of: "groq") ?? .max, groq.firstIndex(of: "openrouter") ?? .max)
    }

    func testPopularAndHighlightedRanges() {
        XCTAssertEqual(APICatalog.popular.map(\.id), APICatalog.popularIDs)
        let name = "OpenRouter"
        let ranges = APICatalog.matchedRanges(in: name, query: "rout")
        XCTAssertEqual(ranges.map { String(name[$0]) }, ["Rout"])
        XCTAssertTrue(APICatalog.matchedRanges(in: name, query: "zz").isEmpty)
    }

    func testSearchFindsProvidersByNameIDAndAlias() {
        func ids(_ query: String) -> Set<String> { Set(APICatalog.search(query).map(\.id)) }
        XCTAssertTrue(ids("kimi").contains("moonshot"))
        XCTAssertTrue(ids("Moonshot").contains("moonshot"))
        XCTAssertTrue(ids("zhipu").isSuperset(of: ["glm", "zai"]))
        XCTAssertTrue(ids("z.ai").isSuperset(of: ["glm", "zai"]))
        XCTAssertTrue(ids("glm").isSuperset(of: ["glm", "zai"]))
        XCTAssertTrue(ids("grok").contains("xai"))
        XCTAssertTrue(ids("open router").contains("openrouter"))
        XCTAssertTrue(ids("ELEVEN").contains("elevenlabs"))
        XCTAssertEqual(ids(""), Set(APICatalog.entries.map(\.id)))
        XCTAssertTrue(ids("zzzz-nothing").isEmpty)

        // What a provider does finds it, not only its name.
        XCTAssertTrue(ids("voice").isSuperset(of: ["elevenlabs", "deepgram"]))
        XCTAssertTrue(ids("scraping").contains("firecrawl"))
        XCTAssertTrue(ids("china").contains("deepseek"))
        // Letters in order, gaps allowed.
        XCTAssertTrue(ids("opnrtr").contains("openrouter"))

        let groups = APICatalog.grouped(APICatalog.search("a"))
        XCTAssertEqual(groups.map(\.category), APICategory.allCases.filter { c in groups.contains { $0.category == c } })
        for group in groups {
            let names = group.entries.map(\.name)
            XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        }
    }

    // MARK: Parsing

    private func parse(_ id: String, _ json: String?, headers: [String: String] = [:],
                       region: String? = nil) throws -> APIReading {
        let entry = try XCTUnwrap(APICatalog.entry(id: id), id)
        guard case .catalog(let recipe) = entry.route else { throw APIParseError.unrecognised }
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
        let context = APIContext(entry: entry, region: entry.region(region), variables: [:], now: Self.now)
        return try recipe.parse.read(APIResponse(json: object, headers: headers, status: 200, context: context))
    }

    /// One answer for every entry whose key reads something, and what it
    /// must read as.
    private static let readable: [String: (json: String, headers: [String: String], expected: APIReading)] = [
        "openrouter": (#"{"data":{"usage":12.5,"usage_monthly":3.25,"limit":null,"limit_remaining":null}}"#, [:],
                       .several([.spend(3.25, .money("USD"), .month), .spend(12.5, .money("USD"), .total)])),
        "openroutercredits": (#"{"data":{"total_credits":50,"total_usage":12.5}}"#, [:],
                              .balanceSpent(remaining: 37.5, spent: 12.5, .money("USD"))),
        "vercel": (#"{"balance":"95.50","total_used":"4.50"}"#, [:],
                   .balanceSpent(remaining: 95.5, spent: 4.5, .money("USD"))),
        "requesty": (#"[{"monthly_spend":2,"monthly_limit":10},{"monthly_spend":3,"monthly_limit":5}]"#, [:],
                     .used(5, of: 15, .money("USD"), resetsAt: nil)),
        "aimlapi": (#"{"current_balance":12.3,"currency":"USD"}"#, [:], .balance(12.3, .money("USD"))),
        "poe": (#"{"current_point_balance":1000000}"#, [:], .balance(1_000_000, .points)),
        "nanogpt": (#"{"usd_balance":"4.20","nano_balance":"1.0"}"#, [:], .balance(4.2, .money("USD"))),
        "venice": (#"{"data":{"balances":{"USD":10.5,"DIEM":3}}}"#, [:], .balance(10.5, .money("USD"))),
        "chutes": (#"{"balance":7.5,"quotas":[]}"#, [:], .balance(7.5, .money("USD"))),
        "cloudflare": (#"{"data":{"viewer":{"accounts":[{"aiInferenceAdaptiveGroups":[{"sum":{"totalNeurons":1200}},{"sum":{"totalNeurons":300}}]}]}},"errors":null}"#,
                       [:], .count(1500, .neurons, .month)),
        "openai": (#"{"object":"page","data":[{"results":[{"amount":{"value":1.5,"currency":"usd"}}]},{"results":[{"amount":{"value":2.25,"currency":"usd"}}]}],"has_more":false}"#,
                   [:], .spend(3.75, .money("USD"), .month)),
        "anthropic": (#"{"data":[{"results":[{"amount":"123.45","currency":"USD"}]},{"results":[{"amount":"76.55","currency":"USD"}]}],"has_more":false}"#,
                      [:], .spend(2.0, .money("USD"), .month)),
        // xAI's own example: $45 of credits bought ahead, nothing spent of a $200 limit.
        "xai": (#"{"coreInvoice":{"lines":[],"amountBeforeVat":"0","vatCost":"0","amountAfterVat":"0","totalWithCorr":{"val":"0"},"prepaidCredits":{"val":"-4500"},"prepaidCreditsUsed":{"val":"0"}},"effectiveSpendingLimit":"20000","defaultCredits":"0","billingCycle":{"year":2025,"month":11}}"#,
                [:], .several([.balance(45, .money("USD")), .used(0, of: 200, .money("USD"), resetsAt: nil)])),
        "runware": (#"{"data":[{"taskType":"accountManagement","operation":"getDetails","balance":{"amount":2450.75,"freeBalance":120,"currency":"USD"},"usage":{"today":{"credits":35.8,"requests":1850}}}]}"#,
                    [:], .balance(2450.75, .money("USD"))),
        "mistral": (#"{"total_cost":4.2,"currency":"eur"}"#, [:], .spend(4.2, .money("EUR"), .month)),
        "fireworks": (#"{"serverlessCosts":[{"costNanoUsd":"1500000000"},{"costNanoUsd":500000000}]}"#, [:],
                      .spend(2.0, .money("USD"), .month)),
        "deepinfra": (#"{"stripe_balance":-25.0,"recent":5.0,"limit":100,"suspended":false}"#, [:],
                      .several([.balance(20, .money("USD")), .spend(5, .money("USD"), .billingPeriod)])),
        "novita": (#"{"availableBalance":"123456","cashBalance":"0"}"#, [:], .balance(12.3456, .money("USD"))),
        "hyperbolic": (#"{"credits":1234}"#, [:], .balance(12.34, .money("USD"))),
        "featherless": (#"{"totals":{"requests":10,"tokens":1000,"cost":2500000000}}"#, [:],
                        .spend(2.5, .money("USD"), .month)),
        "deepseek": (#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"5.10"}]}"#,
                     [:], .balance(5.1, .money("USD"))),
        "moonshot": (#"{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3.0},"scode":"0x0","status":true}"#,
                     [:], .balance(49.58, .money(nil))),
        "siliconflow": (#"{"code":20000,"message":"OK","status":true,"data":{"balance":"0.88","chargeBalance":"88.00","totalBalance":"88.88"}}"#,
                        [:], .balance(88.88, .money(nil))),
        "stepfun": (#"{"type":"prepaid","balance":12.5,"total_cash_balance":10,"total_voucher_balance":2.5}"#, [:],
                    .balance(12.5, .money("CNY"))),
        "elevenlabs": (#"{"tier":"creator","character_count":3200,"character_limit":10000,"next_character_count_reset_unix":1793000000}"#,
                       [:], .used(3200, of: 10000, .characters, resetsAt: Date(timeIntervalSince1970: 1_793_000_000))),
        "deepgram": (#"{"balances":[{"balance_id":"b1","amount":10.5,"units":"usd"},{"balance_id":"b2","amount":2,"units":"usd"}]}"#,
                     [:], .balance(12.5, .money("USD"))),
        "cartesia": (#"{"data":[{"credits":100,"start_ts":"2026-10-01T00:00:00Z"},{"credits":50}]}"#, [:],
                     .count(150, .credits, .month)),
        "stability": (#"{"credits":42.5}"#, [:], .balance(42.5, .credits)),
        "runway": (#"{"creditBalance":1200,"tier":{"maxMonthlyCreditSpend":10000}}"#, [:], .balance(1200, .credits)),
        "leonardo": (#"{"user_details":[{"apiPaidTokens":100,"apiSubscriptionTokens":250,"apiPlanTokenRenewalDate":"2026-11-01T00:00:00.000Z"}]}"#,
                     [:], .left(350, of: nil, .credits, resetsAt: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))),
        "ideogram": (#"{"buckets":[{"start":"2026-10-01","items":[{"cost_total":1.5,"currency_code":"USD"},{"cost_total":"0.5"}]},{"cost_total":2,"line_items":[{"cost_total":2}]}]}"#,
                     [:], .spend(4.0, .money("USD"), .month)),
        "fal": (#"{"username":"me","credits":{"current_balance":15.5,"currency":"usd"}}"#, [:], .balance(15.5, .money("USD"))),
        "tavily": (#"{"key":{"usage":150,"limit":1000},"account":{"current_plan":"Researcher","plan_usage":500,"plan_limit":1000}}"#,
                   [:], .used(500, of: 1000, .credits, resetsAt: nil)),
        "serpapi": (#"{"searches_per_month":250,"this_month_usage":100,"plan_searches_left":150,"total_searches_left":150}"#,
                    [:], .used(100, of: 250, .searches, resetsAt: nil)),
        "serper": (#"{"balance":2500,"rateLimit":5}"#, [:], .balance(2500, .credits)),
        "exa": (#"{"total_cost_usd":3.5,"cost_breakdown":[]}"#, [:], .spend(3.5, .money("USD"), .billingPeriod)),
        "firecrawl": (#"{"success":true,"data":{"remainingCredits":400,"planCredits":500,"billingPeriodEnd":"2026-11-01T00:00:00Z"}}"#,
                      [:], .left(400, of: 500, .credits, resetsAt: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))),
        "jina": (#"{"wallet":{"total_balance":1000000}}"#, [:], .balance(1_000_000, .tokens)),
        "scrapingbee": (#"{"max_api_credit":1000,"used_api_credit":250,"max_concurrency":5}"#, [:],
                        .used(250, of: 1000, .credits, resetsAt: nil)),
        "scraperapi": (#"{"requestCount":100,"requestLimit":"5000","failedRequestCount":0}"#, [:],
                       .used(100, of: 5000, .requests, resetsAt: nil)),
        "brightdata": (#"{"balance":99.5,"pending_balance":1}"#, [:], .balance(99.5, .money("USD"))),
        "browserbase": (#"{"browserMinutes":120,"proxyBytes":0}"#, [:], .count(120, .minutes, .billingPeriod)),
        "neon": (#"{"project":{"id":"p","compute_time_seconds":7200}}"#, [:], .count(2, .computeHours, .billingPeriod)),
        "resend": (#"{"data":[]}"#, ["x-resend-monthly-quota": "42"], .count(42, .emails, .month)),
    ]

    func testEveryReadableEntryHasAFixtureAndReadsIt() throws {
        let readable = Set(APICatalog.entries.filter {
            if case .catalog = $0.route { return $0.readability != .keyCheck }
            return false
        }.map(\.id))
        XCTAssertEqual(readable, Set(Self.readable.keys), "every entry that reads usage is pinned by a fixture")
        for (id, fixture) in Self.readable {
            XCTAssertEqual(try parse(id, fixture.json, headers: fixture.headers), fixture.expected, id)
        }
    }

    /// A key that tells more than one thing shows all of it: what is left
    /// first, then this month, then everything — each its own window.
    func testSeveralFiguresBecomeSeveralWindowsLeftFirst() throws {
        let reading = try XCTUnwrap(APIReading.combine([
            .spend(3, .money("USD"), .month), .spend(40, .money("USD"), .total), .balance(7.5, .money("USD")),
        ]))
        let windows = reading.windows(providerName: "OpenRouter", currency: nil)
        XCTAssertEqual(windows.map(\.id), ["balance", "spend", "spend-total"])
        XCTAssertEqual(windows.map(\.detail), [L10n.t("\("$7.50") left"),
                                                L10n.t("\("$3.00") spent this month"),
                                                L10n.t("\("$40.00") spent in total")])
        XCTAssertEqual(APIReading.combine([.balance(1, .credits)]), .balance(1, .credits))
        XCTAssertNil(APIReading.combine([]))
        // Runware: the balance, the last thirty days and everything.
        XCTAssertEqual(try parse("runware", #"{"data":[{"taskType":"authentication"},{"taskType":"accountManagement","balance":{"amount":9.5,"currency":"USD"},"usage":{"last30Days":{"credits":4},"total":{"credits":120}}}]}"#),
                       .several([.balance(9.5, .money("USD")), .spend(4, .money("USD"), .last30Days),
                                 .spend(120, .money("USD"), .total)]))
        XCTAssertEqual(try parse("runware", #"{"data":[{"taskType":"accountManagement","balance":3.25}]}"#),
                       .balance(3.25, .money("USD")))
    }

    func testOpenRouterAddsTheAccountsCreditsWhenTheKeyMaySeeThem() async throws {
        CatalogEndpoint.reset { request in
            switch request.url?.path {
            case "/api/v1/key": return (200, [:], Data(#"{"data":{"usage":40,"usage_monthly":3}}"#.utf8))
            case "/api/v1/credits": return (200, [:], Data(#"{"data":{"total_credits":50,"total_usage":42.5}}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        let snapshot = try await provider("openrouter").fetchSnapshot()
        XCTAssertEqual(snapshot.windows.map(\.id), ["balance", "spend", "spend-total"])
        XCTAssertEqual(snapshot.headline?.detail, L10n.t("\("$7.50") left"))

        // A key that may not see the credits still reads its own figures.
        CatalogEndpoint.reset { request in
            request.url?.path == "/api/v1/key"
                ? (200, [:], Data(#"{"data":{"usage":40,"usage_monthly":3}}"#.utf8)) : (403, [:], Data())
        }
        let own = try await provider("openrouter").fetchSnapshot()
        XCTAssertEqual(own.windows.map(\.id), ["spend", "spend-total"])
    }

    func testABadKeyAnsweredWithA400IsRefusedNotAnOutage() async throws {
        CatalogEndpoint.reset { _ in
            (400, [:], Data(#"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#.utf8))
        }
        do {
            _ = try await provider("gemini").fetchSnapshot()
            XCTFail("a refused key was kept")
        } catch {
            XCTAssertEqual(UsageStore.providerStatus(for: error), .needsAuth)
        }
    }

    func testOtherShapesOfTheSameAnswers() throws {
        XCTAssertEqual(try parse("openrouter", #"{"data":{"usage_monthly":1,"limit":20,"limit_remaining":"7.5"}}"#),
                       .several([.left(7.5, of: 20, .money("USD"), resetsAt: nil), .spend(1, .money("USD"), .month)]))
        XCTAssertEqual(try parse("requesty", #"{"data":[{"monthly_spend":2},{"monthly_spend":1.5,"monthly_limit":4}]}"#),
                       .spend(3.5, .money("USD"), .month))
        XCTAssertEqual(try parse("venice", #"{"data":{"balances":{"USD":0,"DIEM":3}}}"#), .balance(3, .named("DIEM")))
        XCTAssertEqual(try parse("openai", #"{"data":[],"has_more":false}"#), .spend(0, .money("USD"), .month),
                       "a month with no spend yet is a real zero")
        XCTAssertEqual(try parse("tavily", #"{"key":{"usage":150,"limit":null},"account":{"plan_limit":0}}"#),
                       .count(150, .credits, .billingPeriod))
        XCTAssertEqual(try parse("serpapi", #"{"searches_per_month":0,"total_searches_left":900}"#),
                       .left(900, of: nil, .searches, resetsAt: nil))
        XCTAssertEqual(try parse("firecrawl", #"{"data":{"remainingCredits":700,"planCredits":500}}"#),
                       .left(700, of: nil, .credits, resetsAt: nil), "coupons past the plan have no share of it")
        XCTAssertEqual(try parse("deepseek", #"{"balance_infos":[{"currency":"CNY","total_balance":"7.00"}]}"#),
                       .balance(7, .money("CNY")))
    }

    func testRefusalsAndUnknownShapesAreNeverAReading() {
        func assertThrows(_ id: String, _ json: String?, _ expected: APIParseError, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try parse(id, json), id, file: file, line: line) { error in
                XCTAssertEqual(error as? APIParseError, expected, id, file: file, line: line)
            }
        }
        assertThrows("moonshot", #"{"code":1,"message":"invalid key","data":null}"#, .vendor("invalid key"))
        assertThrows("chutes", #"{"balance":null}"#, .unrecognised)
        assertThrows("poe", #"{"current_point_balance":true}"#, .unrecognised)
        assertThrows("poe", #"{"current_point_balance":"lots"}"#, .unrecognised)
        assertThrows("vercel", #"{"balance":"1.00","total_used":"-2"}"#, .unrecognised)
        assertThrows("openai", #"{"data":[{"results":[{"amount":{"value":"oops"}}]}]}"#, .unrecognised)
        assertThrows("openai", #"{"error":{"message":"nope"}}"#, .unrecognised)
        assertThrows("elevenlabs", #"{"character_count":10}"#, .unrecognised)
        assertThrows("cloudflare", #"{"data":null,"errors":[{"message":"unknown field"}]}"#, .vendor("unknown field"))
        assertThrows("cohere", #"{"valid":false}"#, .refused)
        assertThrows("minimaxapi", #"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#, .refused)
        assertThrows("minimaxapi", #"{"base_resp":{"status_code":1000,"status_msg":"unknown error"}}"#, .vendor("unknown error"))
        assertThrows("mistral", #"{"chat":{"models":{}}}"#, .unrecognised)
        assertThrows("resend", #"{"data":[]}"#, .unrecognised)
        assertThrows("ideogram", #"{"buckets":[{"items":[{"cost_total":-1}]}]}"#, .unrecognised)
        assertThrows("deepgram", #"{"balances":[{"amount":"x"}]}"#, .unrecognised)
    }

    func testKeyChecksReadRateLimitHeadersWhenThereAreAny() throws {
        XCTAssertEqual(try parse("groq", "{}", headers: ["x-ratelimit-remaining-requests": "14399",
                                                         "x-ratelimit-limit-requests": "14400"]),
                       .keyWorks(.requestsLeft(remaining: 14399, limit: 14400, today: true)))
        XCTAssertEqual(try parse("groq", "{}"), .keyWorks(.noUsageAPI))
        XCTAssertEqual(try parse("nebius", "{}", headers: ["x-ratelimit-remaining-requests": "59"]),
                       .keyWorks(.requestsLeft(remaining: 59, limit: nil, today: false)))
        XCTAssertEqual(try parse("cohere", #"{"valid":true,"organization_id":"o"}"#), .keyWorks(.noUsageAPI))
        XCTAssertEqual(try parse("minimaxapi", #"{"base_resp":{"status_code":1008}}"#), .keyWorks(.outOfCredits))
        XCTAssertEqual(try parse("minimaxapi", #"{"base_resp":{"status_code":2013,"status_msg":"bad model"}}"#),
                       .keyWorks(.noUsageAPI), "a parameter refused after the key was accepted still proves the key")
        XCTAssertEqual(try parse("together", nil), .keyWorks(.noUsageAPI))
    }

    // MARK: Drawing

    func testReadingsAreWrittenTheWayAConsoleWritesThem() {
        XCTAssertEqual(APIAmount.full(12.4, .money("USD")), "$12.40")
        XCTAssertEqual(APIAmount.full(1234.5, .money("CNY")), "¥1,234.50")
        XCTAssertEqual(APIAmount.full(3, .money("SGD")), "3.00 SGD")
        XCTAssertEqual(APIAmount.full(49.58, .money(nil), currency: "CNY"), "¥49.58")
        XCTAssertEqual(APIAmount.short(1234.5, .money("USD")), "$1.2K")
        XCTAssertEqual(APIAmount.short(123.4, .money("USD")), "$123")
        XCTAssertEqual(APIAmount.short(9.87, .money("USD")), "$9.87")
        XCTAssertEqual(APIAmount.short(1_000_000, .points), "1.0M")
        XCTAssertEqual(APIAmount.number(1200, .credits), "1,200")
        XCTAssertEqual(APIAmount.full(2.5, .computeHours), L10n.t("\("2.50") compute hours"))

        let balance = APIReading.balance(12.4, .money("USD")).window(providerName: "Poe", currency: nil)
        XCTAssertEqual(balance.detail, L10n.t("\("$12.40") left"))
        XCTAssertEqual(balance.usedText, "$12.40")
        XCTAssertTrue(balance.prefersUsedText)
        XCTAssertNil(balance.usedFraction, "a balance alone has no share to draw")

        let used = APIReading.used(3200, of: 10000, .characters, resetsAt: nil).window(providerName: "x", currency: nil)
        XCTAssertEqual(used.usedFraction ?? -1, 0.32, accuracy: 0.0001)
        XCTAssertEqual(used.detail, L10n.t("\("3,200") of \(L10n.t("\("10,000") characters")) used"))

        let spent = APIReading.balanceSpent(remaining: 75, spent: 25, .money("USD")).window(providerName: "x", currency: nil)
        XCTAssertEqual(spent.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(spent.money?.remaining, 75)

        let works = APIReading.keyWorks(.noUsageAPI).window(providerName: "Groq", currency: nil)
        XCTAssertEqual(works.detail, L10n.t("Key works · \("Groq") doesn't share usage through its API"))
        XCTAssertNil(works.usedFraction)
    }

    // MARK: The provider

    private func provider(_ base: String, region: String? = nil, fields: [String: String]? = nil,
                          key: String = "the-key", now: @escaping @Sendable () -> Date = { Date() }) throws -> CatalogKeyProvider {
        let extra = ExtraKey(id: ExtraKey.makeID(base: base), base: base, name: "Work", region: region, fields: fields)
        return try XCTUnwrap(CatalogKeyProvider(extra: extra, session: session, secret: { key }, now: now))
    }

    func testEachAuthStyleSendsTheKeyWhereTheProviderLooks() async throws {
        CatalogEndpoint.reset { request in
            switch request.url?.host {
            case "openrouter.ai": return (200, [:], Data(#"{"data":{"usage_monthly":1}}"#.utf8))
            case "api.elevenlabs.io": return (200, [:], Data(#"{"character_count":1,"character_limit":2}"#.utf8))
            case "serpapi.com": return (200, [:], Data(#"{"searches_per_month":10,"this_month_usage":1}"#.utf8))
            case "api.upstash.com": return (200, [:], Data("[]".utf8))
            case "api.fal.ai": return (200, [:], Data(#"{"credits":{"current_balance":1}}"#.utf8))
            case "api.anthropic.com": return (200, [:], Data(#"{"data":[]}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        _ = try await provider("openrouter").fetchSnapshot()
        _ = try await provider("elevenlabs").fetchSnapshot()
        _ = try await provider("serpapi", key: "a+b").fetchSnapshot()
        _ = try await provider("upstash", fields: ["email": "me@x.io"]).fetchSnapshot()
        _ = try await provider("fal").fetchSnapshot()
        _ = try await provider("anthropic", key: "sk-ant-admin01-xyz").fetchSnapshot()
        let requests = CatalogEndpoint.requests
        func request(_ host: String) -> URLRequest? { requests.first { $0.url?.host == host } }
        XCTAssertEqual(request("openrouter.ai")?.value(forHTTPHeaderField: "Authorization"), "Bearer the-key")
        XCTAssertEqual(request("api.elevenlabs.io")?.value(forHTTPHeaderField: "xi-api-key"), "the-key")
        XCTAssertNil(request("api.elevenlabs.io")?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request("serpapi.com")?.url?.query, "api_key=a%2Bb")
        XCTAssertEqual(request("api.upstash.com")?.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("me@x.io:the-key".utf8).base64EncodedString())
        XCTAssertEqual(request("api.fal.ai")?.value(forHTTPHeaderField: "Authorization"), "Key the-key")
        XCTAssertEqual(request("api.anthropic.com")?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-admin01-xyz")
        XCTAssertEqual(request("api.anthropic.com")?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertTrue(request("api.anthropic.com")?.url?.query?.contains("starting_at=") ?? false)
    }

    /// Pruna and Bria have nothing free to call: a job that cannot exist is
    /// looked up, a 404 proves the key and a 401 refuses it.
    func testAMissingJobProvesAKeyAndARefusalDoesNot() async throws {
        CatalogEndpoint.reset { request in
            let good = request.value(forHTTPHeaderField: "apikey") == "good"
                || request.value(forHTTPHeaderField: "api_token") == "good"
            return good ? (404, [:], Data(#"{"status":"NOT_FOUND"}"#.utf8)) : (401, [:], Data())
        }
        for base in ["pruna", "bria"] {
            let works = try await provider(base, key: "good").fetchSnapshot()
            XCTAssertEqual(works.status, .ok, base)
            do {
                _ = try await provider(base, key: "bad").fetchSnapshot()
                XCTFail("\(base) kept a refused key")
            } catch {
                XCTAssertEqual(UsageStore.providerStatus(for: error), .needsAuth, base)
            }
        }
        let paths = CatalogEndpoint.requests.compactMap(\.url?.path)
        XCTAssertTrue(paths.contains { $0.hasPrefix("/v1/predictions/status/spyx-check-") })
        XCTAssertTrue(paths.contains { $0.hasPrefix("/v2/status/spyx-check-") })
    }

    func testRunwareAsksForTheAccountWithATaskOfItsOwn() async throws {
        CatalogEndpoint.reset { _ in
            (200, [:], Data(#"{"data":[{"balance":{"amount":12.5,"currency":"USD"}}]}"#.utf8))
        }
        let snapshot = try await provider("runware").fetchSnapshot()
        XCTAssertEqual(snapshot.headline?.detail, L10n.t("\("$12.50") left"))
        let request = try XCTUnwrap(CatalogEndpoint.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer the-key")
        let body = try XCTUnwrap(CatalogEndpoint.bodies.first)
        let tasks = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        XCTAssertEqual(tasks.first?["taskType"] as? String, "accountManagement")
        XCTAssertEqual(tasks.first?["operation"] as? String, "getDetails")
        XCTAssertNotNil(UUID(uuidString: tasks.first?["taskUUID"] as? String ?? ""))
    }

    func testAPrefetchFindsTheProjectAndTheReadingComesFromIt() async throws {
        CatalogEndpoint.reset { request in
            switch request.url?.path {
            case "/v1/projects": return (200, [:], Data(#"{"projects":[{"project_id":"p-42","name":"Main"}]}"#.utf8))
            case "/v1/projects/p-42/balances": return (200, [:], Data(#"{"balances":[{"amount":3.5,"units":"usd"}]}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        let snapshot = try await provider("deepgram").fetchSnapshot()
        XCTAssertEqual(snapshot.headline?.detail, L10n.t("\("$3.50") left"))
        XCTAssertEqual(CatalogEndpoint.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Token the-key", "Token the-key"])

        // Typed in, the prefetch is skipped.
        CatalogEndpoint.reset { request in
            request.url?.path == "/api/v2/projects/mine"
                ? (200, [:], Data(#"{"project":{"compute_time_seconds":3600}}"#.utf8)) : (404, [:], Data())
        }
        let neon = try await provider("neon", fields: ["project": "mine"]).fetchSnapshot()
        XCTAssertEqual(CatalogEndpoint.requests.count, 1)
        XCTAssertEqual(neon.headline?.usedText, "1")

        CatalogEndpoint.reset { _ in (200, [:], Data(#"{"projects":[]}"#.utf8)) }
        do {
            _ = try await provider("deepgram").fetchSnapshot()
            XCTFail("no project, no reading")
        } catch UsageProviderError.apiError(let why) {
            XCTAssertEqual(why, L10n.t("Couldn't find a project on this \("Deepgram") account"))
        }
    }

    /// The case that was reported: a management key, the team read from it,
    /// and the invoice preview — which a team billed after the fact has,
    /// where the prepaid ledger answered 404.
    func testXAIReadsTheTeamFromTheKeyAndTheInvoicePreview() async throws {
        CatalogEndpoint.reset { request in
            guard request.url?.host == "management-api.x.ai" else { return (404, [:], Data()) }
            switch request.url?.path {
            case "/auth/management-keys/validation":
                return request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt"
                    ? (200, [:], Data(#"{"apiKeyId":"k","teamId":"t-1","scope":"SCOPE_TEAM","scopeId":"t-1"}"#.utf8))
                    : (401, [:], Data())
            case "/v1/billing/teams/t-1/postpaid/invoice/preview":
                return (200, [:], Data(#"{"coreInvoice":{"amountAfterVat":"1250","prepaidCredits":{"val":"0"},"prepaidCreditsUsed":{"val":"0"}},"effectiveSpendingLimit":"5000"}"#.utf8))
            case "/v1/billing/teams/t-1/prepaid/balance":
                return (404, [:], Data())
            default:
                return (404, [:], Data())
            }
        }
        // The team comes from the key: nothing typed.
        let snapshot = try await provider("xai", key: "mgmt").fetchSnapshot()
        let detail = try XCTUnwrap(snapshot.headline?.detail)
        XCTAssertTrue(detail.contains("12.50") && detail.contains("$50.00"), detail)
        XCTAssertEqual(snapshot.headline?.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertFalse(CatalogEndpoint.requests.contains { $0.url?.path.hasSuffix("/prepaid/balance") == true })

        // An inference key is refused at the first step, and says which key it wanted.
        await assertFails(try provider("xai", key: "xai-inference"),
                          .apiError(L10n.t("\("xAI") refused this key. Reading usage needs \(L10n.t("a management key")).")))

        // A typed team that is not the key's: said in xAI's terms, not as "unexpected".
        await assertFails(try provider("xai", fields: ["team": "wrong"], key: "mgmt"),
                          .apiError(L10n.t("xAI has no billing for that team — check the Team ID, or leave it empty")))
    }

    func testSpecialKeysAreExplainedTheMomentTheirProviderIsChosen() {
        for entry in APICatalog.entries where entry.readability == .adminKey {
            XCTAssertNotNil(APICatalog.keyGuide(for: entry.id), "\(entry.id) needs a key guide")
        }
        XCTAssertNil(APICatalog.keyGuide(for: "openrouter"), "an ordinary key needs no warning")
        XCTAssertTrue(APICatalog.keyGuide(for: "xai")?.contains("Management keys") ?? false)
    }

    func testTheRedirectGuardRefusesEveryRedirect() {
        let task = session.dataTask(with: URL(string: "https://api.poe.com")!)
        var followed: URLRequest? = URLRequest(url: URL(string: "https://x")!)
        NoRedirects().urlSession(session, task: task,
                                 willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://api.poe.com")!, statusCode: 302,
                                                                             httpVersion: nil, headerFields: nil)!,
                                 newRequest: URLRequest(url: URL(string: "https://evil.example")!)) { followed = $0 }
        XCTAssertNil(followed)
    }

    func testStatusCodesBecomeHonestFailures() async throws {
        CatalogEndpoint.reset { _ in (401, [:], Data()) }
        await assertFails(try provider("poe"), .needsAuth)
        CatalogEndpoint.reset { _ in (403, [:], Data()) }
        await assertFails(try provider("groq"), .needsAuth, "a key check refused is a key refused")
        await assertFails(try provider("featherless"),
                          .apiError(L10n.t("\("Featherless") refused this key. Reading usage needs \(L10n.t("an admin key")).")))
        await assertFails(try provider("venice"),
                          .apiError(L10n.t("\("Venice AI") won't share usage with this key — try one with full account access")))
        CatalogEndpoint.reset { _ in (429, ["Retry-After": "5"], Data()) }
        await assertFails(try provider("poe"), .rateLimited(retryAfter: 60), "never sooner than a minute")
        CatalogEndpoint.reset { _ in (500, [:], Data()) }
        await assertFails(try provider("poe"), .badResponse(status: 500))
        CatalogEndpoint.reset { _ in (200, [:], Data("<html>".utf8)) }
        await assertFails(try provider("poe"), .apiError(L10n.t("\("Poe") answered in a way spyx doesn't recognise")))

        // Payment required: the key is good, the account is empty.
        CatalogEndpoint.reset { _ in (402, [:], Data()) }
        let empty = try await provider("together").fetchSnapshot()
        XCTAssertEqual(empty.headline?.detail, L10n.t("Key works · out of credits"))

        // Best-effort usage: a 200 without it still proves the key.
        CatalogEndpoint.reset { _ in (200, [:], Data(#"{"chat":{}}"#.utf8)) }
        let mistral = try await provider("mistral").fetchSnapshot()
        XCTAssertEqual(mistral.headline?.detail, L10n.t("Key works · spyx couldn't read the usage in \("Mistral")'s answer"))
    }

    private func assertFails(_ make: @autoclosure () throws -> CatalogKeyProvider, _ expected: UsageProviderError,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let provider = try make()
            _ = try await provider.fetchSnapshot(freshness: .fromSource)
            XCTFail("expected \(expected) \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(String(describing: error), String(describing: expected), message, file: file, line: line)
        }
    }

    func testAnAdminEntryRefusesAnOrdinaryKeyBeforeSendingIt() async throws {
        CatalogEndpoint.reset { _ in (200, [:], Data(#"{"data":[]}"#.utf8)) }
        await assertFails(try provider("openai", key: "sk-proj-abc"),
                          .apiError(L10n.t("\("OpenAI") needs an admin key here — one that starts with \("sk-admin-")")))
        XCTAssertTrue(CatalogEndpoint.requests.isEmpty, "the wrong key never leaves the Mac")
        _ = try await provider("openai", key: "sk-admin-abc").fetchSnapshot()
        XCTAssertEqual(CatalogEndpoint.requests.count, 1)
    }

    func testARedirectIsNotFollowedWithTheKey() async throws {
        CatalogEndpoint.reset { request in
            request.url?.host == "api.poe.com"
                ? (302, ["Location": "https://evil.example/steal"], Data())
                : (200, [:], Data(#"{"current_point_balance":1}"#.utf8))
        }
        await assertFails(try provider("poe"), .badResponse(status: 302))
        XCTAssertEqual(CatalogEndpoint.requests.map { $0.url?.host }, ["api.poe.com"])
    }

    func testReadingsAreReusedOnTheScheduleAndBilledChecksWaitToBeAsked() async throws {
        CatalogEndpoint.reset { _ in (200, [:], Data(#"{"current_point_balance":5}"#.utf8)) }
        let clock = Clock(Self.now)
        let poe = try provider("poe", now: { clock.now })
        _ = try await poe.fetchSnapshot()
        _ = try await poe.fetchSnapshot()
        XCTAssertEqual(CatalogEndpoint.requests.count, 1, "a balance is not re-read every minute")
        clock.now = Self.now.addingTimeInterval(6 * 60)
        _ = try await poe.fetchSnapshot()
        XCTAssertEqual(CatalogEndpoint.requests.count, 2)
        poe.forgetCachedCredential()
        _ = try await poe.fetchSnapshot()
        XCTAssertEqual(CatalogEndpoint.requests.count, 3, "Check now asks again")

        CatalogEndpoint.reset { _ in (200, [:], Data("{}".utf8)) }
        let perplexity = try provider("perplexity")
        let kept = try await perplexity.fetchSnapshot()
        XCTAssertTrue(CatalogEndpoint.requests.isEmpty, "a billed check is never spent on a schedule")
        XCTAssertEqual(kept.headline?.detail, L10n.t("Key kept · each check is billed, so spyx checks only when you ask"))
        let checked = try await perplexity.fetchSnapshot(freshness: .fromSource)
        XCTAssertEqual(CatalogEndpoint.requests.count, 1)
        XCTAssertEqual(CatalogEndpoint.requests.first?.httpMethod, "POST")
        XCTAssertEqual(checked.headline?.detail, L10n.t("Key works · \("Perplexity") doesn't share usage through its API"))
        _ = try await perplexity.fetchSnapshot()
        XCTAssertEqual(CatalogEndpoint.requests.count, 1)
    }

    func testAKeyCheckIsALineInTheAPIKeysCell() async throws {
        CatalogEndpoint.reset { request in
            request.url?.host == "api.groq.com" ? (200, [:], Data("{}".utf8))
                : (200, [:], Data(#"{"current_point_balance":5}"#.utf8))
        }
        let groq = try provider("groq")
        let poe = try provider("poe")
        let store = UsageStore(providers: [groq, poe], archive: UsageArchive(defaults: isolatedDefaults()))
        await store.refresh()
        XCTAssertEqual(Set(store.snapshots.map(\.id)), [groq.id, poe.id], "Settings still has the reading")
        // One cell for every key; the check has a line in it, not a ring.
        XCTAssertEqual(store.notchSnapshots.map(\.id), [APIKeyGroup.id])
        XCTAssertEqual(Set(store.notchSnapshots.first?.keyGroup?.map(\.id) ?? []), [groq.id, poe.id])
        XCTAssertFalse(APICatalog.drawsRing(providerID: groq.id))
        XCTAssertTrue(APICatalog.drawsRing(providerID: poe.id))
        XCTAssertTrue(APICatalog.drawsRing(providerID: "glm"))
    }

    // MARK: Adding one

    func testAKeyIsKeptOnlyOnceItHasBeenRead() async throws {
        CatalogEndpoint.reset { _ in (200, [:], Data(#"{"data":{"usage_monthly":2}}"#.utf8)) }
        var stored: [(String, String)] = []
        let outcome = await ExtraKeyVerifier.add(
            base: "openrouter", name: "", key: " sk-or-v1-good ", region: nil, existing: [],
            makeProvider: { [session] extra, key in CatalogKeyProvider(extra: extra, session: session!, secret: { key }) },
            storeSecret: { stored.append(($0, $1)); return true })
        guard case .added(let extra) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(extra.id.hasPrefix("apikey_openrouter-k"))
        XCTAssertEqual(extra.name, L10n.t("Key \(1)"))
        XCTAssertEqual(extra.displayName, "OpenRouter · " + L10n.t("Key \(1)"))
        XCTAssertEqual(stored.map(\.1), ["sk-or-v1-good"])
        XCTAssertEqual(CatalogEndpoint.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-good")

        for (status, body, reason) in [
            (401, "", L10n.t("That key was not accepted")),
            (200, "[]", L10n.t("Couldn't connect — \(L10n.t("\("OpenRouter") answered in a way spyx doesn't recognise"))")),
        ] {
            CatalogEndpoint.reset { _ in (status, [:], Data(body.utf8)) }
            stored = []
            let refused = await ExtraKeyVerifier.add(
                base: "openrouter", name: "", key: "sk-or-v1-bad", region: nil, existing: [],
                makeProvider: { [session] extra, key in CatalogKeyProvider(extra: extra, session: session!, secret: { key }) },
                storeSecret: { stored.append(($0, $1)); return true })
            XCTAssertEqual(refused, .failed(reason))
            XCTAssertTrue(stored.isEmpty)
        }
    }

    func testARequiredFieldIsAskedForBeforeAnythingIsSent() async {
        var asked = 0
        let outcome = await ExtraKeyVerifier.add(
            base: "fireworks", name: "", key: "fw_k", region: nil, fields: ["account": "  "], existing: [],
            makeProvider: { _, _ in asked += 1; return nil },
            storeSecret: { _, _ in XCTFail("nothing to keep"); return true })
        XCTAssertEqual(outcome, .failed(L10n.t("Fill in \(L10n.t("Account ID")) first")))
        XCTAssertEqual(asked, 0)
    }

    func testTheRowSaysWhatTheKeyRead() {
        func snapshot(_ status: ProviderStatus, _ windows: [LimitWindow]) -> ProviderSnapshot {
            ProviderSnapshot(id: "x", displayName: "x", glyph: .apiKey, fidelity: .official, status: status, windows: windows)
        }
        let window = APIReading.balance(3, .money("USD")).window(providerName: "Poe", currency: nil)
        XCTAssertEqual(APIKeyRow.line(for: snapshot(.ok, [window]))?.text, L10n.t("\("$3.00") left"))
        XCTAssertEqual(APIKeyRow.line(for: snapshot(.needsAuth, []))?.isProblem, true)
        XCTAssertEqual(APIKeyRow.line(for: snapshot(.error("down"), []))?.text, "down")
        XCTAssertNil(APIKeyRow.line(for: snapshot(.stale(since: .distantPast), [])), "a placeholder is not a reading")
        XCTAssertNil(APIKeyRow.line(for: nil))
    }

    func testTheNewWordsAreTranslated() {
        for code in ["fr", "ja", "pt-BR", "ru", "zh-Hans"] {
            let locale = Locale(identifier: code)
            for key: String.LocalizationValue in ["Add Key", "Reads usage", "Admin key", "Key check", "Search providers",
                                                  "AI routers & gateways", "Speech & media", "Get a key", "Check now",
                                                  "Add an API key", "API Keys", "Shows the balance left."] {
                XCTAssertNotEqual(L10n.t(key, locale: locale), L10n.t(key, locale: Locale(identifier: "en")), "\(code): \(key)")
            }
            let works = L10n.t("Key works · \("Groq") doesn't share usage through its API", locale: locale)
            XCTAssertTrue(works.contains("Groq"), works)
            XCTAssertFalse(works.contains("doesn't share"), "\(code): \(works)")
            let used = L10n.t("\("3") of \("10") used", locale: locale)
            XCTAssertTrue(used.contains("3") && used.contains("10"), used)
        }
    }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class CatalogEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) -> (Int, [String: String], Data) = { _ in (500, [:], Data()) }
    private static var recorded: [URLRequest] = []
    private static var recordedBodies: [Data] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    /// What each request sent: by the time a request reaches a protocol its
    /// body has become a stream.
    static var bodies: [Data] { lock.withLock { recordedBodies } }

    static func reset(_ handler: @escaping (URLRequest) -> (Int, [String: String], Data)) {
        lock.withLock { self.handler = handler; recorded = []; recordedBodies = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.lock.withLock { () -> (Int, [String: String], Data) in
            Self.recorded.append(request)
            if let body = request.httpBody ?? Self.read(request.httpBodyStream) { Self.recordedBodies.append(body) }
            return Self.handler(request)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
            // What the loader does with a redirect: offers it to the task's
            // delegate, and — refused — finishes with the 3xx itself.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
