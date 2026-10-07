import Foundation

// MARK: - How an entry is described

/// How much an ordinary key can tell. Shown in the picker beside the name, so
/// nobody pastes a key expecting a ring the provider will never fill.
enum APIKeyReadability: String, Sendable {
    /// A normal key reads a balance, a spend or a quota.
    case usage
    /// Usage is there, behind an admin, management or service key.
    case adminKey
    /// No usage API at all: the key is checked, and gets no ring.
    case keyCheck

    var badge: String {
        switch self {
        case .usage:    return L10n.t("Reads usage")
        case .adminKey: return L10n.t("Admin key")
        case .keyCheck: return L10n.t("Key check")
        }
    }

    /// Among equally good matches, the providers that fill a ring come first.
    var rank: Int {
        switch self {
        case .usage:    return 0
        case .adminKey: return 1
        case .keyCheck: return 2
        }
    }
}

/// The picker's groups, in the order it lists them.
enum APICategory: String, CaseIterable, Sendable {
    case routers, llm, asia, media, search, infra

    var title: String {
        switch self {
        case .routers: return L10n.t("AI routers & gateways")
        case .llm:     return L10n.t("LLM APIs")
        case .asia:    return L10n.t("China & Asia")
        case .media:   return L10n.t("Speech & media")
        case .search:  return L10n.t("Search & scraping")
        case .infra:   return L10n.t("Infra & data")
        }
    }
}

/// Which key the form asks for — said in so many words, because "API key"
/// means three different things at OpenAI alone.
enum APIKeyKind: Sendable, Equatable {
    case normal
    case admin(prefix: String?)
    case management
    case service
    case personalToken
    /// A Cloudflare API token, which comes with an account ID.
    case cloudflareToken
    /// An Upstash developer key, which comes with the account's email.
    case upstash

    var note: String {
        switch self {
        case .normal:             return L10n.t("Use an ordinary API key.")
        case .admin(let prefix?): return L10n.t("Needs an admin key (it starts with \(prefix)), not an ordinary API key.")
        case .admin(nil):         return L10n.t("Needs an admin key, not an ordinary API key.")
        case .management:         return L10n.t("Needs a management key, not an inference key.")
        case .service:            return L10n.t("Needs a service key, not an ordinary API key.")
        case .personalToken:      return L10n.t("Use a personal access token.")
        case .cloudflareToken:    return L10n.t("Use an API token with Account Analytics read access, and your account ID.")
        case .upstash:            return L10n.t("Use a Developer API key, and the email you sign in with.")
        }
    }

    /// For "Reading usage needs …".
    var shortName: String {
        switch self {
        case .admin:      return L10n.t("an admin key")
        case .management: return L10n.t("a management key")
        case .service:    return L10n.t("a service key")
        default:          return L10n.t("a key with full account access")
        }
    }
}

/// What the ring will show, for the form's note.
enum APIMeasure: Sendable, Equatable {
    case balance, spend, planUsed, left, usageCount, plan, keyCheck
    /// What is left beside what has been spent, this month and in all.
    case balanceAndSpend

    func note(providerName name: String) -> String {
        switch self {
        case .balance:    return L10n.t("Shows the balance left.")
        case .balanceAndSpend: return L10n.t("Shows the credit left and what has been spent.")
        case .spend:      return L10n.t("Shows what this month has cost so far.")
        case .planUsed:   return L10n.t("Shows how much of your plan is used.")
        case .left:       return L10n.t("Shows what is left to use.")
        case .usageCount: return L10n.t("Shows usage this billing period.")
        case .plan:       return L10n.t("Shows your plan's usage limits.")
        case .keyCheck:   return L10n.t("\(name) doesn't share usage through its API, so pillr only checks that the key works. It gets no ring.")
        }
    }
}

/// One of a provider's consoles, where it has more than one and a key from
/// one is refused by the other.
struct APIRegion: Sendable {
    /// What is stored on the key: `global`, `china`, `international`.
    let id: String
    let title: @Sendable () -> String
    /// What `{base}` stands for in the entry's URLs.
    let base: String
    /// The currency the console bills in, when its answer does not say.
    let currency: String?
}

/// An extra input a provider needs besides the key — an account or project
/// id. Not secret: kept with the key's description, not in the keychain.
struct APIField: Sendable {
    /// Also the template variable it fills: `{account}`.
    let id: String
    let title: @Sendable () -> String
    let placeholder: String
    let required: Bool
}

/// How the key goes on the request.
enum APIAuth: Sendable {
    case bearer
    /// The key alone, under this header.
    case header(String)
    /// The key after a fixed word: `Token …`, `Key …`.
    case prefixed(String, prefix: String)
    /// In the query string. The URL then carries the key, which is why
    /// `CatalogKeyProvider` never logs one.
    case query(String)
    /// HTTP Basic, the email from this field and the key.
    case basic(emailField: String)
}

struct APIRequest: Sendable {
    var method = "GET"
    /// `https://…`, with `{base}`, a field's `{id}`, or a time such as
    /// `{monthStartUnix}` filled in at the moment of asking.
    var url: String
    /// A JSON body, filled the same way.
    var body: String? = nil
}

/// A request made first for a value the main one needs: Deepgram's project
/// id, xAI's team id. Skipped when the person typed the value themselves.
struct APIPrefetch: Sendable {
    let variable: String
    let request: APIRequest
    let path: String
    /// What to say when the answer does not have it.
    let missing: @Sendable () -> String
    /// The lookup is a courtesy rather than a test of the key: a refusal
    /// there says only that the value has to be typed in. xAI's management
    /// key is one an inference endpoint may not accept.
    var refusalMeansMissing = false
}

/// Everything a request template and a parse may look at.
struct APIContext: Sendable {
    let entry: APICatalogEntry
    let region: APIRegion?
    let variables: [String: String]
    let now: Date
}

struct APIResponse {
    let json: Any?
    /// Lowercased names.
    let headers: [String: String]
    let status: Int
    let context: APIContext
}

/// How an answer becomes a reading. Built from the shapes below where it
/// can be; a closure where a provider is odd.
struct APIParse: Sendable {
    let read: @Sendable (APIResponse) throws -> APIReading
}

struct APIRecipe: Sendable {
    var auth: APIAuth = .bearer
    var headers: [String: String] = [:]
    var prefetch: [APIPrefetch] = []
    var request: APIRequest
    var parse: APIParse
    /// Further asks whose figures join the reading, and whose failure does
    /// not count against the key.
    var extras: [APIExtra] = []
    /// Answers besides a 2xx that still prove the key: Pruna and Bria have
    /// nothing free to call, so a look-up of a job that does not exist is the
    /// check — a 404 there means the key got past the door, a 401 that it
    /// did not.
    var acceptedStatuses: Set<Int> = []
}

struct APIExtra: Sendable {
    let request: APIRequest
    let parse: APIParse
}

enum APIRoute: Sendable {
    /// One of the providers pillr had before the catalog — GLM, MiniMax's
    /// Coding Plan, Ollama Cloud, Apify — read by its own adapter.
    case existing
    case catalog(APIRecipe)
}

struct APICatalogEntry: Identifiable, Sendable {
    /// Lowercase letters and digits only: it is the middle of a provider id.
    let id: String
    let name: String
    let category: APICategory
    /// Other words someone might type for it: "kimi" finds Moonshot.
    var aliases: [String] = []
    let readability: APIKeyReadability
    var glyph: ProviderGlyph = .apiKey
    let consoleURL: URL
    /// The start of a key, for the field's placeholder. A hint, never a rule.
    var keyPrefix: String? = nil
    /// A rule: OpenAI and Anthropic admin keys look different from the keys
    /// people usually have, and sending the wrong one only earns a 401.
    var requiredKeyPrefix: String? = nil
    var regions: [APIRegion] = []
    var fields: [APIField] = []
    var keyKind: APIKeyKind = .normal
    let measure: APIMeasure
    /// Checking the key costs a billed request, so it is only done on asking.
    var billedCheck = false
    /// The usage half is documented loosely; a 200 without it still proves
    /// the key, and says the usage could not be read.
    var bestEffortUsage = false
    /// What a 403 or a 404 means at this provider, in its own terms — a
    /// key without billing access, a team that is not the key's — where the
    /// general words would only say "unexpected answer".
    var forbidden: (@Sendable () -> String)? = nil
    var notFound: (@Sendable () -> String)? = nil
    let route: APIRoute

    func region(_ id: String?) -> APIRegion? {
        regions.first { $0.id == id } ?? regions.first
    }

    /// The form's one-line note: which key, and what it will show.
    /// The note without the words about which key — for a provider whose
    /// key guide has said that already.
    var shownNote: String {
        var parts = [measure.note(providerName: name)]
        if billedCheck {
            parts.append(L10n.t("Each check sends one tiny request that \(name) bills, so pillr checks only when you ask."))
        }
        return parts.joined(separator: " ")
    }

    var note: String {
        var parts = [keyKind.note, measure.note(providerName: name)]
        if billedCheck {
            parts.append(L10n.t("Each check sends one tiny request that \(name) bills, so pillr checks only when you ask."))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Filling templates

enum APITemplate {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The first instant of this month, in UTC — what "this month" means to
    /// every billing API here.
    static func monthStart(_ now: Date) -> Date {
        utc.dateInterval(of: .month, for: now)?.start ?? now
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func fill(_ template: String, context: APIContext, json: Bool = false) -> String {
        let start = monthStart(context.now)
        let parts = utc.dateComponents([.year, .month], from: context.now)
        var values: [String: String] = [
            "base": context.region?.base ?? "",
            "monthStartUnix": String(Int(start.timeIntervalSince1970)),
            "monthStartISO": iso(start),
            "nowUnix": String(Int(context.now.timeIntervalSince1970)),
            "nowISO": iso(context.now),
            "year": String(parts.year ?? 1970),
            "month": String(parts.month ?? 1),
            // A fresh id per request, for Runware's tasks and the made-up
            // job ids Pruna and Bria are asked about.
            "uuid": UUID().uuidString.lowercased(),
        ]
        for (name, value) in context.variables {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if json {
                values[name] = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            } else {
                // A typed id must stay one path segment.
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "/?#;")
                values[name] = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            }
        }
        var result = template
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
    }
}

enum APIRequestError: Error { case insecure }

extension APIRecipe {
    /// The request, signed. Refuses anything that is not HTTPS to a real host.
    func makeRequest(_ spec: APIRequest, key: String, context: APIContext) throws -> URLRequest {
        let filled = APITemplate.fill(spec.url, context: context)
        guard var components = URLComponents(string: filled),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { throw APIRequestError.insecure }
        if case .query(let name) = auth {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: name, value: key)]
            // `URLQueryItem` leaves `+` alone, which a server reads as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw APIRequestError.insecure }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: CatalogKeyProvider.requestTimeout)
        request.httpMethod = spec.method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        switch auth {
        case .bearer:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .header(let name):
            request.setValue(key, forHTTPHeaderField: name)
        case .prefixed(let name, let prefix):
            request.setValue(prefix + key, forHTTPHeaderField: name)
        case .query:
            break
        case .basic(let field):
            let email = context.variables[field]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let token = Data("\(email):\(key)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = spec.body {
            request.httpBody = Data(APITemplate.fill(body, context: context, json: true).utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

// MARK: - The usual shapes of an answer

extension APIParse {
    /// A raw amount in the provider's own unit — cents, nano-dollars,
    /// ten-thousandths — brought to the one shown, to a millionth: binary
    /// fractions would otherwise turn 123456 × 0.0001 into 12.345600000000001.
    static func scaled(_ value: Double, _ scale: Double) -> Double {
        scale == 1 ? value : (value * scale * 1_000_000).rounded() / 1_000_000
    }

    /// Money or credits left at `path`, times `scale`; `negate` for a ledger
    /// that writes funds as a negative number.
    static func balance(_ path: String, _ unit: APIUnit, scale: Double = 1, negate: Bool = false) -> APIParse {
        APIParse { response in
            guard let raw = JSONPath.number(response.json, path) else { throw APIParseError.unrecognised }
            return .balance(scaled(negate ? -raw : raw, scale), unit)
        }
    }

    static func balanceSpent(left: String, spent: String, _ unit: APIUnit) -> APIParse {
        APIParse { response in
            guard let left = JSONPath.number(response.json, left),
                  let spent = JSONPath.number(response.json, spent), spent >= 0
            else { throw APIParseError.unrecognised }
            return .balanceSpent(remaining: left, spent: spent, unit)
        }
    }

    /// Every number `path` reaches, added up — a month of daily buckets.
    /// An empty month is a real zero, so an empty list is allowed when the
    /// list itself is there.
    static func spendSum(_ path: String, list: String, _ unit: APIUnit, scale: Double = 1,
                         period: APIPeriod = .month) -> APIParse {
        APIParse { response in
            guard JSONPath.value(response.json, list) is [Any] else { throw APIParseError.unrecognised }
            let found = JSONPath.values(response.json, path)
            var total = 0.0
            for item in found {
                guard let value = JSONPath.number(item), value >= 0 else { throw APIParseError.unrecognised }
                total += value
            }
            return .spend(scaled(total, scale), unit, period)
        }
    }

    static func spend(_ path: String, _ unit: APIUnit, scale: Double = 1, period: APIPeriod = .month) -> APIParse {
        APIParse { response in
            guard let value = JSONPath.number(response.json, path), value >= 0 else { throw APIParseError.unrecognised }
            return .spend(scaled(value, scale), unit, period)
        }
    }

    static func used(_ path: String, of limit: String, _ unit: APIUnit, resets: String? = nil) -> APIParse {
        APIParse { response in
            guard let used = JSONPath.number(response.json, path), used >= 0,
                  let limit = JSONPath.number(response.json, limit), limit >= 0
            else { throw APIParseError.unrecognised }
            let resetsAt = resets.flatMap { JSONPath.date(response.json, $0) }
            if limit == 0 { return .count(used, unit, .billingPeriod) }
            return .used(used, of: limit, unit, resetsAt: resetsAt)
        }
    }

    static func left(_ path: String, of limit: String? = nil, _ unit: APIUnit, resets: String? = nil) -> APIParse {
        APIParse { response in
            guard let left = JSONPath.number(response.json, path) else { throw APIParseError.unrecognised }
            let ceiling = limit.flatMap { JSONPath.number(response.json, $0) }
            let resetsAt = resets.flatMap { JSONPath.date(response.json, $0) }
            return .left(left, of: ceiling, unit, resetsAt: resetsAt)
        }
    }

    static func count(_ path: String, _ unit: APIUnit, scale: Double = 1,
                      period: APIPeriod = .billingPeriod) -> APIParse {
        APIParse { response in
            guard let value = JSONPath.number(response.json, path), value >= 0 else { throw APIParseError.unrecognised }
            return .count(scaled(value, scale), unit, period)
        }
    }

    /// Any 2xx proves the key, and there is nothing more to read.
    static let keyWorks = APIParse { _ in .keyWorks(.noUsageAPI) }

    /// Runware's answer is a list of task results, and the account's may
    /// not be the first — an authentication result can lead it — and its
    /// balance has been seen as a bare number as well as an object.
    static let runwareBalance = APIParse { response in
        let json = response.json
        let tasks = JSONPath.values(json, "data[*]").compactMap { $0 as? [String: Any] }
        let account = tasks.first { ($0["taskType"] as? String) == "accountManagement" }
            ?? tasks.first { $0["balance"] != nil }
            ?? (JSONPath.value(json, "data") as? [String: Any])
            ?? (json as? [String: Any])
        guard let account else { throw APIParseError.unrecognised }
        let currency = (JSONPath.string(account, "balance.currency") ?? "USD").uppercased()
        var figures: [APIReading] = []
        if let amount = JSONPath.number(account, "balance.amount") ?? JSONPath.number(account, "balance") {
            figures.append(.balance(amount, .money(currency)))
        }
        if let recent = JSONPath.number(account, "usage.last30Days.credits") {
            figures.append(.spend(recent, .money(currency), .last30Days))
        }
        if let total = JSONPath.number(account, "usage.total.credits") {
            figures.append(.spend(total, .money(currency), .total))
        }
        guard let reading = APIReading.combine(figures) else { throw APIParseError.unrecognised }
        return reading
    }

    /// A key check that also reads rate-limit headers when the answer has
    /// them. `today` when the header counts requests per day.
    static func keyWorks(remaining: String, limit: String?, today: Bool) -> APIParse {
        APIParse { response in
            guard let left = response.headers[remaining].flatMap({ Int($0.split(separator: ",").first ?? "") }),
                  left >= 0 else { return .keyWorks(.noUsageAPI) }
            let ceiling = limit.flatMap { response.headers[$0] }.flatMap { Int($0.split(separator: ",").first ?? "") }
            return .keyWorks(.requestsLeft(remaining: left, limit: ceiling, today: today && ceiling != nil))
        }
    }

    /// Kimi's envelope: HTTP 200 can still carry `code != 0` and a message.
    func requiringCodeZero() -> APIParse {
        let inner = self
        return APIParse { response in
            if let code = JSONPath.number(response.json, "code"), code != 0 {
                let message = JSONPath.string(response.json, "message")
                    ?? JSONPath.string(response.json, "msg") ?? "code \(Int(code))"
                throw APIParseError.vendor(message)
            }
            return try inner.read(response)
        }
    }
}

// MARK: - The catalog

enum APICatalog {
    private static func url(_ string: String) -> URL { URL(string: string)! }

    private static func r(_ url: String, method: String = "GET", body: String? = nil) -> APIRequest {
        APIRequest(method: method, url: url, body: body)
    }

    /// One tiny chat request, for the providers with nothing free to call.
    private static func chat(_ url: String, model: String) -> APIRequest {
        APIRequest(method: "POST", url: url,
                   body: #"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],"max_tokens":1}"#)
    }

    private static func regions(global: String, china: String,
                                globalCurrency: String? = nil, chinaCurrency: String? = nil,
                                globalID: String = "global") -> [APIRegion] {
        [APIRegion(id: globalID, title: { globalID == "global" ? L10n.t("Global") : L10n.t("International") },
                   base: global, currency: globalCurrency),
         APIRegion(id: "china", title: { L10n.t("China mainland") }, base: china, currency: chinaCurrency)]
    }

    private static func projectMissing(_ name: String) -> @Sendable () -> String {
        { L10n.t("Couldn't find a project on this \(name) account") }
    }

    // MARK: Odd ones

    /// OpenRouter's per-key endpoint. The monthly spend is read by the same
    /// parser a custom OpenRouter endpoint uses; a key with a credit limit
    /// shows what is left of it instead.
    /// A key's own figures: what is left of its limit if it has one, this
    /// month's spend and everything it has spent.
    private static let openRouterKey = APIParse { response in
        let root = response.json
        var figures: [APIReading] = []
        if let limit = JSONPath.number(root, "data.limit"), limit > 0,
           let left = JSONPath.number(root, "data.limit_remaining") {
            figures.append(.left(left, of: limit, .money("USD"), resetsAt: nil))
        }
        if let month = JSONPath.number(root, "data.usage_monthly") {
            figures.append(.spend(month, .money("USD"), .month))
        }
        if let total = JSONPath.number(root, "data.usage") {
            figures.append(.spend(total, .money("USD"), .total))
        }
        if let reading = APIReading.combine(figures) { return reading }
        guard let root, let data = try? JSONSerialization.data(withJSONObject: root),
              case .spendUSD(let spent, _)? = CustomEndpointPresetUsage.parsePreset(.openRouter, data: data)
        else { throw APIParseError.unrecognised }
        return .spend(spent, .money("USD"), .month)
    }

    /// The account's credits less everything used: what is left to spend.
    private static let openRouterCreditsLeft = APIParse { response in
        guard let bought = JSONPath.number(response.json, "data.total_credits"),
              let used = JSONPath.number(response.json, "data.total_usage")
        else { throw APIParseError.unrecognised }
        return .balance(bought - used, .money("USD"))
    }

    /// DeepSeek can hold several currencies; dollars first if there are any.
    private static let deepSeekBalance = APIParse { response in
        guard let infos = JSONPath.value(response.json, "balance_infos") as? [[String: Any]], !infos.isEmpty
        else { throw APIParseError.unrecognised }
        let chosen = infos.first { ($0["currency"] as? String)?.uppercased() == "USD" } ?? infos[0]
        guard let total = JSONPath.number(chosen["total_balance"]),
              let currency = chosen["currency"] as? String else { throw APIParseError.unrecognised }
        return .balance(total, .money(currency.uppercased()))
    }

    /// Venice: dollars when there are any, otherwise DIEM.
    private static let veniceBalance = APIParse { response in
        let usd = JSONPath.number(response.json, "data.balances.USD")
        let diem = JSONPath.number(response.json, "data.balances.DIEM")
        if let usd, usd > 0 || diem == nil { return .balance(usd, .money("USD")) }
        if let diem { return .balance(diem, .named("DIEM")) }
        throw APIParseError.unrecognised
    }

    /// DeepInfra writes funds as a negative `stripe_balance`; what is left is
    /// that, less what has been charged since the last invoice. The units
    /// are not stated — dollars, as every client of it reads them.
    private static let deepInfraBalance = APIParse { response in
        guard let stripe = JSONPath.number(response.json, "stripe_balance") else { throw APIParseError.unrecognised }
        let recent = JSONPath.number(response.json, "recent") ?? 0
        let left = APIReading.balance(-stripe - recent, .money("USD"))
        return recent > 0 ? .several([left, .spend(recent, .money("USD"), .billingPeriod)]) : left
    }

    /// xAI's prepaid ledger: `total.val` is cents with the sign inverted, so
    /// money in the account is negative. From CodexBar's notes, not xAI's docs.
    /// xAI's invoice preview, every amount in US cents and most as strings.
    /// Prepaid credits are written as a negative number, as the ledger
    /// writes money paid in; what is left is that less what has been used.
    /// The sign of `prepaidCreditsUsed` is not shown in the docs (it is 0
    /// there), so its size is taken either way.
    private static let xaiInvoice = APIParse { response in
        let root = response.json
        func dollars(_ path: String) -> Double? { JSONPath.number(root, path).map { $0 / 100 } }
        let prepaid = dollars("coreInvoice.prepaidCredits.val")
        let used = abs(dollars("coreInvoice.prepaidCreditsUsed.val") ?? 0)
        let spent = dollars("coreInvoice.amountAfterVat") ?? dollars("coreInvoice.totalWithCorr.val")
        let limit = dollars("effectiveSpendingLimit")
        var figures: [APIReading] = []
        if let prepaid, prepaid < 0 { figures.append(.balance(max(0, -prepaid - used), .money("USD"))) }
        if let spent {
            if let limit, limit > 0 {
                figures.append(.used(max(0, spent), of: limit, .money("USD"), resetsAt: nil))
            } else {
                figures.append(.spend(max(0, spent), .money("USD"), .month))
            }
        }
        guard let reading = APIReading.combine(figures) else { throw APIParseError.unrecognised }
        return reading
    }

    /// Deepgram's balances, added up — usually one, in dollars.
    private static let deepgramBalance = APIParse { response in
        guard let amounts = JSONPath.numbers(response.json, "balances[*].amount") else { throw APIParseError.unrecognised }
        let units = JSONPath.string(response.json, "balances[0].units")?.uppercased() ?? "USD"
        let unit: APIUnit = units.count == 3 && units.allSatisfy(\.isLetter) ? .money(units) : .named(units.lowercased())
        return .balance(amounts.reduce(0, +), unit)
    }

    /// Leonardo's paid and subscription tokens are one pool to the person.
    private static let leonardoBalance = APIParse { response in
        guard let paid = JSONPath.number(response.json, "user_details[0].apiPaidTokens"),
              let plan = JSONPath.number(response.json, "user_details[0].apiSubscriptionTokens")
        else { throw APIParseError.unrecognised }
        return .left(paid + plan, of: nil, .credits,
                     resetsAt: JSONPath.date(response.json, "user_details[0].apiPlanTokenRenewalDate"))
    }

    /// Ideogram's report nests line items in daily buckets, and the shape of
    /// the nesting is loose in the docs. Every object that carries a
    /// `cost_total` is counted once — its own children are not — so a total
    /// at either level is never added twice.
    private static let ideogramSpend = APIParse { response in
        guard let buckets = JSONPath.value(response.json, "buckets") as? [Any] else { throw APIParseError.unrecognised }
        var total = 0.0
        var currency: String?
        func walk(_ node: Any) throws {
            if let dict = node as? [String: Any] {
                if let cost = dict["cost_total"] {
                    guard let value = JSONPath.number(cost), value >= 0 else { throw APIParseError.unrecognised }
                    total += value
                    currency = currency ?? (dict["currency_code"] as? String)
                    return
                }
                for value in dict.values { try walk(value) }
            } else if let array = node as? [Any] {
                for value in array { try walk(value) }
            }
        }
        try walk(buckets)
        return .spend(total, .money((currency ?? "USD").uppercased()), .month)
    }

    /// Tavily: the plan's credits when there is a plan, else the key's own cap.
    private static let tavilyUsage = APIParse { response in
        let root = response.json
        var figures: [APIReading] = []
        if let used = JSONPath.number(root, "account.plan_usage"),
           let limit = JSONPath.number(root, "account.plan_limit"), limit > 0 {
            figures.append(.used(used, of: limit, .credits, resetsAt: nil))
        }
        // The key's own count only when there is no plan to read: two
        // "used of" lines side by side would read as one figure twice.
        if figures.isEmpty, let used = JSONPath.number(root, "key.usage") {
            if let limit = JSONPath.number(root, "key.limit"), limit > 0 {
                figures.append(.used(used, of: limit, .credits, resetsAt: nil))
            } else {
                figures.append(.count(used, .credits, .billingPeriod))
            }
        }
        guard let reading = APIReading.combine(figures) else { throw APIParseError.unrecognised }
        return reading
    }

    /// SerpApi: searches used of the month's plan; a credit pool with no
    /// monthly plan shows what is left of it.
    private static let serpApiUsage = APIParse { response in
        let root = response.json
        if let limit = JSONPath.number(root, "searches_per_month"), limit > 0,
           let used = JSONPath.number(root, "this_month_usage") {
            return .used(used, of: limit, .searches, resetsAt: nil)
        }
        if let left = JSONPath.number(root, "total_searches_left") {
            return .left(left, of: nil, .searches, resetsAt: nil)
        }
        throw APIParseError.unrecognised
    }

    /// Firecrawl: credits left against the plan; coupons can take it past.
    private static let firecrawlCredits = APIParse { response in
        guard let left = JSONPath.number(response.json, "data.remainingCredits") else { throw APIParseError.unrecognised }
        let plan = JSONPath.number(response.json, "data.planCredits")
        return .left(left, of: plan.flatMap { $0 > 0 && left <= $0 ? $0 : nil }, .credits,
                     resetsAt: JSONPath.date(response.json, "data.billingPeriodEnd"))
    }

    /// Cohere answers a check with `valid`, not with a status.
    private static let cohereCheck = APIParse { response in
        guard let valid = JSONPath.bool(response.json, "valid") else { throw APIParseError.unrecognised }
        guard valid else { throw APIParseError.refused }
        return .keyWorks(.noUsageAPI)
    }

    /// Cloudflare's token check: the token is there and active.
    private static let cloudflareNeurons = APIParse { response in
        if let errors = JSONPath.value(response.json, "errors") as? [Any], !errors.isEmpty {
            throw APIParseError.vendor(JSONPath.string(response.json, "errors[0].message")
                                       ?? L10n.t("Cloudflare refused the usage query"))
        }
        guard JSONPath.value(response.json, "data.viewer.accounts[0]") != nil else {
            throw APIParseError.vendor(L10n.t("Cloudflare doesn't know that account ID"))
        }
        let neurons = JSONPath.numbers(response.json,
            "data.viewer.accounts[0].aiInferenceAdaptiveGroups[*].sum.totalNeurons") ?? []
        return .count(neurons.reduce(0, +), .neurons, .month)
    }

    /// MiniMax pay-as-you-go answers 200 with its own status code: 1004 and
    /// 2049 are a refused key, 1008 an empty balance. A throttle (1002), a
    /// token cap (1039) or a parameter the model would not take (2013) all
    /// come after the key was accepted, so they prove it as well; a server
    /// fault (1000, 1001, 1013) proves nothing.
    private static let miniMaxCheck = APIParse { response in
        guard let code = JSONPath.number(response.json, "base_resp.status_code") else {
            throw APIParseError.unrecognised
        }
        switch Int(code) {
        case 0, 1002, 1039, 2013: return .keyWorks(.noUsageAPI)
        case 1008: return .keyWorks(.outOfCredits)
        case 1004, 2049: throw APIParseError.refused
        default:
            throw APIParseError.vendor(JSONPath.string(response.json, "base_resp.status_msg") ?? "MiniMax \(Int(code))")
        }
    }

    /// Mistral's admin usage: documented by name, not by field. A total is
    /// read where the obvious one is; anything else still proves the key.
    private static let mistralSpend = APIParse { response in
        for path in ["total_cost", "total", "data.total_cost", "total_amount"] {
            if let value = JSONPath.number(response.json, path), value >= 0,
               let currency = JSONPath.string(response.json, "currency") {
                return .spend(value, .money(currency.uppercased()), .month)
            }
        }
        throw APIParseError.unrecognised
    }

    /// Requesty's management list: per-key monthly spend, summed, against
    /// the summed limits when every key has one.
    private static let requestySpend = APIParse { response in
        let list = (response.json as? [Any]) ?? (JSONPath.value(response.json, "data") as? [Any])
            ?? (JSONPath.value(response.json, "api_keys") as? [Any])
        guard let list else { throw APIParseError.unrecognised }
        var spent = 0.0
        var limit: Double? = 0
        for item in list {
            guard let spend = JSONPath.number(item, "monthly_spend"), spend >= 0 else { throw APIParseError.unrecognised }
            spent += spend
            if let cap = JSONPath.number(item, "monthly_limit"), cap > 0, let sum = limit { limit = sum + cap } else { limit = nil }
        }
        if let limit, limit > 0 { return .used(spent, of: limit, .money("USD"), resetsAt: nil) }
        return .spend(spent, .money("USD"), .month)
    }

    /// Resend counts emails in a header, on any call; without it the key
    /// still worked.
    private static let resendQuota = APIParse { response in
        guard let used = response.headers["x-resend-monthly-quota"].flatMap(Double.init) else {
            throw APIParseError.unrecognised
        }
        return .count(used, .emails, .month)
    }

    // MARK: Entries

    static let entries: [APICatalogEntry] = routers + llm + asia + media + search + infra

    private static let routers: [APICatalogEntry] = [
        APICatalogEntry(
            id: "openrouter", name: "OpenRouter", category: .routers, readability: .usage, glyph: .openrouter,
            consoleURL: url("https://openrouter.ai/settings/keys"), keyPrefix: "sk-or-v1-",
            measure: .balanceAndSpend,
            route: .catalog(APIRecipe(
                request: r("https://openrouter.ai/api/v1/key"), parse: openRouterKey,
                // The account's credits, when the key may see them.
                extras: [APIExtra(request: r("https://openrouter.ai/api/v1/credits"), parse: openRouterCreditsLeft)]))),
        APICatalogEntry(
            id: "openroutercredits", name: "OpenRouter credits", category: .routers,
            aliases: ["openrouter", "management"], readability: .adminKey, glyph: .openrouter,
            consoleURL: url("https://openrouter.ai/settings/keys"), keyPrefix: "sk-or-v1-",
            keyKind: .management, measure: .balance,
            route: .catalog(APIRecipe(request: r("https://openrouter.ai/api/v1/credits"),
                                      parse: .balanceSpent(left: "data.total_credits", spent: "data.total_usage", .money("USD"))
                                          .creditsLessUsage()))),
        APICatalogEntry(
            id: "vercel", name: "Vercel AI Gateway", category: .routers, aliases: ["ai gateway"],
            readability: .usage, glyph: .vercel, consoleURL: url("https://vercel.com/dashboard"), keyPrefix: "vck_",
            measure: .balance,
            route: .catalog(APIRecipe(request: r("https://ai-gateway.vercel.sh/v1/credits"),
                                      parse: .balanceSpent(left: "balance", spent: "total_used", .money("USD"))))),
        // Partial: the management API is enterprise-only and its list shape
        // is not pinned down. Anything unexpected is refused.
        APICatalogEntry(
            id: "requesty", name: "Requesty", category: .routers, readability: .adminKey, glyph: .requesty,
            consoleURL: url("https://app.requesty.ai/api-keys"), keyKind: .management, measure: .spend,
            route: .catalog(APIRecipe(request: r("https://api-v2.requesty.ai/v1/manage/apikey"), parse: requestySpend))),
        // Partial: v2 replaced v1 in 2026 and the docs page lags.
        APICatalogEntry(
            id: "aimlapi", name: "AI/ML API", category: .routers, aliases: ["aiml"],
            readability: .usage, glyph: .aimlapi, consoleURL: url("https://aimlapi.com/app/keys"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.aimlapi.com/v2/billing"),
                                      parse: .balance("current_balance", .money("USD"))))),
        APICatalogEntry(
            id: "poe", name: "Poe", category: .routers, readability: .usage, glyph: .poe,
            consoleURL: url("https://poe.com/api_key"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.poe.com/usage/current_balance"),
                                      parse: .balance("current_point_balance", .points)))),
        APICatalogEntry(
            id: "nanogpt", name: "NanoGPT", category: .routers, aliases: ["nano gpt"],
            readability: .usage, glyph: .nanogpt, consoleURL: url("https://nano-gpt.com/api"), measure: .balance,
            route: .catalog(APIRecipe(auth: .header("x-api-key"),
                                      request: r("https://nano-gpt.com/api/check-balance", method: "POST"),
                                      parse: .balance("usd_balance", .money("USD"))))),
        APICatalogEntry(
            id: "venice", name: "Venice AI", category: .routers, readability: .usage, glyph: .venice,
            consoleURL: url("https://venice.ai/settings/api"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.venice.ai/api/v1/api_keys/rate_limits"),
                                      parse: veniceBalance))),
        // Partial: `/users/me` is inferred from the OpenAPI spec.
        APICatalogEntry(
            id: "chutes", name: "Chutes", category: .routers, readability: .usage, glyph: .chutes,
            consoleURL: url("https://chutes.ai/app/api"), keyPrefix: "cpk_", measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.chutes.ai/users/me"),
                                      parse: .balance("balance", .money("USD"))))),
        // Partial: the GraphQL dataset's field names come from the docs'
        // examples. A refused query is shown as Cloudflare's own words.
        APICatalogEntry(
            id: "cloudflare", name: "Cloudflare Workers AI", category: .routers,
            aliases: ["ai gateway", "workers"], readability: .adminKey, glyph: .cloudflare,
            consoleURL: url("https://dash.cloudflare.com/profile/api-tokens"),
            fields: [APIField(id: "account", title: { L10n.t("Account ID") }, placeholder: "0123abcd…", required: true)],
            keyKind: .cloudflareToken, measure: .usageCount,
            route: .catalog(APIRecipe(
                request: r("https://api.cloudflare.com/client/v4/graphql", method: "POST",
                           body: #"{"query":"query($tag:string!,$start:Time!,$end:Time!){viewer{accounts(filter:{accountTag:$tag}){aiInferenceAdaptiveGroups(limit:10000,filter:{datetime_geq:$start,datetime_leq:$end}){sum{totalNeurons}}}}}","variables":{"tag":"{account}","start":"{monthStartISO}","end":"{nowISO}"}}"#),
                parse: cloudflareNeurons))),
    ]

    private static let llm: [APICatalogEntry] = [
        APICatalogEntry(
            id: "openai", name: "OpenAI", category: .llm, aliases: ["chatgpt", "gpt"], readability: .adminKey,
            glyph: .openai, consoleURL: url("https://platform.openai.com/settings/organization/admin-keys"),
            keyPrefix: "sk-admin-", requiredKeyPrefix: "sk-admin-", keyKind: .admin(prefix: "sk-admin-"),
            measure: .spend,
            route: .catalog(APIRecipe(
                request: r("https://api.openai.com/v1/organization/costs?start_time={monthStartUnix}&bucket_width=1d&limit=31"),
                parse: .spendSum("data[*].results[*].amount.value", list: "data", .money("USD"))))),
        // Amounts are decimal strings in cents.
        APICatalogEntry(
            id: "anthropic", name: "Anthropic", category: .llm, aliases: ["claude api"], readability: .adminKey,
            glyph: .anthropic, consoleURL: url("https://console.anthropic.com/settings/admin-keys"),
            keyPrefix: "sk-ant-admin01-", requiredKeyPrefix: "sk-ant-admin", keyKind: .admin(prefix: "sk-ant-admin"),
            measure: .spend,
            route: .catalog(APIRecipe(
                auth: .header("x-api-key"), headers: ["anthropic-version": "2023-06-01"],
                request: r("https://api.anthropic.com/v1/organizations/cost_report?starting_at={monthStartISO}&bucket_width=1d&limit=31"),
                parse: .spendSum("data[*].results[*].amount", list: "data", .money("USD"), scale: 0.01)))),
        // Partial: the team id comes from the inference API's own key
        // endpoint when it is not typed in, and the ledger's units and sign
        // are from CodexBar's notes.
        APICatalogEntry(
            id: "xai", name: "xAI", category: .llm, aliases: ["grok"], readability: .adminKey, glyph: .xai,
            consoleURL: url("https://console.x.ai"), keyPrefix: "xai-",
            fields: [APIField(id: "team", title: { L10n.t("Team ID") },
                              placeholder: L10n.t("Optional — read from the key"), required: false)],
            keyKind: .management, measure: .balanceAndSpend,
            forbidden: { L10n.t("This management key can't read billing — give it billing access in the xAI Console") },
            notFound: { L10n.t("xAI has no billing for that team — check the Team ID, or leave it empty") },
            route: .catalog(APIRecipe(
                // The management key's own description names its team, and
                // asking for it is the check that the key is one at all.
                prefetch: [APIPrefetch(variable: "team",
                                       request: r("https://management-api.x.ai/auth/management-keys/validation"),
                                       path: "teamId",
                                       missing: { L10n.t("xAI didn't say which team this key is for — add your Team ID") })],
                // The invoice preview, not the prepaid ledger: the ledger
                // answers 404 for a team billed after the fact, and the
                // preview has both — credits bought ahead and this cycle's
                // spend against its limit.
                request: r("https://management-api.x.ai/v1/billing/teams/{team}/postpaid/invoice/preview"),
                parse: xaiInvoice))),
        // Partial: the admin API's field names are not in the docs.
        APICatalogEntry(
            id: "mistral", name: "Mistral", category: .llm, readability: .adminKey, glyph: .mistral,
            consoleURL: url("https://admin.mistral.ai"), keyKind: .admin(prefix: nil), measure: .spend,
            bestEffortUsage: true,
            route: .catalog(APIRecipe(auth: .header("x-api-key"),
                                      request: r("https://api.mistral.ai/v1/admin/usage?month={month}&year={year}"),
                                      parse: mistralSpend))),
        APICatalogEntry(
            id: "gemini", name: "Google Gemini API", category: .llm, aliases: ["ai studio", "google"],
            readability: .keyCheck, glyph: .geminiSpark, consoleURL: url("https://aistudio.google.com/apikey"),
            keyPrefix: "AIza", measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("x-goog-api-key"),
                                      request: r("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"),
                                      parse: .keyWorks))),
        APICatalogEntry(
            id: "groq", name: "Groq", category: .llm, readability: .keyCheck, glyph: .groq,
            consoleURL: url("https://console.groq.com/keys"), keyPrefix: "gsk_", measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.groq.com/openai/v1/models"),
                                      parse: .keyWorks(remaining: "x-ratelimit-remaining-requests",
                                                       limit: "x-ratelimit-limit-requests", today: true)))),
        APICatalogEntry(
            id: "together", name: "Together AI", category: .llm, readability: .keyCheck, glyph: .together,
            consoleURL: url("https://api.together.ai/settings/api-keys"), measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.together.xyz/v1/models"), parse: .keyWorks))),
        // Partial: no endpoint names the account, so it is typed in.
        APICatalogEntry(
            id: "fireworks", name: "Fireworks AI", category: .llm, readability: .usage, glyph: .fireworks,
            consoleURL: url("https://fireworks.ai/account/api-keys"), keyPrefix: "fw_",
            fields: [APIField(id: "account", title: { L10n.t("Account ID") }, placeholder: "my-account", required: true)],
            measure: .spend,
            route: .catalog(APIRecipe(
                request: r("https://api.fireworks.ai/v1/accounts/{account}/billingUsage?startTime={monthStartISO}&endTime={nowISO}&usageType=SERVERLESS"),
                parse: .spendSum("serverlessCosts[*].costNanoUsd", list: "serverlessCosts", .money("USD"), scale: 1e-9)))),
        APICatalogEntry(
            id: "deepinfra", name: "DeepInfra", category: .llm, readability: .usage, glyph: .deepinfra,
            consoleURL: url("https://deepinfra.com/dash/api_keys"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.deepinfra.com/payment/checklist"), parse: deepInfraBalance))),
        // In units of 0.0001 USD.
        APICatalogEntry(
            id: "novita", name: "Novita AI", category: .llm, readability: .usage, glyph: .novita,
            consoleURL: url("https://novita.ai/settings/key-management"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.novita.ai/openapi/v1/billing/balance/detail"),
                                      parse: .balance("availableBalance", .money("USD"), scale: 0.0001)))),
        // Unverified: the endpoint is from Hyperbolic's AgentKit, which reads
        // `credits` as cents. Anything else is refused.
        APICatalogEntry(
            id: "hyperbolic", name: "Hyperbolic", category: .llm, readability: .usage, glyph: .hyperbolic,
            consoleURL: url("https://app.hyperbolic.xyz/settings"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.hyperbolic.xyz/billing/get_current_balance"),
                                      parse: .balance("credits", .money("USD"), scale: 0.01)))),
        // Partial: cost in nano-dollars, for a key with billing permission.
        APICatalogEntry(
            id: "featherless", name: "Featherless", category: .llm, readability: .adminKey, glyph: .featherless,
            consoleURL: url("https://featherless.ai/account/api-keys"), keyKind: .admin(prefix: nil), measure: .spend,
            route: .catalog(APIRecipe(
                request: r("https://api.featherless.ai/usage/activity/summary?start={monthStartUnix}&end={nowUnix}"),
                parse: .spend("totals.cost", .money("USD"), scale: 1e-9)))),
        // Partial: header names from a real response, not the docs page.
        APICatalogEntry(
            id: "cerebras", name: "Cerebras", category: .llm, readability: .keyCheck, glyph: .cerebras,
            consoleURL: url("https://cloud.cerebras.ai"), keyPrefix: "csk-", measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.cerebras.ai/v1/models"),
                                      parse: .keyWorks(remaining: "x-ratelimit-remaining-requests-day",
                                                       limit: "x-ratelimit-limit-requests-day", today: true)))),
        APICatalogEntry(
            id: "sambanova", name: "SambaNova", category: .llm, readability: .keyCheck, glyph: .sambanova,
            // The model list answers anyone, key or not, so the check has to
            // be a one-token chat — billed, so only when asked.
            consoleURL: url("https://cloud.sambanova.ai/apis"), measure: .keyCheck, billedCheck: true,
            route: .catalog(APIRecipe(request: chat("https://api.sambanova.ai/v1/chat/completions", model: "Meta-Llama-3.3-70B-Instruct"),
                                      parse: .keyWorks(remaining: "x-ratelimit-remaining-requests-day",
                                                       limit: "x-ratelimit-limit-requests-day", today: true)))),
        APICatalogEntry(
            id: "nebius", name: "Nebius AI Studio", category: .llm, aliases: ["token factory"],
            readability: .keyCheck, glyph: .nebius, consoleURL: url("https://tokenfactory.nebius.com"), measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.tokenfactory.nebius.com/v1/models"),
                                      parse: .keyWorks(remaining: "x-ratelimit-remaining-requests", limit: nil, today: false)))),
        APICatalogEntry(
            id: "cohere", name: "Cohere", category: .llm, readability: .keyCheck, glyph: .cohere,
            consoleURL: url("https://dashboard.cohere.com/api-keys"), measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.cohere.com/v1/check-api-key", method: "POST"),
                                      parse: cohereCheck))),
        APICatalogEntry(
            id: "perplexity", name: "Perplexity", category: .llm, aliases: ["sonar"], readability: .keyCheck, glyph: .perplexity,
            consoleURL: url("https://www.perplexity.ai/account/api/keys"), keyPrefix: "pplx-",
            measure: .keyCheck, billedCheck: true,
            route: .catalog(APIRecipe(request: chat("https://api.perplexity.ai/chat/completions", model: "sonar"),
                                      parse: .keyWorks))),
        APICatalogEntry(
            id: "ai21", name: "AI21", category: .llm, aliases: ["jamba"], readability: .keyCheck, glyph: .ai21,
            consoleURL: url("https://studio.ai21.com/account/api-key"), measure: .keyCheck, billedCheck: true,
            route: .catalog(APIRecipe(request: chat("https://api.ai21.com/studio/v1/chat/completions", model: "jamba-mini"),
                                      parse: .keyWorks))),
        APICatalogEntry(
            id: "huggingface", name: "Hugging Face", category: .llm, aliases: ["hf", "inference providers"],
            readability: .keyCheck, glyph: .huggingface, consoleURL: url("https://huggingface.co/settings/tokens"), keyPrefix: "hf_",
            keyKind: .personalToken, measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://huggingface.co/api/whoami-v2"), parse: .keyWorks))),
        APICatalogEntry(
            id: "ollama", name: "Ollama Cloud", category: .llm, readability: .usage, glyph: .ollama,
            consoleURL: url("https://ollama.com/settings/keys"), measure: .plan, route: .existing),
    ]

    private static let asia: [APICatalogEntry] = [
        APICatalogEntry(
            id: "deepseek", name: "DeepSeek", category: .asia, readability: .usage, glyph: .deepseek,
            consoleURL: url("https://platform.deepseek.com/api_keys"), keyPrefix: "sk-", measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.deepseek.com/user/balance"), parse: deepSeekBalance))),
        APICatalogEntry(
            id: "moonshot", name: "Kimi (Moonshot)", category: .asia, aliases: ["kimi", "moonshot"],
            readability: .usage, glyph: .kimi, consoleURL: url("https://platform.kimi.ai"), keyPrefix: "sk-",
            regions: regions(global: "https://api.moonshot.ai", china: "https://api.moonshot.cn",
                             globalCurrency: "USD", chinaCurrency: "CNY"),
            measure: .balance,
            route: .catalog(APIRecipe(request: r("{base}/v1/users/me/balance"),
                                      parse: APIParse.balance("data.available_balance", .money(nil)).requiringCodeZero()))),
        APICatalogEntry(
            id: "siliconflow", name: "SiliconFlow", category: .asia, aliases: ["silicon flow", "硅基流动"],
            readability: .usage, glyph: .siliconflow, consoleURL: url("https://cloud.siliconflow.com/account/ak"), keyPrefix: "sk-",
            regions: regions(global: "https://api.siliconflow.com", china: "https://api.siliconflow.cn",
                             globalCurrency: "USD", chinaCurrency: "CNY"),
            measure: .balance,
            route: .catalog(APIRecipe(request: r("{base}/v1/user/info"),
                                      parse: .balance("data.totalBalance", .money(nil))))),
        APICatalogEntry(
            id: "stepfun", name: "StepFun", category: .asia, aliases: ["step"], readability: .usage, glyph: .stepfun,
            consoleURL: url("https://platform.stepfun.com/interface-key"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.stepfun.com/v1/accounts"),
                                      parse: .balance("balance", .money("CNY"))))),
        APICatalogEntry(
            id: "glm", name: "GLM Coding Plan", category: .asia, aliases: ["zhipu", "z.ai", "zai", "bigmodel"],
            readability: .usage, glyph: .glm, consoleURL: url("https://z.ai/manage-apikey/apikey-list"),
            regions: [APIRegion(id: "global", title: { L10n.t("Global (z.ai)") }, base: "https://api.z.ai", currency: nil),
                      APIRegion(id: "china", title: { L10n.t("China (bigmodel.cn)") }, base: "https://open.bigmodel.cn", currency: nil)],
            measure: .plan, route: .existing),
        APICatalogEntry(
            id: "zai", name: "Z.ai / Zhipu (pay-as-you-go)", category: .asia,
            aliases: ["glm", "zhipu", "z.ai", "bigmodel"], readability: .keyCheck, glyph: .zai,
            consoleURL: url("https://z.ai/manage-apikey/apikey-list"),
            regions: [APIRegion(id: "global", title: { L10n.t("Global (z.ai)") }, base: "https://api.z.ai/api/paas/v4", currency: nil),
                      APIRegion(id: "china", title: { L10n.t("China (bigmodel.cn)") }, base: "https://open.bigmodel.cn/api/paas/v4", currency: nil)],
            measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("{base}/models"), parse: .keyWorks))),
        APICatalogEntry(
            id: "minimax", name: "MiniMax Coding Plan", category: .asia, aliases: ["hailuo"], readability: .usage,
            glyph: .minimax, consoleURL: url("https://platform.minimax.io/user-center/basic-information/interface-key"),
            regions: [APIRegion(id: MiniMaxRegion.international.rawValue, title: { L10n.t("International") }, base: "", currency: nil),
                      APIRegion(id: MiniMaxRegion.china.rawValue, title: { L10n.t("China mainland") }, base: "", currency: nil)],
            measure: .plan, route: .existing),
        APICatalogEntry(
            id: "minimaxapi", name: "MiniMax (pay-as-you-go)", category: .asia, aliases: ["minimax", "hailuo"],
            readability: .keyCheck, glyph: .minimax,
            consoleURL: url("https://platform.minimax.io/user-center/basic-information/interface-key"),
            regions: regions(global: "https://api.minimax.io", china: "https://api.minimaxi.com",
                             globalID: MiniMaxRegion.international.rawValue),
            measure: .keyCheck, billedCheck: true,
            route: .catalog(APIRecipe(request: chat("{base}/v1/text/chatcompletion_v2", model: "MiniMax-M2"),
                                      parse: miniMaxCheck))),
        // Unverified: no models list is documented, so the check is a chat.
        APICatalogEntry(
            id: "baichuan", name: "Baichuan", category: .asia, readability: .keyCheck, glyph: .baichuan,
            consoleURL: url("https://platform.baichuan-ai.com/console/apikey"), keyPrefix: "sk-",
            measure: .keyCheck, billedCheck: true,
            route: .catalog(APIRecipe(request: chat("https://api.baichuan-ai.com/v1/chat/completions", model: "Baichuan4-Turbo"),
                                      parse: .keyWorks))),
    ]

    private static let media: [APICatalogEntry] = [
        APICatalogEntry(
            id: "elevenlabs", name: "ElevenLabs", category: .media, aliases: ["11labs", "voice"],
            readability: .usage, glyph: .elevenlabs, consoleURL: url("https://elevenlabs.io/app/settings/api-keys"), keyPrefix: "sk_",
            measure: .planUsed,
            route: .catalog(APIRecipe(auth: .header("xi-api-key"),
                                      request: r("https://api.elevenlabs.io/v1/user/subscription"),
                                      parse: .used("character_count", of: "character_limit", .characters,
                                                   resets: "next_character_count_reset_unix")))),
        APICatalogEntry(
            id: "deepgram", name: "Deepgram", category: .media, aliases: ["speech"], readability: .usage, glyph: .deepgram,
            consoleURL: url("https://console.deepgram.com"), measure: .balance,
            route: .catalog(APIRecipe(
                auth: .prefixed("Authorization", prefix: "Token "),
                prefetch: [APIPrefetch(variable: "project", request: r("https://api.deepgram.com/v1/projects"),
                                       path: "projects[0].project_id", missing: projectMissing("Deepgram"))],
                request: r("https://api.deepgram.com/v1/projects/{project}/balances"),
                parse: deepgramBalance))),
        APICatalogEntry(
            id: "assemblyai", name: "AssemblyAI", category: .media, aliases: ["assembly"], readability: .keyCheck, glyph: .assemblyai,
            consoleURL: url("https://www.assemblyai.com/app/api-keys"), measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("Authorization"),
                                      request: r("https://api.assemblyai.com/v2/transcript?limit=1"), parse: .keyWorks))),
        APICatalogEntry(
            id: "cartesia", name: "Cartesia", category: .media, readability: .adminKey, glyph: .cartesia,
            consoleURL: url("https://play.cartesia.ai/keys"), keyPrefix: "sk_car_",
            keyKind: .admin(prefix: nil), measure: .usageCount,
            route: .catalog(APIRecipe(
                headers: ["Cartesia-Version": "2026-08-14"],
                request: r("https://api.cartesia.ai/usage/credits?start_ts={monthStartISO}&end_ts={nowISO}&interval=month"),
                parse: APIParse { response in
                    guard JSONPath.value(response.json, "data") is [Any] else { throw APIParseError.unrecognised }
                    let credits = JSONPath.numbers(response.json, "data[*].credits") ?? []
                    return .count(credits.reduce(0, +), .credits, .month)
                }))),
        // Runware takes a list of tasks at one address; asking for the
        // account's details runs nothing.
        APICatalogEntry(
            id: "runware", name: "Runware", category: .media, aliases: ["image", "flux"],
            readability: .usage, glyph: .runware, consoleURL: url("https://runware.ai/dashboard"), measure: .balanceAndSpend,
            route: .catalog(APIRecipe(
                request: r("https://api.runware.ai/v1", method: "POST",
                           body: #"[{"taskType":"accountManagement","taskUUID":"{uuid}","operation":"getDetails"}]"#),
                parse: .runwareBalance))),
        // No usage API and nothing free to call: a job id that cannot exist is
        // looked up, and the 404 proves the key.
        APICatalogEntry(
            id: "pruna", name: "Pruna AI", category: .media, aliases: ["p-api", "p-image"],
            readability: .keyCheck, glyph: .pruna, consoleURL: url("https://dashboard.pruna.ai"), measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("apikey"),
                                      request: r("https://api.pruna.ai/v1/predictions/status/pillr-check-{uuid}"),
                                      parse: .keyWorks, acceptedStatuses: [404]))),
        APICatalogEntry(
            id: "bria", name: "Bria AI", category: .media, aliases: ["bria"],
            readability: .keyCheck, glyph: .bria, consoleURL: url("https://platform.bria.ai/organization-management/api-keys"),
            measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("api_token"),
                                      request: r("https://engine.prod.bria-api.com/v2/status/pillr-check-{uuid}"),
                                      parse: .keyWorks, acceptedStatuses: [404]))),
        APICatalogEntry(
            id: "stability", name: "Stability AI", category: .media, aliases: ["stable diffusion"],
            readability: .usage, glyph: .stability, consoleURL: url("https://platform.stability.ai/account/keys"), keyPrefix: "sk-",
            measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.stability.ai/v1/user/balance"),
                                      parse: .balance("credits", .credits)))),
        // Partial: field names from Runway's own guides.
        APICatalogEntry(
            id: "runway", name: "Runway", category: .media, readability: .usage, glyph: .runway,
            consoleURL: url("https://dev.runwayml.com"), keyPrefix: "key_", measure: .balance,
            route: .catalog(APIRecipe(headers: ["X-Runway-Version": "2024-11-06"],
                                      request: r("https://api.dev.runwayml.com/v1/organization"),
                                      parse: .balance("creditBalance", .credits)))),
        // Partial: field names from the FAQ and third-party SDKs.
        APICatalogEntry(
            id: "leonardo", name: "Leonardo AI", category: .media, readability: .usage,
            consoleURL: url("https://app.leonardo.ai/api-access"), measure: .left,
            route: .catalog(APIRecipe(request: r("https://cloud.leonardo.ai/api/rest/v1/me"), parse: leonardoBalance))),
        APICatalogEntry(
            id: "ideogram", name: "Ideogram", category: .media, readability: .usage, glyph: .ideogram,
            consoleURL: url("https://ideogram.ai/manage-api"), measure: .spend,
            route: .catalog(APIRecipe(auth: .header("Api-Key"),
                                      request: r("https://api.ideogram.ai/v2/account/usage?start_time={monthStartISO}&end_time={nowISO}&bucket_width=1d"),
                                      parse: ideogramSpend))),
        // Partial: the scope a key needs for billing is unstated.
        APICatalogEntry(
            id: "fal", name: "fal.ai", category: .media, aliases: ["fal"], readability: .usage, glyph: .fal,
            consoleURL: url("https://fal.ai/dashboard/keys"), measure: .balance,
            route: .catalog(APIRecipe(auth: .prefixed("Authorization", prefix: "Key "),
                                      request: r("https://api.fal.ai/v1/account/billing?expand=credits"),
                                      parse: APIParse { response in
                                          guard let balance = JSONPath.number(response.json, "credits.current_balance")
                                          else { throw APIParseError.unrecognised }
                                          let code = JSONPath.string(response.json, "credits.currency")?.uppercased() ?? "USD"
                                          return .balance(balance, .money(code))
                                      }))),
        APICatalogEntry(
            id: "replicate", name: "Replicate", category: .media, readability: .keyCheck, glyph: .replicate,
            consoleURL: url("https://replicate.com/account/api-tokens"), keyPrefix: "r8_", measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.replicate.com/v1/account"), parse: .keyWorks))),
    ]

    private static let search: [APICatalogEntry] = [
        APICatalogEntry(
            id: "tavily", name: "Tavily", category: .search, readability: .usage, glyph: .tavily,
            consoleURL: url("https://app.tavily.com"), keyPrefix: "tvly-", measure: .planUsed,
            route: .catalog(APIRecipe(request: r("https://api.tavily.com/usage"), parse: tavilyUsage))),
        APICatalogEntry(
            id: "serpapi", name: "SerpApi", category: .search, aliases: ["serp"], readability: .usage, glyph: .serpapi,
            consoleURL: url("https://serpapi.com/manage-api-key"), measure: .planUsed,
            route: .catalog(APIRecipe(auth: .query("api_key"), request: r("https://serpapi.com/account.json"),
                                      parse: serpApiUsage))),
        // Unverified: `/account` is seen only in community tools.
        APICatalogEntry(
            id: "serper", name: "Serper", category: .search, aliases: ["google search"], readability: .usage, glyph: .serper,
            consoleURL: url("https://serper.dev/api-key"), measure: .balance,
            route: .catalog(APIRecipe(auth: .header("X-API-KEY"), request: r("https://google.serper.dev/account"),
                                      parse: .balance("balance", .credits)))),
        // Partial: spend for one key, by its id, with a service key.
        APICatalogEntry(
            id: "exa", name: "Exa", category: .search, readability: .adminKey, glyph: .exa,
            consoleURL: url("https://dashboard.exa.ai/api-keys"),
            fields: [APIField(id: "keyid", title: { L10n.t("API key ID") }, placeholder: "…", required: true)],
            keyKind: .service, measure: .spend,
            route: .catalog(APIRecipe(auth: .header("x-api-key"),
                                      request: r("https://admin-api.exa.ai/team-management/api-keys/{keyid}/usage"),
                                      parse: .spend("total_cost_usd", .money("USD"), period: .billingPeriod)))),
        APICatalogEntry(
            id: "firecrawl", name: "Firecrawl", category: .search, readability: .usage, glyph: .firecrawl,
            consoleURL: url("https://www.firecrawl.dev/app/api-keys"), keyPrefix: "fc-", measure: .left,
            route: .catalog(APIRecipe(request: r("https://api.firecrawl.dev/v2/team/credit-usage"), parse: firecrawlCredits))),
        // Unverified: a dashboard endpoint third parties use; tokens left.
        APICatalogEntry(
            id: "jina", name: "Jina AI", category: .search, aliases: ["reader"], readability: .usage, glyph: .jina,
            consoleURL: url("https://jina.ai/api-dashboard/key-manager"), keyPrefix: "jina_", measure: .left,
            route: .catalog(APIRecipe(auth: .query("api_key"), request: r("https://dash.jina.ai/api/v1/api_key/fe_user"),
                                      parse: .balance("wallet.total_balance", .tokens)))),
        APICatalogEntry(
            id: "scrapingbee", name: "ScrapingBee", category: .search, readability: .usage, glyph: .scrapingbee,
            consoleURL: url("https://app.scrapingbee.com/account/manage/api_key"), measure: .planUsed,
            route: .catalog(APIRecipe(request: r("https://app.scrapingbee.com/api/v1/usage"),
                                      parse: .used("used_api_credit", of: "max_api_credit", .credits,
                                                   resets: "renewal_subscription_date")))),
        APICatalogEntry(
            id: "scraperapi", name: "ScraperAPI", category: .search, readability: .usage, glyph: .scraperapi,
            consoleURL: url("https://dashboard.scraperapi.com"), measure: .planUsed,
            route: .catalog(APIRecipe(auth: .query("api_key"), request: r("https://api.scraperapi.com/account"),
                                      parse: .used("requestCount", of: "requestLimit", .requests)))),
        APICatalogEntry(
            id: "brightdata", name: "Bright Data", category: .search, readability: .usage, glyph: .brightdata,
            consoleURL: url("https://brightdata.com/cp/setting/users"), measure: .balance,
            route: .catalog(APIRecipe(request: r("https://api.brightdata.com/customer/balance"),
                                      parse: .balance("balance", .money("USD"))))),
        APICatalogEntry(
            id: "apify", name: "Apify", category: .search, readability: .usage, glyph: .apify,
            consoleURL: url("https://console.apify.com/settings/integrations"), keyPrefix: "apify_api_",
            measure: .plan, route: .existing),
    ]

    private static let infra: [APICatalogEntry] = [
        APICatalogEntry(
            id: "browserbase", name: "Browserbase", category: .infra, readability: .usage, glyph: .browserbase,
            consoleURL: url("https://www.browserbase.com/settings"), keyPrefix: "bb_live_", measure: .usageCount,
            route: .catalog(APIRecipe(
                auth: .header("X-BB-API-Key"),
                prefetch: [APIPrefetch(variable: "project", request: r("https://api.browserbase.com/v1/projects"),
                                       path: "[0].id", missing: projectMissing("Browserbase"))],
                request: r("https://api.browserbase.com/v1/projects/{project}/usage"),
                parse: .count("browserMinutes", .minutes)))),
        APICatalogEntry(
            id: "e2b", name: "E2B", category: .infra, aliases: ["sandbox"], readability: .keyCheck, glyph: .e2b,
            consoleURL: url("https://e2b.dev/dashboard?tab=keys"), keyPrefix: "e2b_", measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("X-API-Key"), request: r("https://api.e2b.app/sandboxes"),
                                      parse: .keyWorks))),
        APICatalogEntry(
            id: "neon", name: "Neon", category: .infra, aliases: ["postgres"], readability: .usage, glyph: .neon,
            consoleURL: url("https://console.neon.tech/app/settings/api-keys"), keyPrefix: "napi_",
            fields: [APIField(id: "project", title: { L10n.t("Project ID") }, placeholder: L10n.t("Optional"), required: false)],
            measure: .usageCount,
            route: .catalog(APIRecipe(
                prefetch: [APIPrefetch(variable: "project", request: r("https://console.neon.tech/api/v2/projects"),
                                       path: "projects[0].id", missing: projectMissing("Neon"))],
                request: r("https://console.neon.tech/api/v2/projects/{project}"),
                parse: .count("project.compute_time_seconds", .computeHours, scale: 1.0 / 3600)))),
        APICatalogEntry(
            id: "supabase", name: "Supabase", category: .infra, readability: .keyCheck, glyph: .supabase,
            consoleURL: url("https://supabase.com/dashboard/account/tokens"), keyPrefix: "sbp_",
            keyKind: .personalToken, measure: .keyCheck,
            route: .catalog(APIRecipe(request: r("https://api.supabase.com/v1/projects"), parse: .keyWorks))),
        APICatalogEntry(
            id: "upstash", name: "Upstash", category: .infra, aliases: ["redis"], readability: .keyCheck, glyph: .upstash,
            consoleURL: url("https://console.upstash.com/account/api"),
            fields: [APIField(id: "email", title: { L10n.t("Account email") }, placeholder: "you@example.com", required: true)],
            keyKind: .upstash, measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .basic(emailField: "email"),
                                      request: r("https://api.upstash.com/v2/redis/databases"), parse: .keyWorks))),
        APICatalogEntry(
            id: "pinecone", name: "Pinecone", category: .infra, aliases: ["vector"], readability: .keyCheck, glyph: .pinecone,
            consoleURL: url("https://app.pinecone.io"), keyPrefix: "pcsk_", measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("Api-Key"), headers: ["X-Pinecone-Api-Version": "2025-10"],
                                      request: r("https://api.pinecone.io/indexes"), parse: .keyWorks))),
        // Partial: the quota header is documented for sends; on a read it
        // may be absent, and then only the key is shown to work.
        APICatalogEntry(
            id: "resend", name: "Resend", category: .infra, aliases: ["email"], readability: .usage, glyph: .resend,
            consoleURL: url("https://resend.com/api-keys"), keyPrefix: "re_", measure: .usageCount,
            bestEffortUsage: true,
            route: .catalog(APIRecipe(request: r("https://api.resend.com/domains"), parse: resendQuota))),
        APICatalogEntry(
            id: "composio", name: "Composio", category: .infra, readability: .keyCheck, glyph: .composio,
            consoleURL: url("https://platform.composio.dev"), measure: .keyCheck,
            route: .catalog(APIRecipe(auth: .header("x-api-key"),
                                      request: r("https://backend.composio.dev/api/v3/tools?limit=1"), parse: .keyWorks))),
    ]

    // MARK: Lookup

    private static let byID: [String: APICatalogEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    static func entry(id: String) -> APICatalogEntry? { byID[id] }

    /// The entry behind a provider id: an extra key's, or a base provider's
    /// own (`glm`).
    static func entry(forProviderID id: String) -> APICatalogEntry? {
        if let base = ExtraKey.base(fromProviderID: id) { return byID[base] }
        guard let entry = byID[id], case .existing = entry.route else { return nil }
        return entry
    }

    /// Whether a provider's reading has a place in the notch. A key that can
    /// only be checked has nothing to fill a ring with.
    static func drawsRing(providerID id: String) -> Bool {
        guard id.hasPrefix(ExtraKey.catalogPrefix), let entry = entry(forProviderID: id) else { return true }
        return entry.readability != .keyCheck
    }

    /// Entries matching every word typed, in any order, ignoring case and
    /// accents — by name, id, alias, group or what the provider does
    /// ("voice", "scraping", "china") — best match first: a name that starts
    /// with what was typed before one that only contains it, a provider whose
    /// usage can be read before one whose key can only be checked.
    static func search(_ query: String, in list: [APICatalogEntry] = entries) -> [APICatalogEntry] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return list }
        return list.compactMap { entry -> (APICatalogEntry, Int)? in
            var total = 0
            for word in words {
                let score = score(entry, word)
                guard score > 0 else { return nil }
                total += score
            }
            return (entry, total)
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.readability.rank != b.0.readability.rank { return a.0.readability.rank < b.0.readability.rank }
            return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }
        .map(\.0)
    }

    /// Where a provider that wants a key other than its ordinary one says
    /// to make it — shown the moment that provider is chosen, because the
    /// key someone already has is exactly the one that will be refused.
    static func keyGuide(for id: String) -> String? {
        switch id {
        case "openai":
            return L10n.t("OpenAI shares costs only with an Admin key. Create one at platform.openai.com → Settings → Organization → Admin keys; it starts with sk-admin-. A project key (sk-proj-) is refused.")
        case "anthropic":
            return L10n.t("Anthropic shares costs only with an Admin key. Create one in the Claude Console → Settings → Admin keys; it starts with sk-ant-admin. An ordinary API key is refused.")
        case "xai":
            return L10n.t("xAI shares billing only with a management key — not a key from the API Keys page. Create one in the xAI Console → Settings → Management keys, with access to billing. The team is read from the key, so Team ID can stay empty.")
        case "openroutercredits":
            return L10n.t("The account's credits need a management key from OpenRouter → Settings → Management keys. For one key's own spend, choose OpenRouter instead.")
        case "mistral":
            return L10n.t("Mistral shares usage only through its Admin API, on Team and Enterprise plans. Create an admin key at admin.mistral.ai.")
        case "requesty":
            return L10n.t("Requesty shares spend only through its management API, on Enterprise plans. Use a management key from the Requesty dashboard.")
        case "cloudflare":
            return L10n.t("Create an API token under My Profile → API Tokens with Account Analytics: Read, then copy the Account ID from the right-hand side of the Cloudflare dashboard.")
        case "featherless", "cartesia", "exa":
            return L10n.t("This provider shares usage only with an admin key. Create one in its dashboard's team or admin settings — an ordinary API key is refused.")
        case "upstash":
            return L10n.t("Use a Developer API key from Upstash → Account → Management API, and the email you sign in with.")
        default:
            return nil
        }
    }

    /// What the field offers before anything is typed: the keys people
    /// most often hold.
    static let popularIDs = ["openrouter", "openai", "anthropic", "deepseek", "moonshot", "glm", "elevenlabs", "groq"]

    static var popular: [APICatalogEntry] { popularIDs.compactMap { entry(id: $0) } }

    /// Words for what a group's providers do, so a search can be for the job
    /// rather than the name.
    static func tags(for category: APICategory) -> [String] {
        switch category {
        case .routers: return ["router", "gateway", "proxy", "credits", "multi-model"]
        case .llm:     return ["llm", "chat", "model", "inference", "gpu", "text"]
        case .asia:    return ["china", "chinese", "asia", "cny", "yuan"]
        case .media:   return ["voice", "tts", "speech", "audio", "transcription", "stt", "image", "video", "music"]
        case .search:  return ["search", "scrape", "scraping", "crawl", "serp", "web", "browser"]
        case .infra:   return ["database", "db", "postgres", "vector", "sandbox", "serverless", "email", "redis"]
        }
    }

    /// How well one typed word fits an entry; 0 is not at all.
    static func score(_ entry: APICatalogEntry, _ word: String) -> Int {
        let name = fold(entry.name)
        if name == word { return 100 }
        if name.hasPrefix(word) { return 90 }
        if words(of: name).contains(where: { $0.hasPrefix(word) }) { return 80 }
        let aliases = entry.aliases.map(fold)
        if aliases.contains(word) { return 78 }
        if aliases.contains(where: { $0.hasPrefix(word) }) { return 70 }
        if aliases.flatMap(words(of:)).contains(where: { $0.hasPrefix(word) }) { return 65 }
        if entry.id.hasPrefix(word) { return 60 }
        let groupWords = tags(for: entry.category) + words(of: fold(entry.category.title))
        if groupWords.contains(where: { $0.hasPrefix(word) }) { return 40 }
        if name.contains(word) || name.replacingOccurrences(of: " ", with: "").contains(word) { return 35 }
        if aliases.contains(where: { $0.contains(word) }) || entry.id.contains(word) { return 25 }
        if word.count >= 3, isSubsequence(word, of: name.replacingOccurrences(of: " ", with: "")) { return 10 }
        return 0
    }

    /// Where the typed words land in a name, for the field to embolden.
    static func matchedRanges(in name: String, query: String) -> [Range<String.Index>] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let folded = fold(name)
        guard folded.count == name.count else { return [] }
        return words.compactMap { word in
            guard let range = folded.range(of: word) else { return nil }
            let lower = name.index(name.startIndex, offsetBy: folded.distance(from: folded.startIndex, to: range.lowerBound))
            let upper = name.index(lower, offsetBy: word.count)
            return lower..<upper
        }
    }

    private static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// "opnr" in "openrouter": every letter, in order, gaps allowed.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(haystack)
        for character in needle {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }

    /// The picker's sections: each group in order, its entries by name.
    static func grouped(_ list: [APICatalogEntry]) -> [(category: APICategory, entries: [APICatalogEntry])] {
        APICategory.allCases.compactMap { category in
            let members = list.filter { $0.category == category }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return members.isEmpty ? nil : (category, members)
        }
    }
}

extension APIParse {
    /// OpenRouter's `/credits` reports everything ever bought and everything
    /// ever used; what is left is the difference.
    fileprivate func creditsLessUsage() -> APIParse {
        let inner = self
        return APIParse { response in
            guard case .balanceSpent(let bought, let used, let unit) = try inner.read(response) else {
                throw APIParseError.unrecognised
            }
            return .balanceSpent(remaining: bought - used, spent: used, unit)
        }
    }
}
