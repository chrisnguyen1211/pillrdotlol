import Foundation
import os

// MARK: - What a key's answer says

/// Over what stretch of time a spend or a count was added up.
enum APIPeriod: Equatable, Sendable {
    /// The calendar month so far, in UTC — what pillr asks for when the
    /// endpoint wants a range.
    case month
    /// Whatever cycle the provider bills on, when it chooses the range itself.
    case billingPeriod
    /// Everything since the key or the account began.
    case total
    /// The thirty days to now, where that is the window a provider keeps.
    case last30Days
}

/// What a number is a number of.
enum APIUnit: Equatable, Sendable {
    /// An ISO currency code. Nil means the region's own — Kimi and SiliconFlow
    /// never say, and the host is the only answer.
    case money(String?)
    case credits, characters, searches, tokens, points, minutes, requests, emails, neurons, computeHours
    /// A unit with a name of its own and no translation — Venice's DIEM.
    case named(String)
}

/// Why a key that works has no number to show.
enum APIKeyNote: Equatable, Sendable {
    /// The provider has no usage API at all.
    case noUsageAPI
    /// The key was accepted and the account has nothing left to spend.
    case outOfCredits
    /// The key was accepted, and the answer did not carry the usage pillr
    /// knows how to read. Only for endpoints marked best-effort.
    case usageUnreadable
    /// Checking costs a billed request, so the key is not re-checked on a
    /// schedule — only when somebody asks.
    case keptUnchecked
    /// Rate-limit headers that came back on a free call.
    case requestsLeft(remaining: Int, limit: Int?, today: Bool)
}

/// One reading of an API key, before it is drawn.
enum APIReading: Equatable, Sendable {
    /// Money or credits left, with nothing to compare it to.
    case balance(Double, APIUnit)
    /// Left and spent, so the ring can show the share gone.
    case balanceSpent(remaining: Double, spent: Double, APIUnit)
    case spend(Double, APIUnit, APIPeriod)
    case used(Double, of: Double, APIUnit, resetsAt: Date?)
    case left(Double, of: Double?, APIUnit, resetsAt: Date?)
    /// Usage counted up with no ceiling — browser minutes, emails sent.
    case count(Double, APIUnit, APIPeriod)
    /// No number: the key works, and this is why there is nothing more.
    case keyWorks(APIKeyNote)
    /// More than one figure from the same answer — what is left, this
    /// month's spend, the spend in total — the first one leading.
    case several([APIReading])

    /// The figures one by one, in the order they are shown.
    var parts: [APIReading] {
        if case .several(let list) = self { return list.flatMap(\.parts) }
        return [self]
    }

    /// One reading from several: one alone is itself, and money or credits
    /// left always lead, since that is what runs out.
    static func combine(_ list: [APIReading]) -> APIReading? {
        let flat = list.flatMap(\.parts)
        let leading = flat.filter(\.isLeft) + flat.filter { !$0.isLeft }
        switch leading.count {
        case 0: return nil
        case 1: return leading[0]
        default: return .several(leading)
        }
    }

    var isKeyOnly: Bool {
        if case .keyWorks = self { return true }
        return false
    }

    private var isLeft: Bool {
        switch self {
        case .balance, .balanceSpent, .left: return true
        default: return false
        }
    }
}

/// The ways a parse refuses an answer. Each one rejects the key with a
/// reason rather than drawing a number nobody sent.
enum APIParseError: Error, Equatable {
    /// Not the shape this endpoint is documented to return.
    case unrecognised
    /// The answer says, in so many words, that the key is no good.
    case refused
    /// The provider's own words about what went wrong.
    case vendor(String)
}

// MARK: - Reading JSON by path

/// A dotted path into decoded JSON: `data.balance_infos[0].total_balance`,
/// `data[*].results[*].amount.value`, `[0].id` for an array at the root.
/// `[*]` fans out over an array, which is how sums are written.
enum JSONPath {
    private enum Step { case key(String), index(Int), all }

    private static func steps(_ path: String) -> [Step]? {
        var steps: [Step] = []
        var key = ""
        let chars = Array(path)
        var i = 0
        func flush() {
            if !key.isEmpty { steps.append(.key(key)); key = "" }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "." { flush(); i += 1; continue }
            if c == "[" {
                flush()
                guard let close = chars[i...].firstIndex(of: "]") else { return nil }
                let inside = String(chars[(i + 1)..<close])
                if inside == "*" { steps.append(.all) }
                else if let n = Int(inside), n >= 0 { steps.append(.index(n)) }
                else { return nil }
                i = close + 1
                continue
            }
            key.append(c)
            i += 1
        }
        flush()
        return steps
    }

    /// Everything the path reaches, in order. A path without `[*]` reaches
    /// at most one thing.
    static func values(_ root: Any?, _ path: String) -> [Any] {
        guard let root, let steps = steps(path) else { return [] }
        var current: [Any] = [root]
        for step in steps {
            var next: [Any] = []
            for value in current {
                switch step {
                case .key(let name):
                    if let dict = value as? [String: Any], let found = dict[name], !(found is NSNull) {
                        next.append(found)
                    }
                case .index(let n):
                    if let array = value as? [Any], n < array.count, !(array[n] is NSNull) {
                        next.append(array[n])
                    }
                case .all:
                    if let array = value as? [Any] { next.append(contentsOf: array.filter { !($0 is NSNull) }) }
                }
            }
            current = next
        }
        return current
    }

    static func value(_ root: Any?, _ path: String) -> Any? { values(root, path).first }

    /// A finite number, from a JSON number or a string holding one — DeepSeek,
    /// SiliconFlow and NanoGPT send their amounts as strings. A Boolean is
    /// never a number, whatever `NSNumber` would make of it.
    static func number(_ any: Any?) -> Double? {
        if let number = any as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        if let text = any as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed), value.isFinite else { return nil }
            return value
        }
        return nil
    }

    static func number(_ root: Any?, _ path: String) -> Double? { number(value(root, path)) }

    /// Every number the path reaches, or nil when it reaches nothing or
    /// anything that is not a number: a sum with a hole in it is not a sum.
    static func numbers(_ root: Any?, _ path: String) -> [Double]? {
        let found = values(root, path)
        guard !found.isEmpty else { return nil }
        var result: [Double] = []
        for item in found {
            guard let value = number(item) else { return nil }
            result.append(value)
        }
        return result
    }

    /// A text value, or a number written out — ids arrive as either.
    static func string(_ root: Any?, _ path: String) -> String? {
        let found = value(root, path)
        if let text = found as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = found as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
        return nil
    }

    static func bool(_ root: Any?, _ path: String) -> Bool? {
        guard let number = value(root, path) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// An ISO-8601 date with or without fractions, or Unix seconds.
    static func date(_ root: Any?, _ path: String) -> Date? {
        let found = value(root, path)
        if let seconds = number(found as? NSNumber), seconds > 0 {
            // Milliseconds past the year 33658 are not seconds.
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        guard let text = found as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - Writing a reading out

/// Amounts the way the console writes them: "$12.40", "1,200 credits" —
/// grouped the same whatever the Mac's region, like `ApifyUsage.money`.
enum APIAmount {
    private static func grouped(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func symbol(_ code: String) -> String? {
        switch code.uppercased() {
        case "USD": return "$"
        case "CNY", "RMB": return "¥"
        case "EUR": return "€"
        case "GBP": return "£"
        default: return nil
        }
    }

    private static func money(_ value: Double, code: String, decimals: Int = 2) -> String {
        let sign = value < 0 ? "-" : ""
        let body = grouped(abs(value), decimals: decimals)
        if let symbol = symbol(code) { return sign + symbol + body }
        return sign + body + " " + code.uppercased()
    }

    /// A count with no unit, for "3,200 of 10,000 credits used". Whole
    /// numbers stay whole; a fraction keeps a decimal or two.
    static func number(_ value: Double, _ unit: APIUnit, currency: String? = nil) -> String {
        if case .money(let code) = unit { return money(value, code: code ?? currency ?? "USD") }
        if value.rounded() == value || abs(value) >= 100 { return grouped(value.rounded(), decimals: 0) }
        return grouped(value, decimals: abs(value) < 10 ? 2 : 1)
    }

    /// The amount with its unit named: "$12.40", "1,200 credits".
    static func full(_ value: Double, _ unit: APIUnit, currency: String? = nil) -> String {
        let n = number(value, unit, currency: currency)
        switch unit {
        case .money:        return n
        case .credits:      return L10n.t("\(n) credits")
        case .characters:   return L10n.t("\(n) characters")
        case .searches:     return L10n.t("\(n) searches")
        case .tokens:       return L10n.t("\(n) tokens")
        case .points:       return L10n.t("\(n) points")
        case .minutes:      return L10n.t("\(n) browser minutes")
        case .requests:     return L10n.t("\(n) requests")
        case .emails:       return L10n.t("\(n) emails")
        case .neurons:      return L10n.t("\(n) neurons")
        case .computeHours: return L10n.t("\(n) compute hours")
        case .named(let name): return "\(n) \(name)"
        }
    }

    /// Short enough to sit under a 44 pt ring: "$12.40", "$1.2K", "3.4M".
    static func short(_ value: Double, _ unit: APIUnit, currency: String? = nil) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "-" : ""
        func compact(_ v: Double) -> String {
            if v >= 1_000_000 { return String(format: "%.1fM", locale: Locale(identifier: "en_US_POSIX"), v / 1_000_000) }
            return String(format: "%.1fK", locale: Locale(identifier: "en_US_POSIX"), v / 1_000)
        }
        if case .money(let code) = unit {
            let code = code ?? currency ?? "USD"
            let prefix = symbol(code) ?? ""
            let suffix = symbol(code) == nil ? " " + code.uppercased() : ""
            if magnitude >= 1_000 { return sign + prefix + compact(magnitude) + suffix }
            return money(value, code: code, decimals: magnitude >= 100 ? 0 : 2)
        }
        if magnitude >= 10_000 { return sign + compact(magnitude) }
        return number(value, unit)
    }
}

extension APIReading {
    /// The window this reading is drawn as. One window, always the headline.
    func window(providerName: String, currency: String?) -> LimitWindow {
        func full(_ v: Double, _ u: APIUnit) -> String { APIAmount.full(v, u, currency: currency) }
        func short(_ v: Double, _ u: APIUnit) -> String { APIAmount.short(v, u, currency: currency) }
        func number(_ v: Double, _ u: APIUnit) -> String { APIAmount.number(v, u, currency: currency) }

        switch self {
        case .balance(let left, let unit):
            return LimitWindow(id: "balance", label: L10n.t("Balance"),
                               usedText: short(left, unit), detail: L10n.t("\(full(left, unit)) left"),
                               prefersUsedText: true)
        case .balanceSpent(let left, let spent, let unit):
            let funded = left + spent
            var money: UsageMoneyBreakdown?
            if case .money(let code) = unit, left >= 0, spent >= 0 {
                money = UsageMoneyBreakdown(currency: code ?? currency ?? "USD", spent: spent, remaining: left)
            }
            return LimitWindow(id: "balance", label: L10n.t("Balance"),
                               usedFraction: funded > 0 ? min(max(spent / funded, 0), 1) : nil,
                               usedText: short(left, unit),
                               detail: L10n.t("\(full(left, unit)) left · \(full(spent, unit)) spent"),
                               money: money, prefersUsedText: true)
        case .spend(let amount, let unit, let period):
            let (id, label, detail): (String, String, String) = switch period {
            case .month:
                ("spend", L10n.t("Spend this month"), L10n.t("\(full(amount, unit)) spent this month"))
            case .billingPeriod:
                ("spend", L10n.t("Spend this billing period"), L10n.t("\(full(amount, unit)) spent this billing period"))
            case .total:
                ("spend-total", L10n.t("Spend in total"), L10n.t("\(full(amount, unit)) spent in total"))
            case .last30Days:
                ("spend-30d", L10n.t("Spend, last 30 days"), L10n.t("\(full(amount, unit)) spent in the last 30 days"))
            }
            return LimitWindow(id: id, label: label, usedText: short(amount, unit), detail: detail,
                               prefersUsedText: true)
        case .used(let used, let limit, let unit, let resetsAt):
            return LimitWindow(id: "usage", label: L10n.t("Usage"),
                               usedFraction: limit > 0 ? max(used, 0) / limit : nil,
                               usedText: short(used, unit),
                               detail: L10n.t("\(number(used, unit)) of \(full(limit, unit)) used"),
                               resetsAt: resetsAt)
        case .left(let left, let limit, let unit, let resetsAt):
            if let limit, limit > 0 {
                return LimitWindow(id: "usage", label: L10n.t("Usage"),
                                   usedFraction: max(0, limit - left) / limit,
                                   usedText: short(left, unit),
                                   detail: L10n.t("\(number(left, unit)) of \(full(limit, unit)) left"),
                                   resetsAt: resetsAt)
            }
            return LimitWindow(id: "balance", label: L10n.t("Balance"),
                               usedText: short(left, unit), detail: L10n.t("\(full(left, unit)) left"),
                               resetsAt: resetsAt, prefersUsedText: true)
        case .count(let count, let unit, let period):
            let detail = switch period {
            case .month: L10n.t("\(full(count, unit)) this month")
            case .billingPeriod: L10n.t("\(full(count, unit)) this billing period")
            case .total: L10n.t("\(full(count, unit)) in total")
            case .last30Days: L10n.t("\(full(count, unit)) in the last 30 days")
            }
            return LimitWindow(id: period == .total ? "usage-total" : "usage", label: L10n.t("Usage"),
                               usedText: short(count, unit), detail: detail, prefersUsedText: true)
        case .keyWorks(let note):
            return LimitWindow(id: "key", label: L10n.t("Key"), detail: note.text(providerName: providerName))
        case .several(let list):
            return list.first?.window(providerName: providerName, currency: currency)
                ?? APIReading.keyWorks(.usageUnreadable).window(providerName: providerName, currency: currency)
        }
    }

    /// A window per figure, each with an id of its own.
    func windows(providerName: String, currency: String?) -> [LimitWindow] {
        var seen: Set<String> = []
        return parts.map { part in
            let window = part.window(providerName: providerName, currency: currency)
            var id = window.id
            var n = 2
            while seen.contains(id) { id = "\(window.id)-\(n)"; n += 1 }
            seen.insert(id)
            return id == window.id ? window : window.withID(id)
        }
    }
}

extension APIKeyNote {
    func text(providerName name: String) -> String {
        switch self {
        case .noUsageAPI:
            return L10n.t("Key works · \(name) doesn't share usage through its API")
        case .outOfCredits:
            return L10n.t("Key works · out of credits")
        case .usageUnreadable:
            return L10n.t("Key works · pillr couldn't read the usage in \(name)'s answer")
        case .keptUnchecked:
            return L10n.t("Key kept · each check is billed, so pillr checks only when you ask")
        case .requestsLeft(let remaining, let limit?, true):
            let left = APIAmount.number(Double(remaining), .requests)
            let of = APIAmount.number(Double(limit), .requests)
            return L10n.t("Key works · \(left) of \(of) requests left today")
        case .requestsLeft(let remaining, _, _):
            return L10n.t("Key works · \(APIAmount.number(Double(remaining), .requests)) requests left right now")
        }
    }
}

// MARK: - The provider

/// The last reading, behind a lock so `forgetCachedCredential` — which is
/// not isolated to the actor — can drop it.
private final class HeldReading: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ProviderSnapshot?
    private var at: Date?
    private var forced = false

    func reusable(now: Date, maxAge: TimeInterval) -> ProviderSnapshot? {
        lock.withLock {
            guard !forced, let snapshot, let at, now.timeIntervalSince(at) < maxAge else { return nil }
            return snapshot
        }
    }

    var isForced: Bool { lock.withLock { forced } }
    var hasReading: Bool { lock.withLock { snapshot != nil } }

    func keep(_ snapshot: ProviderSnapshot, at date: Date) {
        lock.withLock { self.snapshot = snapshot; self.at = date; forced = false }
    }

    func force() {
        lock.withLock { snapshot = nil; at = nil; forced = true }
    }
}

/// One API key from `APICatalog`, read as a ring of its own — or, for a
/// provider with no usage API, checked and shown in Settings with no ring.
///
/// Everything provider-specific is data on the entry: where to ask, how to
/// sign the request, how to read the answer. This is the part every entry
/// shares, and it is deliberately strict. HTTPS only, eight seconds a
/// request, no redirects, no cookies, and the key never in a log line — some
/// providers take it in the query string, so a URL is not logged either.
///
/// It also decides how often to ask. The store polls every minute while an
/// agent is busy; a balance does not move that fast, so a reading is reused
/// for five minutes, a key check for six hours, and a check the provider
/// bills for is never repeated on its own.
actor CatalogKeyProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph: ProviderGlyph
    nonisolated let entry: APICatalogEntry
    nonisolated let region: APIRegion?
    nonisolated private let fields: [String: String]
    nonisolated private let recipe: APIRecipe
    private let session: URLSession
    nonisolated private let secret: @Sendable () -> String?
    private let now: @Sendable () -> Date
    nonisolated private let held = HeldReading()
    private var retryNoEarlierThan: Date?
    /// A balance endpoint has nothing to gain from a 302, and following one
    /// re-sends the key to wherever it points — see `NoRedirects`.
    private let noRedirects = NoRedirects()

    static let requestTimeout: TimeInterval = 8

    init?(extra: ExtraKey, session: URLSession = .shared,
          secret: @escaping @Sendable () -> String?,
          now: @escaping @Sendable () -> Date = { Date() }) {
        guard let entry = APICatalog.entry(id: extra.base), case .catalog(let recipe) = entry.route
        else { return nil }
        self.id = extra.id
        self.displayName = extra.displayName
        self.glyph = entry.glyph
        self.entry = entry
        self.recipe = recipe
        self.region = entry.region(extra.region)
        self.fields = extra.fields ?? [:]
        self.session = session
        self.secret = secret
        self.now = now
    }

    nonisolated var signInRoute: SignInRoute { .guidance(ExtraKey.signInGuidance) }

    nonisolated func account() -> ProviderAccount? {
        guard secret() != nil else { return nil }
        return ProviderAccount(label: nil, plan: nil, source: "pillr", manageURL: entry.consoleURL)
    }

    /// The key is pillr's own, and Settings' Remove deletes it.
    nonisolated func signOut() async {}
    nonisolated func presentSignIn() {}

    /// "Check now": drop the held reading so the next fetch asks the
    /// provider, billed check or not.
    nonisolated func forgetCachedCredential() { held.force() }

    /// How long a reading answers for.
    private func maxAge(_ freshness: UsageFreshness) -> TimeInterval {
        switch freshness {
        case .fromSource: return 0
        case .live: return 60
        case .standard:
            if entry.billedCheck { return .infinity }
            return entry.readability == .keyCheck ? 6 * 3600 : 5 * 60
        }
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        try await fetchSnapshot(freshness: .standard)
    }

    func fetchSnapshot(freshness: UsageFreshness) async throws -> ProviderSnapshot {
        let date = now()
        if let reusable = held.reusable(now: date, maxAge: maxAge(freshness)) { return reusable }
        guard let key = secret()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw UsageProviderError.needsAuth
        }
        // Never spend somebody's money on a schedule: a billed check is made
        // when the key is added and whenever somebody asks, and otherwise
        // the key is shown as kept.
        if entry.billedCheck, freshness == .standard, !held.isForced, !held.hasReading {
            return snapshot(for: .keyWorks(.keptUnchecked))
        }
        if let prefix = entry.requiredKeyPrefix, !key.hasPrefix(prefix) {
            throw UsageProviderError.apiError(
                L10n.t("\(entry.name) needs an admin key here — one that starts with \(prefix)"))
        }
        if let retryNoEarlierThan, retryNoEarlierThan > date {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(date))
        }

        var variables = fields
        for step in recipe.prefetch {
            if let given = variables[step.variable], !given.isEmpty { continue }
            let context = APIContext(entry: entry, region: region, variables: variables, now: date)
            let answer: APIResponse
            do {
                answer = try await send(step.request, key: key, context: context)
            } catch UsageProviderError.needsAuth where step.refusalMeansMissing {
                throw UsageProviderError.apiError(step.missing())
            } catch UsageProviderError.apiError where step.refusalMeansMissing {
                throw UsageProviderError.apiError(step.missing())
            } catch UsageProviderError.badResponse where step.refusalMeansMissing {
                throw UsageProviderError.apiError(step.missing())
            }
            guard let found = JSONPath.string(answer.json, step.path) else {
                throw UsageProviderError.apiError(step.missing())
            }
            variables[step.variable] = found
        }

        let context = APIContext(entry: entry, region: region, variables: variables, now: date)
        let answer = try await send(recipe.request, key: key, context: context)
        let reading: APIReading
        if answer.status == 402 {
            // Payment required is the key being accepted by an account with
            // nothing left in it — a fact about the account, not the key.
            reading = .keyWorks(.outOfCredits)
        } else {
            do {
                reading = try recipe.parse.read(answer)
            } catch APIParseError.refused {
                throw UsageProviderError.needsAuth
            } catch APIParseError.vendor(let message) {
                throw UsageProviderError.apiError(message)
            } catch {
                // The shape only — names and kinds, never a value — so a
                // provider that changed its answer can be fixed from the log.
                Log.usage.notice("\(self.entry.id, privacy: .public): answer not recognised: \(JSONShape.describe(answer.json), privacy: .public)")
                if let message = JSONShape.vendorMessage(answer.json) {
                    // A provider that says why in its own words is better
                    // heard than paraphrased.
                    throw UsageProviderError.apiError("\(entry.name): \(message)")
                }
                if entry.bestEffortUsage {
                    reading = .keyWorks(.usageUnreadable)
                } else {
                    throw UsageProviderError.apiError(
                        L10n.t("\(entry.name) answered in a way pillr doesn't recognise"))
                }
            }
        }
        retryNoEarlierThan = nil
        var combined = reading
        if !recipe.extras.isEmpty, !reading.isKeyOnly {
            combined = APIReading.combine([reading] + (await extraReadings(key: key, context: context))) ?? reading
        }
        let fresh = snapshot(for: combined)
        held.keep(fresh, at: date)
        return fresh
    }

    private func snapshot(for reading: APIReading) -> ProviderSnapshot {
        let windows = reading.windows(providerName: entry.name, currency: region?.currency)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: windows.first?.id)
    }

    /// The figures a second request adds — OpenRouter's credits beside a
    /// key's spend. A refusal or an odd answer there costs nothing: the main
    /// reading already proved the key.
    private func extraReadings(key: String, context: APIContext) async -> [APIReading] {
        var found: [APIReading] = []
        for extra in recipe.extras {
            guard let answer = try? await send(extra.request, key: key, context: context),
                  (200..<300).contains(answer.status),
                  let reading = try? extra.parse.read(answer) else { continue }
            found.append(reading)
        }
        return found
    }

    /// One request, signed for this provider, with every failure turned into
    /// a status the store already knows how to show.
    private func send(_ spec: APIRequest, key: String, context: APIContext) async throws -> APIResponse {
        let request: URLRequest
        do {
            request = try recipe.makeRequest(spec, key: key, context: context)
        } catch {
            throw UsageProviderError.apiError(L10n.t("pillr only sends keys over HTTPS"))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: noRedirects)
        } catch let error as URLError where error.code == .timedOut {
            throw UsageProviderError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageProviderError.apiError(L10n.t("Couldn't reach \(entry.name). Check your connection."))
        }

        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // The id and the code only: the URL can carry the key.
        Log.usage.debug("\(self.entry.id, privacy: .public): HTTP \(status)")
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] {
            if let name = name as? String { headers[name.lowercased()] = "\(value)" }
        }

        switch status {
        case 200..<300, 402:
            break
        case 400:
            // Google and a few others answer a bad key with a 400 and say so.
            let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let message = JSONShape.vendorMessage(json) {
                let lowered = message.lowercased()
                if ["api key", "api_key", "apikey", "token", "unauthor", "credential", "authenticat"]
                    .contains(where: lowered.contains) {
                    throw UsageProviderError.needsAuth
                }
                throw UsageProviderError.apiError("\(entry.name): \(message)")
            }
            throw UsageProviderError.badResponse(status: status)
        case _ where recipe.acceptedStatuses.contains(status):
            break
        case 401:
            if entry.readability == .adminKey {
                throw UsageProviderError.apiError(adminRefusal)
            }
            throw UsageProviderError.needsAuth
        case 403 where entry.forbidden != nil:
            throw UsageProviderError.apiError(entry.forbidden!())
        case 404 where entry.notFound != nil:
            throw UsageProviderError.apiError(entry.notFound!())
        case 403:
            switch entry.readability {
            case .adminKey: throw UsageProviderError.apiError(adminRefusal)
            case .keyCheck: throw UsageProviderError.needsAuth
            case .usage:
                throw UsageProviderError.apiError(
                    L10n.t("\(entry.name) won't share usage with this key — try one with full account access"))
            }
        case 429:
            let delay = max(60, headers["retry-after"].flatMap(Double.init) ?? 60)
            retryNoEarlierThan = context.now.addingTimeInterval(delay)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        default:
            throw UsageProviderError.badResponse(status: status)
        }

        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return APIResponse(json: json, headers: headers, status: status, context: context)
    }

    /// What a refused key says when the provider wanted an admin key.
    private var adminRefusal: String {
        L10n.t("\(entry.name) refused this key. Reading usage needs \(entry.keyKind.shortName).")
    }
}

/// What an answer looks like without what it says: field names and the kind
/// of each value, for the log.
enum JSONShape {
    static func describe(_ json: Any?, depth: Int = 0) -> String {
        let text = shape(json, depth: depth)
        return text.count > 800 ? String(text.prefix(800)) + "…" : text
    }

    private static func shape(_ json: Any?, depth: Int) -> String {
        guard let json else { return "nil" }
        if depth > 5 { return "…" }
        if let dict = json as? [String: Any] {
            let fields = dict.keys.sorted().prefix(25).map { "\($0):\(shape(dict[$0], depth: depth + 1))" }
            return "{" + fields.joined(separator: ",") + (dict.count > 25 ? ",…" : "") + "}"
        }
        if let array = json as? [Any] {
            return "[" + (array.first.map { shape($0, depth: depth + 1) } ?? "") + (array.count > 1 ? ",…\(array.count)" : "") + "]"
        }
        if let number = json as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "num"
        }
        if json is String { return "str" }
        if json is NSNull { return "null" }
        return "?"
    }

    /// The reason a provider gave, where the usual envelopes put one.
    static func vendorMessage(_ json: Any?) -> String? {
        for path in ["errors[0].message", "error.message", "error_description", "error", "detail", "message", "msg"] {
            if let text = JSONPath.value(json, path) as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 240 { return trimmed }
            }
        }
        return nil
    }
}

extension LimitWindow {
    /// The same window under another id, for a key with two of a kind.
    func withID(_ id: String) -> LimitWindow {
        LimitWindow(id: id, group: group, label: label, usedFraction: usedFraction, remaining: remaining,
                    used: used, usedText: usedText, detail: detail, money: money, resetsAt: resetsAt,
                    duration: duration, bandOverride: bandOverride, prefersUsedText: prefersUsedText)
    }
}
