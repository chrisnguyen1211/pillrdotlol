import Foundation
import os

/// One Claude account's limits, read from whichever source can answer without
/// interrupting anyone.
///
/// Three sources, in order. Claude Desktop's HTTP cache is read first, because
/// it is the one that costs nothing and cannot be refused: no subprocess, no
/// keychain, no network — see `ClaudeDesktopUsageCache`. It answers only while
/// Desktop is running, and only for the account Desktop is signed into, so where
/// it is silent `claude "/usage"` is asked next: it reports the same figures off
/// a credential Claude Code already holds, and needs no keychain access from
/// this app — which matters because Claude Code files a new keychain item on
/// every token rotation, so a grant the user gives against the old item is good
/// for about an hour. Where that fails or Claude Code is not installed, the
/// usage endpoint is called directly with the OAuth token from the keychain,
/// exactly as before.
///
/// One instance per `ClaudeProfile`: a work login kept under `~/.claude-work`
/// has its own token, its own limits and its own ring, and this reads exactly
/// one of them.
///
/// The numbers are Anthropic's, so this is `.official` — the tooltip shows them
/// unqualified. The endpoint is not a published API, though, so every failure
/// path degrades to a status the UI can render honestly rather than to a guess.
actor ClaudeOAuthProvider: UsageProvider {
    nonisolated let profile: ClaudeProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude
    /// This profile's token, behind its own cache — see `ClaudeKeychain`.
    nonisolated private let keychain: ClaudeKeychain

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    /// Held between refreshes so the keychain is read once per token, not once
    /// per minute — a keychain read can put a prompt in front of the user.
    private var credentials: ClaudeCredentials?
    /// When the token runs out, as of the last keychain read — expired or not.
    ///
    /// Read-only bookkeeping for `ClaudeTokenRefresher`, which has to know how
    /// long is left *before* deciding to do anything. Kept here because this is
    /// already the one place that reads the item, so exposing it costs no extra
    /// keychain traffic and no extra prompt.
    private(set) var tokenExpiry: Date?
    /// Set when the endpoint returns 429. Until it passes, refreshes are
    /// skipped without touching the network — a poll that keeps firing into a
    /// rate limit is how you stay rate limited.
    private var retryNoEarlierThan: Date?
    /// How many 429s in a row. The endpoint answers `Retry-After: 0`, which is
    /// no guidance at all, so the wait doubles each time instead.
    private var consecutiveRateLimits = 0

    private let archive: UsageArchive
    /// How this profile's token is obtained. Injected for the same reason
    /// `session` is: the token path had no tests, which is how a back-off that
    /// never expired shipped. Production reads through this profile's own
    /// `ClaudeKeychain`; a test substitutes a fake credential source instead.
    private let loadCredentials: @Sendable () throws -> ClaudeCredentials

    /// How the CLI is asked, or nil where Claude Code is not installed. Nil is
    /// resolved once at init rather than per refresh: the answer only changes
    /// when someone installs or removes Claude Code, and the app is relaunched
    /// either way.
    nonisolated private let cli: ClaudeUsageCLI?
    /// Claude Desktop's cache, or nil to leave that source out. Nil in tests
    /// about the other two: left in, whichever cache the developer's own Desktop
    /// happens to hold would decide whether they pass.
    nonisolated private let desktopCache: ClaudeDesktopUsageCache?
    /// How recent a Desktop snapshot has to be to stand in for a live reading.
    ///
    /// Thirty minutes, from watching a real cache: while Claude Desktop is open it
    /// rewrites this entry every five to fifteen minutes, with the occasional
    /// half-hour gap when it is left in the background. So thirty minutes rides
    /// out an ordinary gap without ever presenting a number that could be far
    /// wrong — the session window moved eleven points in fifteen minutes on the
    /// day this was measured, which is why it is not an hour.
    ///
    /// Past it the source simply drops through, and `UsageStore` does the rest: it
    /// re-shows the last good reading, undimmed for its own fifteen minutes and
    /// dimmed and dated after that. Nothing here has to re-implement any of it.
    private let desktopFreshness: TimeInterval
    /// Stamped whenever a Desktop read came up short. Without it, a machine with
    /// no Claude Desktop — or one whose Desktop has gone quiet — pays for a scan
    /// of a few thousand directory entries on every 60s tick, forever. The same
    /// reason `lastCLIAttempt` exists. A working source never sees this: every
    /// successful read scans (the scan is cheap and always accurate; see
    /// `ClaudeDesktopUsageCache.read`), and only a miss ever sets it.
    private var lastDesktopMiss: Date?
    /// How long a miss suppresses the next scan.
    private let desktopRescanInterval: TimeInterval

    /// A subprocess is far more expensive than an HTTP call, and `UsageStore`
    /// polls every 60s while a session is busy. The windows barely move in a
    /// minute, so the last answer is reused in between.
    private let cliRefreshInterval: TimeInterval
    private var lastCLIWindows: (windows: [LimitWindow], at: Date)?
    /// The named tier the last `/usage` print named, if it named one.
    private var lastCLIPlan: String?
    /// Stamped on every spawn, successful or not. Without it a Claude Code that
    /// is installed but signed out costs a process on every tick, forever.
    private var lastCLIAttempt: Date?

    init(profile: ClaudeProfile = .default(),
         session: URLSession = .shared,
         archive: UsageArchive = UsageArchive(),
         loadCredentials: (@Sendable () throws -> ClaudeCredentials)? = nil,
         cli: ClaudeUsageCLI? = ClaudeUsageCLI.locate(),
         cliRefreshInterval: TimeInterval = 5 * 60,
         desktopCache: ClaudeDesktopUsageCache? = ClaudeDesktopUsageCache(),
         desktopFreshness: TimeInterval = 30 * 60,
         desktopRescanInterval: TimeInterval = 5 * 60) {
        self.cli = cli
        self.cliRefreshInterval = cliRefreshInterval
        self.desktopCache = desktopCache
        self.desktopFreshness = desktopFreshness
        self.desktopRescanInterval = desktopRescanInterval
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        let keychain = ClaudeKeychain(profile: profile)
        self.keychain = keychain
        self.loadCredentials = loadCredentials ?? { try keychain.load() }
        self.session = session
        self.archive = archive
        // Pick the back-off back up where the last run left it, so relaunching
        // during a penalty does not spend an attempt extending it.
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: profile.id)
    }

    /// How close to expiry a back-off counts as already expired.
    ///
    /// The server hands back a 60s hint and `UsageStore` also ticks every 60s,
    /// so the two run at the same period and the tick lands a few milliseconds
    /// *before* the window opens — `retryAfter: 0.015` in the log. Refusing
    /// that costs far more than the 15ms it saves: the caller is a timer, not a
    /// retry loop, so the next attempt is not a moment later but a whole
    /// refresh interval later. A 60s penalty silently becomes 120s and every
    /// other tick is spent on nothing.
    private let backoffSlack: TimeInterval = 1

    /// Pure, so the resonance this exists to break can be tested without a
    /// timer and a live endpoint.
    nonisolated static func shouldHoldOff(until: Date?, slack: TimeInterval,
                                          now: Date = Date()) -> Bool {
        guard let until else { return false }
        return until.timeIntervalSince(now) > slack
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Ahead of both the CLI and the back-off check. This is the cheapest
        // source and the only one that can never interrupt anyone: it reads a
        // file Claude Desktop has already written.
        if let windows = await desktopWindows() {
            return snapshot(windows: windows)
        }
        // Ahead of the back-off check on purpose. That deadline is the
        // endpoint's, and the CLI does not share the endpoint's rate limit —
        // there is no reason for a 429 on one to darken a ring the other can
        // still fill.
        if let windows = await cliWindows() {
            return snapshot(windows: windows, plan: lastCLIPlan)
        }
        if Self.shouldHoldOff(until: retryNoEarlierThan, slack: backoffSlack),
           let retryNoEarlierThan {
            let remaining = retryNoEarlierThan.timeIntervalSinceNow
            Log.usage.debug("skipping fetch, backing off for \(remaining, format: .fixed(precision: 0))s")
            throw UsageProviderError.rateLimited(retryAfter: remaining)
        }
        do {
            let snapshot = try await fetch(retryingOnUnauthorized: true)
            retryNoEarlierThan = nil
            consecutiveRateLimits = 0
            archive.saveBackoffUntil(nil, providerID: id)
            return snapshot
        } catch UsageProviderError.needsAuth {
            // The held copy goes, so the next tick re-reads. Backing off is
            // `CredentialCache`'s job and it already does it correctly: it
            // waits on the item's modification date rather than on a clock, so
            // a token Claude Code has just rotated is picked up at once. A
            // second timer here could only ever be wrong — and was: it stamped
            // itself on every failed tick, so its own window never expired and
            // the keychain was never read again.
            credentials = nil
            throw UsageProviderError.needsAuth
        } catch UsageProviderError.credentialExpired {
            credentials = nil
            throw UsageProviderError.credentialExpired
        } catch let error as UsageProviderError {
            if case .rateLimited(let retryAfter) = error {
                consecutiveRateLimits += 1
                retryNoEarlierThan = Date().addingTimeInterval(retryAfter)
                archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
                Log.usage.notice("rate limited (\(self.consecutiveRateLimits)x), next attempt in \(retryAfter, format: .fixed(precision: 0))s")
            }
            throw error
        }
    }

    /// The snapshot shape every source produces. One place, so a window order or
    /// a headline changed for the endpoint cannot quietly differ from the CLI's or
    /// Desktop's — the three are the same reading taken from three places.
    private func snapshot(windows: [LimitWindow], plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "session",
            // #102's second ring. The helper is the only place a Claude
            // snapshot is built now, so this is the only place it can go.
            weeklyID: "weekly_all",
            plan: plan?.nonEmptyPlan
        )
    }

    /// What Claude Desktop's cache holds for *this* profile's account, or nil.
    ///
    /// Deliberately cannot throw, for the reason `cliWindows` cannot: every way
    /// this can come up empty — Desktop not installed, closed, signed into
    /// another account, a snapshot too old to call live, a format that has moved
    /// on — is a reason to ask the next source, not a reason to fail the refresh
    /// and put an invented status on the ring.
    ///
    /// A snapshot past `desktopFreshness` is *not* returned. That is what keeps
    /// the ring honest without any new state: dropping through leaves the last
    /// good reading to `UsageStore`, which already re-shows it with the age it
    /// actually has and dims it — where returning it here would present numbers
    /// from an hour ago as a live `.ok`.
    private func desktopWindows() async -> [LimitWindow]? {
        guard let desktopCache else { return nil }
        let now = Date()
        // A recent miss means the next read would be a full scan for something
        // that was not there a moment ago. Wait it out.
        if let lastDesktopMiss, now.timeIntervalSince(lastDesktopMiss) < desktopRescanInterval {
            return nil
        }
        // Read per refresh rather than held: switching account in Claude Code
        // rewrites this, and a held copy would keep matching the old
        // organization's cache entry.
        guard let organization = profile.organizationID() else {
            lastDesktopMiss = now
            return nil
        }

        // Off the actor, exactly as the CLI read is. The scan stats a few
        // thousand directory entries, and the actor's other work — the token path
        // this falls through to — has no business queueing behind that.
        let reading = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: desktopCache.read(organization: organization))
            }
        }
        guard let reading else {
            lastDesktopMiss = now
            return nil
        }

        guard reading.isFresh(at: now, within: desktopFreshness) else {
            lastDesktopMiss = now
            Log.usage.debug("\(self.id, privacy: .public): claude desktop snapshot is too old to show as live")
            return nil
        }
        lastDesktopMiss = nil
        Log.usage.debug("\(self.id, privacy: .public): read \(reading.windows.count) windows from the claude desktop cache entry \(reading.entry.lastPathComponent, privacy: .public)")
        return reading.windows
    }

    /// What `claude "/usage"` last said, or nil to mean "use the token path".
    ///
    /// Deliberately cannot throw. Every way the CLI can fail — not installed,
    /// signed out, wording changed, wedged and killed — is a reason to ask the
    /// endpoint instead, not a reason to fail the refresh. The endpoint's
    /// errors are also the ones `UsageStore` knows how to word, and a status
    /// invented here would be a second vocabulary saying the same things.
    private func cliWindows() async -> [LimitWindow]? {
        guard let cli else { return nil }
        let now = Date()

        // A cached answer is only reused inside the interval. Past it the
        // reading is stale, and handing it back as `.ok` would be claiming a
        // freshness it does not have.
        if let last = lastCLIWindows, now.timeIntervalSince(last.at) < cliRefreshInterval {
            return last.windows
        }
        if let lastCLIAttempt, now.timeIntervalSince(lastCLIAttempt) < cliRefreshInterval {
            return nil
        }
        lastCLIAttempt = now

        do {
            let reading = try await cli.readWithPlan(profile: profile, now: now)
            lastCLIWindows = (reading.windows, now)
            lastCLIPlan = reading.plan
            Log.usage.debug("\(self.id, privacy: .public): read \(reading.windows.count) windows from claude /usage")
            return reading.windows
        } catch {
            Log.usage.debug("\(self.id, privacy: .public): claude /usage did not answer, falling back to the token")
            return nil
        }
    }

    private func fetch(retryingOnUnauthorized: Bool) async throws -> ProviderSnapshot {
        let token = try currentToken()

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        Log.usage.debug("GET /api/oauth/usage")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("usage endpoint answered \(status)")

        if status == 401 || status == 403 {
            // Rejected but unexpired: the held copy is wrong, which is what
            // signing into a different account looks like from here.
            keychain.forgetCached()
            // The cached token went stale mid-flight; re-read once in case
            // Claude Code has refreshed it since.
            credentials = nil
            if retryingOnUnauthorized {
                return try await fetch(retryingOnUnauthorized: false)
            }
            throw UsageProviderError.needsAuth
        }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: Self.backoff(
                    forAttempt: consecutiveRateLimits,
                    retryAfter: Self.retryAfter(from: response)
                )
            )
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let payload = try UsageResponse.decoder.decode(UsageResponse.self, from: data)
        return snapshot(windows: payload.limitWindows(), plan: credentials?.subscriptionType)
    }

    private func currentToken() throws -> String {
        if let credentials, !credentials.isExpired {
            return credentials.accessToken
        }
        // No local back-off lock here — `CredentialCache`, behind `keychain`,
        // already does this correctly: it waits on the item's modification
        // date rather than on a clock, so a token Claude Code has just
        // rotated is picked up at once. A second timer here could only ever
        // be wrong, and was — it stamped itself on every failed tick, so its
        // own window never expired and the keychain was never read again.
        let fresh = try loadCredentials()
        Log.usage.debug("\(self.id, privacy: .public): read keychain token, expires \(fresh.expiresAt, privacy: .public)")
        tokenExpiry = fresh.expiresAt
        // Expired is not signed out. Claude Code rotates this token whenever it
        // runs, and this app deliberately does not — minting one would mean
        // writing a credential it does not own, and racing the owner for it. So
        // after a machine restart the token is usually stale until Claude Code
        // is next used, and the honest thing is to keep showing the last reading
        // with its age rather than demand a sign-in that is not needed.
        guard !fresh.isExpired else { throw UsageProviderError.credentialExpired }
        credentials = fresh
        return fresh.accessToken
    }

    /// How long to wait after a 429.
    ///
    /// The server's own hint is honoured only as a *floor-raiser*: it answers
    /// `Retry-After: 0`, and obeying that literally means retrying immediately,
    /// which is what keeps you rate limited. So the wait starts at a minute and
    /// doubles for each 429 in a row, capped so it always recovers on its own.
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 15 * 60
        let doubled = floor * pow(2, Double(min(attempt, 4)))
        return min(ceiling, max(doubled, retryAfter ?? 0))
    }

    /// `Retry-After` is either a number of seconds or an HTTP date.
    static func retryAfter(from response: URLResponse?) -> TimeInterval? {
        guard let header = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }

        if let seconds = TimeInterval(header) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    nonisolated var signInCommand: String? { profile.signInCommand }

    nonisolated var signInRoute: SignInRoute {
        // Names the command for a profile, because that is the only way to
        // reach it: plain `claude` signs the default one in, not this.
        .guidance(L10n.t("Run `\(profile.signInCommand)` once. It signs in and is what these readings come from. Use /login there to change account."))
    }

    /// Reached only from "Allow access…", so this is the one path allowed to
    /// raise the keychain dialogue — see `ClaudeKeychain.askAgain`.
    nonisolated func forgetCachedCredential() { keychain.askAgain() }

    /// Read the keychain again, ignoring anything held, and report the expiry.
    ///
    /// The after-check for `ClaudeTokenRefresher`, and the only caller that
    /// should want it: everything else is served from the cache precisely so
    /// that the keychain — and its prompt — is touched as rarely as possible.
    func reloadTokenExpiry() -> Date? {
        keychain.forgetCached()
        credentials = nil
        guard let fresh = try? loadCredentials() else { return nil }
        tokenExpiry = fresh.expiresAt
        return fresh.expiresAt
    }

    nonisolated func account() -> ProviderAccount? {
        let manageURL = URL(string: "https://claude.ai/settings/usage")

        // Settings must not be the thing that raises a keychain prompt. Where
        // the CLI can answer, the readings never touch the token, and opening
        // Settings to see whose account a ring is for would have been the one
        // thing that did — the exact interruption this provider now avoids.
        //
        // The trade is the plan name for the address, and the address is the
        // more useful half: it says *which* account, which is the only question
        // two Claude rings ever raise, and the token could never answer it.
        if cli != nil {
            guard let address = profile.signedInAddress() else { return nil }
            return ProviderAccount(
                label: address,
                plan: nil,   // Claude Code's own config does not name the plan
                source: profile.sourceName,
                manageURL: manageURL
            )
        }

        // Through the injected source, not `keychain` directly. In production
        // the source *is* `keychain.load()` — the default set in `init` — so
        // nothing about how this reads, caches or prompts changes. What it buys
        // is that a test can build a real provider without the call reaching
        // the login keychain: it used to, and a test host rebuilt with a fresh
        // ad-hoc signature would sit behind an authorization prompt nobody was
        // there to answer, hanging the whole suite on `providerSummaries`.
        guard let credentials = try? loadCredentials() else { return nil }
        return ProviderAccount(
            label: profile.signedInAddress(),
            plan: credentials.subscriptionType,
            source: profile.sourceName,
            manageURL: manageURL
        )
    }
}

/// The shape of `GET /api/oauth/usage`.
struct UsageResponse: Decodable {
    struct Limit: Decodable {
        let kind: String
        let percent: Double
        let resetsAt: Date?
        /// What the window is scoped to, where it is scoped to anything.
        ///
        /// The model-specific weekly window comes back as `weekly_scoped` for
        /// *every* model, so the kind alone can only ever say "Scoped". The
        /// model it actually meters is named here and nowhere else — which is
        /// also why this is read rather than the model being hardcoded: the
        /// window follows whichever model the plan scopes, and has already been
        /// Opus once.
        let scope: Scope?

        /// The window's own name: the model where the response names one, the
        /// kind's own wording otherwise.
        var windowLabel: String {
            let named = scope?.model?.displayName?.trimmingCharacters(in: .whitespaces)
            if let named, !named.isEmpty { return named }
            return UsageResponse.label(forKind: kind)
        }

        private enum CodingKeys: String, CodingKey {
            case kind, percent, resetsAt, scope
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            percent = try container.decode(Double.self, forKey: .percent)
            resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
            // Tolerated rather than required. Everything above is the reading
            // itself and must decode; the scope is only a nicer name for it, so
            // a shape change here falls back to the kind's wording instead of
            // costing the whole response.
            scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
        }
    }

    struct Scope: Decodable {
        struct Model: Decodable { let displayName: String? }
        let model: Model?
    }
    struct Window: Decodable {
        let utilization: Double
        let resetsAt: Date?
    }

    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?

    /// How this response is read, wherever it is read from.
    ///
    /// Shared rather than one per source: the endpoint and Claude Desktop's cache
    /// carry the *same* response, so two decoders would be two chances for one of
    /// them to drift and silently start dropping windows.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Timestamps come back with fractional seconds and an offset, which
        // `.iso8601` alone will not parse.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unparseable date \(text)")
            )
        }
        return decoder
    }()

    /// `limits` is the forward-compatible shape — it grows new kinds as
    /// Anthropic adds them — so it is preferred, with the two named windows as
    /// a fallback for older responses.
    func limitWindows() -> [LimitWindow] {
        var windows = (limits ?? []).compactMap { limit -> LimitWindow? in
            guard let resetsAt = limit.resetsAt else { return nil }
            return LimitWindow(
                id: limit.kind,
                label: limit.windowLabel,
                usedFraction: limit.percent / 100,
                resetsAt: resetsAt,
                duration: Self.duration(forKind: limit.kind)
            )
        }

        // The named windows are merged in rather than used only as a fallback.
        // Claude Code's own schema says an entry is "present only while the API
        // reports it and its resets_at has not passed", so a window that has
        // just rolled over disappears from `limits` while `five_hour` still
        // carries it. Relying on the array alone loses the session exactly when
        // it resets, which is when someone is most likely to be looking.
        func merge(_ window: UsageResponse.Window?, id: String, label: String) {
            guard let window, let resetsAt = window.resetsAt,
                  !windows.contains(where: { $0.id == id })
            else { return }
            windows.append(LimitWindow(id: id, label: label,
                                       usedFraction: window.utilization / 100,
                                       resetsAt: resetsAt, duration: Self.duration(forKind: id)))
        }
        merge(fiveHour, id: "session", label: L10n.t("Current session"))
        merge(sevenDay, id: "weekly_all", label: L10n.t("All models"))

        return windows.sorted(by: UsageResponse.displayOrder)
    }

    static func duration(forKind kind: String) -> TimeInterval? {
        if kind == "session" { return 5 * 3600 }
        if kind.hasPrefix("weekly_") { return 7 * 86400 }
        return nil
    }

    /// The frame's wording, for the kinds it drew.
    static func label(forKind kind: String) -> String {
        switch kind {
        case "session":       return L10n.t("Current session")
        case "weekly_all":    return L10n.t("All models")
        case "weekly_opus":   return L10n.t("Opus")
        case "weekly_sonnet": return L10n.t("Sonnet")
        // Only reached when the response names no model for the window, which
        // is the one case where there is nothing better to call it.
        case "weekly_scoped", "scoped": return L10n.t("Scoped")
        default:
            return kind
                .replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Session first, then the weekly windows — the order the frame shows.
    /// Shared with `ClaudeUsageCLI`, which reads the same windows off the CLI
    /// and must hand them over in the same order.
    static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            if id == "session" { return 0 }
            if id == "weekly_all" { return 1 }
            return 2
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }
}
