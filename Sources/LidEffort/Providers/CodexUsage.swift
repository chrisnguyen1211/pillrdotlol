import Foundation

/// Account-wide Codex activity returned by the Codex profile endpoint.
///
/// `/wham/profiles/me` reports token totals in daily buckets and account-level
/// summary statistics.
struct CodexTokenUsage: Codable, Equatable, Sendable {
    struct Summary: Codable, Equatable, Sendable {
        let lifetimeTokens: Int?
        let peakDailyTokens: Int?
        let longestRunningTurnSeconds: Double?
        let currentStreakDays: Int?
        let longestStreakDays: Int?

        init(lifetimeTokens: Int? = nil,
             peakDailyTokens: Int? = nil,
             longestRunningTurnSeconds: Double? = nil,
             currentStreakDays: Int? = nil,
             longestStreakDays: Int? = nil) {
            self.lifetimeTokens = lifetimeTokens
            self.peakDailyTokens = peakDailyTokens
            self.longestRunningTurnSeconds = longestRunningTurnSeconds
            self.currentStreakDays = currentStreakDays
            self.longestStreakDays = longestStreakDays
        }
    }

    struct DailyBucket: Codable, Equatable, Identifiable, Sendable {
        let startDate: String
        let tokens: Int

        var id: String { startDate }

        init(startDate: String, tokens: Int) {
            self.startDate = startDate
            self.tokens = tokens
        }
    }

    let summary: Summary?
    let dailyUsageBuckets: [DailyBucket]

    init(summary: Summary? = nil,
         dailyUsageBuckets: [DailyBucket] = []) {
        self.summary = summary
        self.dailyUsageBuckets = dailyUsageBuckets
    }

    /// The consecutive calendar days represented by the card's chart.
    func last30Days(now: Date = Date(), calendar: Calendar = .current) -> [DailyBucket] {
        let today = calendar.startOfDay(for: now)
        var values: [String: DailyBucket] = [:]
        for bucket in dailyUsageBuckets {
            values[bucket.startDate] = bucket
        }

        return (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 29, to: today)
            else { return nil }
            let key = Self.dayKey(for: date, calendar: calendar)
            return values[key] ?? DailyBucket(startDate: key, tokens: 0)
        }
    }

    func usageInLast30Days(now: Date = Date(), calendar: Calendar = .current) -> Int {
        last30Days(now: now, calendar: calendar).reduce(0) { $0 + $1.tokens }
    }

    /// A missing current-day bucket means the server has not published today's
    /// usage yet. A present zero is a real zero, not a pending value.
    func usageToday(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let key = Self.dayKey(for: calendar.startOfDay(for: now), calendar: calendar)
        return dailyUsageBuckets.first(where: { $0.startDate == key })?.tokens
    }

    var peakDailyTokens: Int? {
        summary?.peakDailyTokens ?? dailyUsageBuckets.map(\.tokens).max()
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// Unused rate-limit resets on the Codex account.
///
/// The ChatGPT backend lists credits that can still reset a rate limit, under
/// the same credential as `/wham/usage`.
struct CodexResetCredits: Equatable, Sendable {
    struct Credit: Equatable, Sendable, Identifiable {
        let id: String
        let status: String
        let expiresAt: Date?

        init(id: String, status: String, expiresAt: Date? = nil) {
            self.id = id
            self.status = status
            self.expiresAt = expiresAt
        }
    }

    let availableCount: Int
    let credits: [Credit]

    init(availableCount: Int, credits: [Credit] = []) {
        self.availableCount = availableCount
        self.credits = credits
    }

    /// Credits still available, soonest expiry first.
    var available: [Credit] {
        credits.filter { $0.status == "available" }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    var nextExpiry: Date? { available.compactMap(\.expiresAt).min() }
}

/// Only the account's main rate-limit windows belong in the usage rings —
/// `additional_rate_limits` and `code_review_rate_limit` meter something else
/// and are deliberately left out.
enum CodexUsage {
    private struct Response: Decodable {
        let rate_limit: RateLimit?
        let plan_type: String?
    }

    private struct ProfileUsageResponse: Decodable {
        let stats: ProfileStats?
    }

    private struct ProfileStats: Decodable {
        let lifetime_tokens: Int?
        let peak_daily_tokens: Int?
        let longest_running_turn_sec: Double?
        let current_streak_days: Int?
        let longest_streak_days: Int?
        let daily_usage_buckets: [ProfileDailyBucket]?
    }

    private struct ProfileDailyBucket: Decodable {
        let start_date: String
        let tokens: Int
    }

    private struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }

    private struct Window: Decodable {
        let limit_window_seconds: Double?
        let used_percent: Double?
        let reset_at: Double?
        let reset_after_seconds: Double?
    }

    private struct ResetCreditsResponse: Decodable {
        let credits: [ResetCredit]
        let availableCount: Int?

        private enum CodingKeys: String, CodingKey {
            case credits
            case available_count
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try? container.decode(Int.self, forKey: .available_count)
            // One unreadable credit must not discard the rest of a valid list.
            let items = (try? container.decode([FailableResetCredit].self, forKey: .credits)) ?? []
            credits = items.compactMap(\.value)
        }
    }

    private struct FailableResetCredit: Decodable {
        let value: ResetCredit?
        init(from decoder: Decoder) throws {
            value = try? ResetCredit(from: decoder)
        }
    }

    private struct ResetCredit: Decodable {
        let id: String
        let status: String
        let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case status
            case expires_at
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
            if let text = try? container.decode(String.self, forKey: .expires_at) {
                expiresAt = parseISO8601(text)
            } else {
                expiresAt = nil
            }
        }
    }

    static func windows(from data: Data, now: Date = Date()) throws -> [LimitWindow] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }

        var windows: [LimitWindow] = []
        for (id, window) in [("primary", response.rate_limit?.primary_window),
                             ("secondary", response.rate_limit?.secondary_window)] {
            guard let window else { continue }
            // One malformed window must not discard the other: a null
            // `used_percent` on the 5h window once threw the whole fetch away,
            // hiding a perfectly good weekly window behind an error.
            guard let percent = window.used_percent else { continue }
            let resetsAt = window.reset_at.map { Date(timeIntervalSince1970: $0) }
                ?? window.reset_after_seconds.map { now.addingTimeInterval($0) }
            windows.append(LimitWindow(
                id: id,
                label: label(windowSeconds: window.limit_window_seconds ?? 0, fallback: id),
                usedFraction: percent / 100,
                resetsAt: resetsAt,
                duration: window.limit_window_seconds
            ))
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(L10n.t("Codex reported no usage windows"))
        }
        return windows
    }

    /// The account tier the usage payload names, when it names one.
    static func plan(from data: Data) -> String? {
        (try? JSONDecoder().decode(Response.self, from: data))?.plan_type?.nonEmptyPlan
    }

    /// Decode the profile endpoint's token statistics.
    static func profileUsage(from data: Data) throws -> CodexTokenUsage {
        do {
            let response = try JSONDecoder().decode(ProfileUsageResponse.self, from: data)
            let stats = response.stats
            return CodexTokenUsage(
                summary: stats.map {
                    .init(lifetimeTokens: $0.lifetime_tokens,
                          peakDailyTokens: $0.peak_daily_tokens,
                          longestRunningTurnSeconds: $0.longest_running_turn_sec,
                          currentStreakDays: $0.current_streak_days,
                          longestStreakDays: $0.longest_streak_days)
                },
                dailyUsageBuckets: stats?.daily_usage_buckets?.map {
                    .init(startDate: $0.start_date, tokens: $0.tokens)
                } ?? []
            )
        } catch let error as UsageProviderError {
            throw error
        } catch {
            throw UsageProviderError.badResponse(status: 0)
        }
    }

    /// Decode the ChatGPT backend list of unused rate-limit resets.
    ///
    /// Same credential as `/wham/usage`. `available_count` is trusted even when
    /// the `credits` array is truncated. Throws only when the body is not JSON
    /// at all, so an unfamiliar payload cannot fail the usage fetch.
    static func resetCredits(from data: Data) throws -> CodexResetCredits {
        let response: ResetCreditsResponse
        do {
            response = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
        } catch {
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return CodexResetCredits(availableCount: 0, credits: [])
            }
            throw UsageProviderError.badResponse(status: 0)
        }

        let credits = response.credits.map {
            CodexResetCredits.Credit(id: $0.id, status: $0.status, expiresAt: $0.expiresAt)
        }
        let availableCount = response.availableCount
            ?? credits.filter { $0.status == "available" }.count
        return CodexResetCredits(availableCount: availableCount, credits: credits)
    }

    /// The backend mixes whole-second and fractional ISO-8601 stamps; each
    /// formatter rejects the other form.
    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// The plan an account is on decides what its primary window actually is
    /// — a free plan has shown a 30-day window here, not the 5-hour one a paid
    /// plan reports — so the label is derived from the length Codex actually
    /// sent rather than assumed from a fixed pair of durations. Getting this
    /// wrong doesn't mislabel the window, it drops it: an unrecognised length
    /// used to be silently skipped, which on a free account left both windows
    /// absent and the ring reporting nothing metered at all.
    static func label(windowSeconds: Double, fallback: String) -> String {
        guard windowSeconds > 0 else {
            return fallback == "primary" ? L10n.t("Current session") : L10n.t("Longer window")
        }
        let minutes = windowSeconds / 60
        if minutes < 60 { return L10n.t("\(Int(minutes))m limit") }
        if minutes < 60 * 24 { return L10n.t("\(Int(minutes / 60))h limit") }
        let days = Int((minutes / (60 * 24)).rounded())
        switch days {
        case 7:  return L10n.t("Weekly limit")
        case 30: return L10n.t("Monthly limit")
        default: return L10n.t("\(days)d limit")
        }
    }
}
