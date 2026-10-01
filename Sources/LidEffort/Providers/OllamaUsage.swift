import Foundation

/// Parses Ollama's `GET /api/usage` response.
///
/// **Modern plans** (Pro 20/60/100/500) return a single monthly window:
///
/// ```json
/// { "activity": {
///     "cost": "0.00000",
///     "period": { "type": "last_4_weeks",
///                 "starting_at": "2026-08-17T00:00:00Z",
///                 "ending_at": "2026-09-08T08:28:05Z" } },
///   "limits": {
///     "monthly": {
///       "usage": 0.152,
///       "models": [ { "name": "glm-5.3", "request_count": 468 }, ... ] } } }
/// ```
///
/// `usage` is a **fraction of the plan's monthly allowance** — 0.152 means
/// 15.2% — not dollars. The plan tier (20/60/100/500) sets the dollar ceiling,
/// but the fraction is the same number the ring needs regardless of tier.
///
/// **Legacy plans** return `session` and `weekly` windows instead:
///
/// ```json
/// { "limits": {
///     "session": { "usage": 0.12, "models": [...] },
///     "weekly":  { "usage": 0.41, "models": [...] } },
///   "activity": { "cost": "0.10", "period": { "type": "last_4_weeks" } } }
/// ```
///
/// Legacy responses carry no `ending_at`, so their reset date is unknown.
enum OllamaUsage {
    /// The parsed result: the windows to show and which one the ring means.
    struct Result {
        let windows: [LimitWindow]
        let headlineID: String?
    }

    static func parse(_ json: String) throws -> Result {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let limits = root["limits"] as? [String: Any] ?? [:]
        let activity = root["activity"] as? [String: Any] ?? [:]
        let period = activity["period"] as? [String: Any] ?? [:]
        // The API exposes only a rolling 4-week activity window
        // (`period.starting_at` = 4 weeks ago, `period.ending_at` = now). It does
        // not expose the billing cycle start or reset date, so the window
        // carries no `resetsAt` — showing one would be a guess.

        var windows: [LimitWindow] = []
        var headlineID: String?

        // Modern: a single monthly window with a usage fraction.
        if let monthly = limits["monthly"] as? [String: Any] {
            if let usage = monthly["usage"] as? Double, usage > 0 {
                windows.append(LimitWindow(
                    id: "monthly", label: L10n.t("Monthly usage"),
                    usedFraction: usage, resetsAt: nil
                ))
                headlineID = "monthly"
            }
            windows.append(contentsOf: models(from: monthly, prefix: "monthly"))
        }

        // Legacy: session and weekly windows, each with its own fraction.
        if let session = limits["session"] as? [String: Any] {
            if let usage = session["usage"] as? Double, usage > 0 {
                windows.append(LimitWindow(
                    id: "session", label: L10n.t("Session usage"),
                    usedFraction: usage, resetsAt: nil
                ))
                if headlineID == nil { headlineID = "session" }
            }
            windows.append(contentsOf: models(from: session, prefix: "session"))
        }

        if let weekly = limits["weekly"] as? [String: Any] {
            if let usage = weekly["usage"] as? Double, usage > 0 {
                windows.append(LimitWindow(
                    id: "weekly", label: L10n.t("Weekly usage"),
                    usedFraction: usage, resetsAt: nil
                ))
                // Weekly is the better headline than session for legacy plans.
                headlineID = "weekly"
            }
            windows.append(contentsOf: models(from: weekly, prefix: "weekly"))
        }

        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered(
                L10n.t("No Ollama usage recorded yet for this period.")
            )
        }

        return Result(windows: windows, headlineID: headlineID)
    }

    /// Per-model request counts as individual windows, so each model gets its
    /// own row in the tooltip. Returns an empty array when there are no models
    /// or all have zero requests.
    private static func models(
        from limit: [String: Any], prefix: String
    ) -> [LimitWindow] {
        guard let models = limit["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let name = model["name"] as? String,
                  let count = model["request_count"] as? Int, count > 0
            else { return nil }
            return LimitWindow(
                id: "\(prefix).\(name)", label: name,
                used: count, resetsAt: nil
            )
        }
    }
}
