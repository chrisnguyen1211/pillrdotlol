// Ported from Codenotch (MIT).
import Foundation
import Combine

/// USD per million tokens for a model family (matched by prefix, longest wins).
struct ModelPrice: Codable, Identifiable, Equatable, Sendable {
    var id: String { model }
    var model: String
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
}

/// Where the cost layer keeps its files: accounts, prices, plans and one
/// database per login.
enum CostPaths {
    static var directory: URL {
        if Runtime.isUnderTest {
            return FileManager.default.temporaryDirectory.appendingPathComponent("spyx-costs-tests", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spyx/costs", isDirectory: true)
    }
}

/// Editable price list and exchange rate. Costs are estimates: the CLIs bill
/// through a subscription, this is what the same tokens would cost on the API.
///
/// spyx only talks to the agents' own servers and GitHub, so the daily
/// market-data refresh (OpenRouter's price list, open.er-api.com's exchange
/// rate) is opt-in: off, the bundled prices are used and amounts can only be
/// converted when the Mac's currency is the US dollar.
@MainActor
final class PriceTable: ObservableObject {
    static let shared = PriceTable()

    @Published var prices: [ModelPrice] { didSet { save() } }
    @Published var rate: Double { didSet { save() } }          // 1 USD = `rate` in the Mac's currency; 0 = not known yet
    var rateKnown: Bool { rate > 0 }
    @Published var pricesUpdatedAt: Date? { didSet { save() } }
    @Published var rateUpdatedAt: Date? { didSet { save() } }
    @Published var lastError: String?

    /// Whether the daily refresh may reach OpenRouter and open.er-api.com.
    /// Off by default: neither host is an agent's own server.
    static let marketDataKey = "costsMarketData"
    @Published var marketDataEnabled: Bool {
        didSet {
            UserDefaults.standard.set(marketDataEnabled, forKey: Self.marketDataKey)
            if marketDataEnabled { refreshIfDue() }
        }
    }

    /// The Mac's own currency (System Settings → Language & Region).
    var currency: String { Locale.current.currency?.identifier ?? "USD" }

    static var fileURL: URL { CostPaths.directory.appendingPathComponent("prices.json") }

    /// Fallback prices (USD per million tokens), used until the first market
    /// refresh succeeds — and for good when the refresh is off.
    static let defaults: [ModelPrice] = [
        ModelPrice(model: "claude-fable-5", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        ModelPrice(model: "claude-opus-5", input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25),
        ModelPrice(model: "claude-sonnet-5", input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5),
        ModelPrice(model: "claude-haiku-4", input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25),
        ModelPrice(model: "gpt-6", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5),
        ModelPrice(model: "gpt-5", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25),
    ]

    private var loading = true
    private init() {
        prices = Self.defaults
        rate = 0                                   // unknown until fetched (USD needs none)
        marketDataEnabled = UserDefaults.standard.bool(forKey: Self.marketDataKey)
        if Locale.current.currency?.identifier == "USD" { rate = 1 }
        if let data = try? Data(contentsOf: Self.fileURL),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let list = root["prices"] as? [[String: Any]] {
                let decoded = list.compactMap { d -> ModelPrice? in
                    guard let m = d["model"] as? String else { return nil }
                    return ModelPrice(model: m, input: d["input"] as? Double ?? 0, output: d["output"] as? Double ?? 0,
                                      cacheRead: d["cacheRead"] as? Double ?? 0, cacheWrite: d["cacheWrite"] as? Double ?? 0)
                }
                if !decoded.isEmpty { prices = decoded }
            }
            if let r = root["rate"] as? Double, r > 0 { rate = r }
            if let t = root["pricesUpdatedAt"] as? Double { pricesUpdatedAt = Date(timeIntervalSince1970: t) }
            if let t = root["rateUpdatedAt"] as? Double { rateUpdatedAt = Date(timeIntervalSince1970: t) }
        }
        loading = false
        refreshIfDue()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIfDue() }
        }
    }

    // MARK: Daily refresh from public sources (no keys) — opt-in

    static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!
    static let fxURL = URL(string: "https://open.er-api.com/v6/latest/USD")!

    func refreshIfDue(force: Bool = false) {
        guard marketDataEnabled, !Runtime.isUnderTest else { return }
        let day: TimeInterval = 24 * 3600
        let needPrices = force || (pricesUpdatedAt.map { Date().timeIntervalSince($0) > day } ?? true)
        let needRate = force || (rateUpdatedAt.map { Date().timeIntervalSince($0) > day } ?? true)
        guard needPrices || needRate else { return }
        let currency = self.currency
        Task.detached(priority: .utility) {
            var newPrices: [ModelPrice]?
            var newRate: Double?
            var failure: String?
            if needPrices {
                do {
                    let (data, _) = try await URLSession.shared.data(from: Self.modelsURL)
                    newPrices = Self.parseOpenRouter(data)
                } catch {
                    failure = "OpenRouter: \(error.localizedDescription)"
                    Log.usage.error("costs: price list refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if needRate {
                if currency == "USD" { newRate = 1 } else {
                    do {
                        let (data, _) = try await URLSession.shared.data(from: Self.fxURL)
                        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                           let rates = root["rates"] as? [String: Any], let r = rates[currency] as? Double { newRate = r }
                    } catch {
                        failure = "FX: \(error.localizedDescription)"
                        Log.usage.error("costs: exchange rate refresh failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            let p = newPrices, r = newRate, e = failure
            await MainActor.run {
                if let p, !p.isEmpty { self.merge(p); self.pricesUpdatedAt = Date() }
                if let r { self.rate = r; self.rateUpdatedAt = Date() }
                self.lastError = e
            }
        }
    }

    /// OpenRouter lists prices per token; keep the vendor models we care about
    /// as USD per million, keyed the way the CLIs name them.
    nonisolated static func parseOpenRouter(_ data: Data) -> [ModelPrice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        var out: [ModelPrice] = []
        for m in list {
            guard let id = m["id"] as? String, !id.contains(":"),
                  id.hasPrefix("anthropic/") || id.hasPrefix("openai/"),
                  let pr = m["pricing"] as? [String: Any] else { continue }
            func num(_ k: String) -> Double { Double((pr[k] as? String) ?? "") ?? 0 }
            // "anthropic/claude-fable-5.1" → "claude-fable-5-1" (Claude Code's spelling)
            let name = id.split(separator: "/").last.map(String.init)!.replacingOccurrences(of: ".", with: "-")
            out.append(ModelPrice(model: name, input: num("prompt") * 1e6, output: num("completion") * 1e6,
                                  cacheRead: num("input_cache_read") * 1e6, cacheWrite: num("input_cache_write") * 1e6))
        }
        return out
    }

    private func merge(_ fetched: [ModelPrice]) {
        var byModel = Dictionary(uniqueKeysWithValues: prices.map { ($0.model, $0) })
        for p in fetched where p.input > 0 || p.output > 0 { byModel[p.model] = p }
        prices = byModel.values.sorted { $0.model < $1.model }
    }

    private func save() {
        guard !loading, !Runtime.isUnderTest else { return }
        var root: [String: Any] = [
            "rate": rate,
            "prices": prices.map { ["model": $0.model, "input": $0.input, "output": $0.output,
                                    "cacheRead": $0.cacheRead, "cacheWrite": $0.cacheWrite] },
        ]
        if let t = pricesUpdatedAt { root["pricesUpdatedAt"] = t.timeIntervalSince1970 }
        if let t = rateUpdatedAt { root["rateUpdatedAt"] = t.timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func price(for model: String) -> ModelPrice? {
        prices.filter { model.hasPrefix($0.model) }.max { $0.model.count < $1.model.count }
    }

    /// Cost in USD for one turn's tokens; nil when the model has no price.
    func usd(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(input) * p.input + Double(output) * p.output
                + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
    }

    /// A snapshot usable off the main thread.
    var pricer: Pricer { Pricer(prices: prices, rate: rate) }
}

struct Pricer: Sendable {
    let prices: [ModelPrice]
    let rate: Double
    func local(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        guard let p = prices.filter({ model.hasPrefix($0.model) }).max(by: { $0.model.count < $1.model.count }) else { return nil }
        guard rate > 0 else { return nil }
        let usd = (Double(input) * p.input + Double(output) * p.output
                   + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
        return usd * rate
    }
}

enum MoneyFormat {
    static func string(_ amount: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = amount < 10 ? 2 : 0
        f.locale = L10n.locale
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
    }
    /// "1.2M", "84k" — spyx's own compact token count.
    static func tokens(_ n: Int) -> String { TokenCount.compact(n) }
}


/// Turns token weights into money for one account, off the main thread.
///   subscription: monthly price × (weight of the work / weight of the whole
///                 month for that account)
///   api:          the price table, converted at the USD rate
struct CostEstimator: Sendable {
    static let weeksPerMonth = 365.25 / 12 / 7   // 4.35

    let billing: CostAccount.Billing
    let monthlyPrice: Double
    /// Credit-based seat: money per 1 % of the allowance (limit × price ÷ 100); nil otherwise.
    var creditPointValue: Double? = nil
    /// Weekly limit periods with, for each, how much of the allowance was used
    /// and the total token weight of the account's turns inside it.
    let periods: [(start: Int, end: Int, usedPct: Double, weight: Double)]
    var monthWeight: Double = 0
    let pricer: Pricer

    /// Money for one session: the week's spend (weekly price × share of the
    /// allowance used) split across that week's turns by token weight.
    func cost(at ts: Int, weight: Double, model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        switch billing {
        case .subscription:
            if let pointValue = creditPointValue {
                guard let p = periods.first(where: { ts >= $0.start && ts < $0.end }) ?? periods.last, p.weight > 0 else { return nil }
                return pointValue * p.usedPct * weight / p.weight
            }
            guard monthlyPrice > 0 else { return nil }
            if let p = periods.first(where: { ts >= $0.start && ts < $0.end }) ?? periods.last, p.weight > 0 {
                let weekSpend = monthlyPrice / Self.weeksPerMonth * p.usedPct / 100
                return weekSpend * weight / p.weight
            }
            // No limit periods (credit-based plan): spread the month's price over the month's tokens.
            guard monthWeight > 0 else { return nil }
            return monthlyPrice * weight / monthWeight
        case .api:
            return pricer.local(model: model, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }

    static func weight(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        Double(input) + Double(output) * CostStore.kOutput
            + Double(cacheRead) * CostStore.kCacheRead + Double(cacheWrite) * CostStore.kCacheWrite
    }

    static func monthStart() -> Int {
        let cal = Calendar.current
        return Int(cal.date(from: cal.dateComponents([.year, .month], from: Date()))!.timeIntervalSince1970)
    }
}


/// Subscription plans and their list prices, from a JSON catalog the user can
/// edit (Application Support/spyx/costs/plans.json, seeded on first run).
/// Nothing about plans lives in the code that reads them.
@MainActor
final class PlanCatalog: ObservableObject {
    static let shared = PlanCatalog()

    struct Plan { var name: String; var prices: [String: Double]; var creditUSD: Double? }
    @Published private(set) var plans: [String: Plan] = [:]
    @Published private(set) var updatedAt: Date?

    static var fileURL: URL { CostPaths.directory.appendingPathComponent("plans.json") }

    /// The catalog written on first run. Plans as the vendors report them
    /// (Claude: organization.rate_limit_tier; Codex: plan_type); prices per
    /// month, the Mac's currency used when listed, else USD at the rate.
    static let seed = """
    {
      "_comment": "credit_usd = money per credit for credit-based seats (Codex Business/Team); cost there = credits used × credit_usd. Subscription plans as the vendors report them (Claude: organization.rate_limit_tier; Codex: plan_type). Prices per month; the Mac's currency is used when listed, else USD converted at the rate. Edit this file to change a price.",
      "plans": {
        "default_claude_free":      { "name": "Free",     "prices": { "USD": 0 } },
        "default_claude_pro":       { "name": "Pro",      "prices": { "USD": 20 } },
        "default_claude_max_5x":    { "name": "Max 5x",   "prices": { "USD": 100, "BRL": 550 } },
        "default_claude_max_20x":   { "name": "Max 20x",  "prices": { "USD": 200 } },
        "default_claude_team":      { "name": "Team",     "prices": { "USD": 30 } },
        "default_claude_enterprise":{ "name": "Enterprise", "prices": {} },
        "free":       { "name": "Free",       "prices": { "USD": 0 } },
        "plus":       { "name": "Plus",       "prices": { "USD": 20 } },
        "pro":        { "name": "Pro",        "prices": { "USD": 200 } },
        "team":       { "name": "Team",       "prices": { "USD": 30 }, "credit_usd": 1 },
        "business":   { "name": "Business",   "prices": { "USD": 30 }, "credit_usd": 1 },
        "enterprise": { "name": "Enterprise", "prices": {}, "credit_usd": 1 },
        "edu":        { "name": "Edu",        "prices": {} }
      }
    }
    """

    private init() {
        if !Runtime.isUnderTest, !FileManager.default.fileExists(atPath: Self.fileURL.path) {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(Self.seed.utf8).write(to: Self.fileURL, options: .atomic)
        }
        load()
    }

    private func load() {
        guard !Runtime.isUnderTest, let data = try? Data(contentsOf: Self.fileURL) else {
            apply(Data(Self.seed.utf8))
            return
        }
        apply(data)
        updatedAt = (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path))?[.modificationDate] as? Date
    }

    /// Re-reads plans.json, for after it has been edited.
    func reload() { load() }

    private func apply(_ data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["plans"] as? [String: [String: Any]] else { return }
        var out: [String: Plan] = [:]
        for (tier, d) in list {
            let prices = (d["prices"] as? [String: Any])?.compactMapValues { ($0 as? Double) ?? ($0 as? Int).map(Double.init) } ?? [:]
            out[tier] = Plan(name: d["name"] as? String ?? tier, prices: prices,
                             creditUSD: (d["credit_usd"] as? Double) ?? (d["credit_usd"] as? Int).map(Double.init))
        }
        plans = out
    }

    func name(for tier: String) -> String {
        plans[tier]?.name ?? tier.replacingOccurrences(of: "default_claude_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Monthly list price in `currency` when the catalog has it, else the USD
    /// price converted at `rate` (nil when neither is possible).
    func monthly(for tier: String, currency: String, rate: Double) -> Double? {
        guard let plan = plans[tier] else { return nil }
        if let local = plan.prices[currency] { return local }
        if let usd = plan.prices["USD"], rate > 0 { return usd * rate }
        return nil
    }
    func usd(for tier: String) -> Double? { plans[tier]?.prices["USD"] }
    func creditUSD(for tier: String) -> Double? { plans[tier]?.creditUSD }
}
