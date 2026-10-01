import Foundation

/// "how long has it been like this" — the second half of answering "is Claude
/// still working".
enum ElapsedCopy {
    /// The same span, phrased as a point in the past.
    static func ago(since: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let elapsed = text(since: since, now: now, locale: locale)
        return elapsed == L10n.t("just now", locale: locale)
            ? elapsed
            : L10n.t("\(elapsed) ago", locale: locale)
    }

    /// A running clock for work in progress: "4.2s", "1m 4.2s", "2h 05m".
    static func clock(since: Date, now: Date = Date()) -> String {
        let total = max(0, now.timeIntervalSince(since))
        let tenths = (total * 10).rounded(.down) / 10
        if tenths < 60 { return String(format: "%.1fs", tenths) }
        if tenths < 3600 {
            let minutes = Int(tenths / 60)
            return String(format: "%dm %.1fs", minutes, tenths - Double(minutes) * 60)
        }
        let hours = Int(tenths / 3600)
        return String(format: "%dh %02dm", hours, Int(tenths - Double(hours) * 3600) / 60)
    }

    static func text(since: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return L10n.t("just now", locale: locale) }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L10n.t("\(max(1, minutes)) min", locale: locale) }

        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return L10n.t("\(hours) hr", locale: locale) }
        return L10n.t("\(hours) hr \(rest) min", locale: locale)
    }
}
