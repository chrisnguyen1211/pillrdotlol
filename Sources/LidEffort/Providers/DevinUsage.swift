import Foundation

/// Parses the quota in Devin's GetUserStatus response.
///
/// The response nests the plan under `userStatus.planStatus`; it is not the
/// cached plan-info JSON from Devin Desktop's local database.
///
/// - Percentages are remaining allowance, not usage, and may be fractional.
/// - Protobuf JSON encodes 64-bit reset timestamps and balances as strings.
///   Numeric representations are accepted too.
///
/// Reset timestamps are kept exactly as reported by the service. A timestamp
/// in the past is not permission to invent a new cycle with the old usage.
///
/// The service drops `*QuotaRemainingPercent` when it hits 0 (fully used),
/// leaving the reset timestamp as the signal the quota is still metered. A
/// missing percent with a reset is therefore 0% remaining, not "not metered";
/// only when both are absent is there no reading to fabricate.
enum DevinUsage {
    static var dailyLabel: String { L10n.t("Daily quota") }
    static var weeklyLabel: String { L10n.t("Weekly quota") }
    static var overageLabel: String { L10n.t("Extra usage balance") }
    static var usageGroup: String { L10n.t("Usage") }
    static var extraGroup: String { L10n.t("Extra usage") }

    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let user = root["userStatus"] as? [String: Any],
              let plan = user["planStatus"] as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        var windows: [LimitWindow] = []
        for (id, label) in [("daily", dailyLabel), ("weekly", weeklyLabel)] {
            let hidden = id == "daily" ? "hideDailyQuota" : "hideWeeklyQuota"
            guard plan[hidden] as? Bool != true else { continue }
            let reset = number(plan["\(id)QuotaResetAtUnix"])
                .flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            // The service omits *QuotaRemainingPercent at 0; a reset timestamp
            // without it means fully used, not unmetered.
            let remaining: Double
            if let r = number(plan["\(id)QuotaRemainingPercent"]), (0...100).contains(r) {
                remaining = r
            } else if reset != nil {
                remaining = 0
            } else {
                continue
            }
            windows.append(LimitWindow(id: id, group: usageGroup, label: label,
                                       usedFraction: (100 - remaining) / 100, resetsAt: reset))
        }
        // Overage is appended before the empty guard so a response that reports
        // only an overage balance is still a valid reading, not a bad response.
        if let micros = number(plan["overageBalanceMicros"]), micros >= 0,
           let cents = Int(exactly: (micros / 10_000).rounded()) {
            let formatted = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                                   Double(cents) / 100)
            windows.append(LimitWindow(id: "overage", group: extraGroup, label: overageLabel,
                                       used: cents, usedText: L10n.t("$\(formatted)")))
        }
        guard !windows.isEmpty else { throw UsageProviderError.badResponse(status: 0) }
        return windows
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else {
            result = (value as? String).flatMap(Double.init)
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}
