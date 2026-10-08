import Foundation

/// What each coding agent's plan costs a month, so the dashboard can count
/// the plans without anyone typing a price.
///
/// The plan comes from what each agent already reports (Cursor's membership
/// type, Copilot's plan, GLM's level, Kiro's plan line…). Its list price is
/// looked up here, by agent: "pro" is $20 at Cursor and $200 at ChatGPT, so
/// a name alone means nothing. A price set in Settings wins over the table.
enum CodingPlans {
    struct Price: Equatable {
        /// As the vendor names it.
        let name: String
        /// Monthly list price in US dollars, billed monthly.
        let usd: Double
    }

    /// The agent a provider id belongs to: `claude-work` is Claude,
    /// `codex-2` is Codex.
    static func agent(of providerID: String) -> String {
        let base = providerID.split(separator: "-").first.map(String.init) ?? providerID
        return ["claude", "codex"].contains(base) ? base : providerID
    }

    /// A plan name brought to one spelling: lower case, `LEVEL_` and the
    /// vendor's own name dropped, `+` as "plus", separators gone.
    static func key(_ plan: String, agent: String) -> String {
        var text = plan.lowercased()
        text = text.replacingOccurrences(of: "level_", with: "")
        for brand in [agent, "github copilot", "copilot", "chatgpt", "claude", "kiro", "kilo", "amp", "supergrok"] {
            text = text.replacingOccurrences(of: brand, with: " ")
        }
        text = text.replacingOccurrences(of: "+", with: " plus ")
        text = text.replacingOccurrences(of: "default_", with: "")
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !["plan", "subscription", "tier"].contains($0) }
        return words.joined(separator: "_")
    }

    /// The table: agent → plan key → price. Prices as listed by each vendor
    /// for monthly billing, checked on the date below.
    /// Only names that say which plan they are: Claude's bare "max" could be
    /// 5x or 20x, so it is left for a price typed in Settings.
    static let checked = "2026-10-09"
    static let table: [String: [String: Price]] = [
        // claude.com/pricing
        "claude": [
            "free": .init(name: "Free", usd: 0), "pro": .init(name: "Pro", usd: 20),
            "max_5x": .init(name: "Max 5x", usd: 100), "max_20x": .init(name: "Max 20x", usd: 200),
            "team": .init(name: "Team Standard", usd: 25), "team_standard": .init(name: "Team Standard", usd: 25),
            "team_1": .init(name: "Team Premium", usd: 125),
        ],
        // ChatGPT plans, which Codex runs on (help.openai.com)
        "codex": [
            "free": .init(name: "Free", usd: 0), "go": .init(name: "Go", usd: 8), "plus": .init(name: "Plus", usd: 20),
            "prolite": .init(name: "Pro 100", usd: 100), "pro": .init(name: "Pro", usd: 200),
            "team": .init(name: "Business", usd: 25), "business": .init(name: "Business", usd: 25),
        ],
        // cursor.com/docs/account/pricing
        "cursor": [
            "free": .init(name: "Hobby", usd: 0), "hobby": .init(name: "Hobby", usd: 0), "free_trial": .init(name: "Pro trial", usd: 0),
            "pro": .init(name: "Pro", usd: 20), "pro_plus": .init(name: "Pro+", usd: 60), "ultra": .init(name: "Ultra", usd: 200),
            "team": .init(name: "Teams", usd: 40),
        ],
        // docs.github.com/en/copilot/get-started/plans
        "copilot": [
            "free_limited": .init(name: "Free", usd: 0), "individual_edu": .init(name: "Student", usd: 0),
            "individual": .init(name: "Pro", usd: 10), "individual_pro": .init(name: "Pro+", usd: 39),
            "individual_max": .init(name: "Max", usd: 100),
            "business": .init(name: "Business", usd: 19), "enterprise": .init(name: "Enterprise", usd: 39),
        ],
        // kimi.ai membership pricing; pillr shows the level without LEVEL_
        "kimi": [
            "free": .init(name: "Adagio", usd: 0), "basic": .init(name: "Moderato", usd: 19),
            "intermediate": .init(name: "Allegretto", usd: 39), "advanced": .init(name: "Allegro", usd: 99),
        ],
        // z.ai GLM Coding Plan, monthly billing
        "glm": [
            "lite": .init(name: "Lite", usd: 18), "pro": .init(name: "Pro", usd: 80), "max": .init(name: "Max", usd: 168),
        ],
        // platform.minimax.io Token Plan, which replaced the Coding Plan
        "minimax": [
            "token_plus": .init(name: "Token Plan Plus", usd: 22), "token_max": .init(name: "Token Plan Max", usd: 55),
            "token_ultra": .init(name: "Token Plan Ultra", usd: 132),
            "plus": .init(name: "Token Plan Plus", usd: 22), "max": .init(name: "Token Plan Max", usd: 55),
            "ultra": .init(name: "Token Plan Ultra", usd: 132),
        ],
        // kiro.dev/pricing
        "kiro": [
            "free": .init(name: "Free", usd: 0), "pro": .init(name: "Pro", usd: 20), "pro_plus": .init(name: "Pro+", usd: 40),
            "pro_max": .init(name: "Pro Max", usd: 100), "power": .init(name: "Power", usd: 200),
        ],
        // kilo.ai/pricing: Kilo Pass, by name or by its tier id
        "kilo": [
            "pass_starter": .init(name: "Kilo Pass Starter", usd: 19), "pass_pro": .init(name: "Kilo Pass Pro", usd: 49),
            "pass_expert": .init(name: "Kilo Pass Expert", usd: 199),
            "19": .init(name: "Kilo Pass Starter", usd: 19), "49": .init(name: "Kilo Pass Pro", usd: 49),
            "199": .init(name: "Kilo Pass Expert", usd: 199),
        ],
        // commandcode.ai/docs/resources/pricing-limits, by plan id
        "commandcode": [
            "individual_go": .init(name: "Go", usd: 1), "goat": .init(name: "GOAT", usd: 10),
            "individual_goat": .init(name: "GOAT", usd: 10), "individual_provider": .init(name: "Provider", usd: 15),
            "individual_pro": .init(name: "Pro", usd: 20), "individual_pro_v1": .init(name: "Pro", usd: 20),
            "individual_max": .init(name: "Max 10x", usd: 100), "individual_ultra": .init(name: "Max 20x", usd: 200),
            "teams_pro": .init(name: "Team Pro", usd: 40),
        ],
        // ampcode.com/pricing
        "amp": [
            "free": .init(name: "Free", usd: 0), "megawatt": .init(name: "Megawatt", usd: 20),
            "gigawatt": .init(name: "Gigawatt", usd: 200),
        ],
        // opencode.ai/docs/go
        "opencode": [
            "go": .init(name: "Go", usd: 10), "go_plus": .init(name: "Go Plus", usd: 40),
        ],
    ]

    /// Prices set by hand in Settings → Costs, in dollars a month, by
    /// provider id. They win over the table.
    static let overridesKey = "codingPlanPrices"

    static var overrides: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: overridesKey) }
    }

    /// One agent on a plan, as the dashboard counts it.
    struct Row: Identifiable, Equatable {
        enum Source: Equatable { case table, typed, account }
        let id: String
        let agentName: String
        let glyph: ProviderGlyph
        /// The plan as the agent reported it.
        let reported: String
        /// The vendor's name for it, when known.
        let name: String?
        /// A month of the plan, and the currency it is in.
        let monthly: Double?
        let currency: String
        let source: Source?
    }

    /// The plans the agents report, priced: Claude and Codex logins set to a
    /// monthly plan from their own account, every other agent from its
    /// reported plan. A login paid per token has no plan to count.
    @MainActor
    static func rows(snapshots: [ProviderSnapshot], accounts: [CostAccount], localCurrency: String) -> [Row] {
        var out: [Row] = []
        var seen: Set<String> = []
        for snapshot in snapshots where !snapshot.id.hasPrefix(ExtraKey.catalogPrefix) && !seen.contains(snapshot.id) {
            seen.insert(snapshot.id)
            let typed = overrides[snapshot.id]
            if let account = accounts.first(where: { $0.id == snapshot.id }) {
                guard account.billing == .subscription else { continue }
                let reported = account.planTier.map { PlanCatalog.shared.name(for: $0) } ?? snapshot.plan ?? ""
                if let typed {
                    out.append(Row(id: snapshot.id, agentName: snapshot.displayName, glyph: snapshot.glyph, reported: reported,
                                   name: reported, monthly: typed, currency: "USD", source: .typed))
                } else if account.monthlyPrice > 0 {
                    out.append(Row(id: snapshot.id, agentName: snapshot.displayName, glyph: snapshot.glyph, reported: reported,
                                   name: reported, monthly: account.monthlyPrice, currency: localCurrency, source: .account))
                } else {
                    let usd = account.planTier.flatMap { PlanCatalog.shared.usd(for: $0) }
                        ?? account.planTier.flatMap { price(providerID: snapshot.id, plan: $0)?.usd }
                        ?? snapshot.plan.flatMap { price(providerID: snapshot.id, plan: $0)?.usd }
                    out.append(Row(id: snapshot.id, agentName: snapshot.displayName, glyph: snapshot.glyph, reported: reported,
                                   name: reported.isEmpty ? nil : reported, monthly: usd, currency: "USD", source: usd == nil ? nil : .table))
                }
                continue
            }
            guard let plan = snapshot.plan, !plan.isEmpty else { continue }
            let known = price(providerID: snapshot.id, plan: plan)
            out.append(Row(id: snapshot.id, agentName: snapshot.displayName, glyph: snapshot.glyph, reported: plan,
                           name: known?.name ?? plan, monthly: typed ?? known?.usd, currency: "USD",
                           source: typed != nil ? .typed : (known != nil ? .table : nil)))
        }
        return out.sorted { ($0.monthly ?? -1) > ($1.monthly ?? -1) }
    }

    /// The share of a month a range is: a day, seven days, or the month.
    static func share(of range: DashboardModel.Range, now: Date = Date(), calendar: Calendar = .current) -> Double {
        let days = Double(calendar.range(of: .day, in: .month, for: now)?.count ?? 30)
        switch range {
        case .today: return 1 / days
        case .week: return 7 / days
        case .month: return 1
        }
    }

    /// The list price of an agent's plan, when the table knows it.
    static func price(providerID: String, plan: String) -> Price? {
        let agent = agent(of: providerID)
        return table[agent]?[key(plan, agent: agent)]
    }
}
