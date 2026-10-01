import Foundation

/// Parses Command Code's `/alpha` billing payload — the same four documents
/// the desktop app's `fetchUsageData` asks for:
///
/// - `GET /alpha/usage/summary` → `{ totalCost, totalCount, … }`
/// - `GET /alpha/billing/credits` → `{ credits: { monthlyCredits }, windowLimits }`
/// - `GET /alpha/billing/subscriptions` → `{ data: { planId, currentPeriodEnd } }`
///
/// The ring is monthly spend over monthly cap (`totalCost + monthlyCredits`).
/// Five-hour and weekly windows ride in the tooltip when the cap is known.
/// A `resetAt` of 0 is absence, not 1970.
enum CommandCodeUsage {
    static let whoami = URL(string: "https://api.commandcode.ai/alpha/whoami")!
    static let credits = URL(string: "https://api.commandcode.ai/alpha/billing/credits")!
    static let subscriptions = URL(string: "https://api.commandcode.ai/alpha/billing/subscriptions")!
    static let summary = URL(string: "https://api.commandcode.ai/alpha/usage/summary")!

    static func windows(summaryJSON: String,
                        creditsJSON: String,
                        subscriptionJSON: String) throws -> [LimitWindow] {
        guard let summary = object(summaryJSON),
              let creditsRoot = object(creditsJSON)
        else { throw UsageProviderError.badResponse(status: 0) }

        let credits = (creditsRoot["credits"] as? [String: Any]) ?? [:]
        let limits = (creditsRoot["windowLimits"] as? [String: Any]) ?? [:]
        let subRoot = object(subscriptionJSON) ?? [:]
        let sub = (subRoot["data"] as? [String: Any]) ?? subRoot
        let periodEnd = date(sub["currentPeriodEnd"])

        let used = number(summary["totalCost"]) ?? 0
        let remaining = number(credits["monthlyCredits"]) ?? 0
        let cap = (used > 0 || remaining > 0) ? used + remaining : 0
        guard cap > 0 else {
            throw UsageProviderError.nothingMetered(L10n.t("Command Code has nothing metered on this account yet"))
        }

        var windows: [LimitWindow] = [
            LimitWindow(
                id: "monthly",
                label: L10n.t("Monthly limit"),
                usedFraction: used / cap,
                resetsAt: periodEnd
            )
        ]

        if let five = window(limits["fiveHour"], id: "fiveHour", label: L10n.t("5h limit")) {
            windows.append(five)
        }
        if let weekly = window(limits["weekly"], id: "weekly", label: L10n.t("Weekly limit")) {
            windows.append(weekly)
        }
        return windows
    }

    static func planName(_ planId: String?) -> String? {
        guard let planId, !planId.isEmpty else { return nil }
        let key = planId.lowercased().replacingOccurrences(of: "-", with: "_")
        if key.contains("goat") { return "GOAT" }
        return planId
    }

    static func orgId(whoamiJSON: String) -> String? {
        guard let root = object(whoamiJSON) else { return nil }
        let org = (root["org"] as? [String: Any]) ?? [:]
        return org["id"] as? String
    }

    private static func window(_ any: Any?, id: String, label: String) -> LimitWindow? {
        guard let entry = any as? [String: Any],
              let cap = number(entry["cap"]), cap > 0
        else { return nil }
        let used = number(entry["used"]) ?? 0
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: used / cap,
            resetsAt: date(entry["resetAt"])
        )
    }

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue
    }

    /// ISO 8601, unix seconds, or unix milliseconds. Zero is "no reset".
    static func date(_ any: Any?) -> Date? {
        if let text = any as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            return ISO8601DateFormatter().date(from: text)
        }
        guard let value = number(any), value > 0 else { return nil }
        var unix = value
        if unix > 1_000_000_000_000 { unix /= 1000 }
        return Date(timeIntervalSince1970: unix)
    }
}
