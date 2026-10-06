import Foundation

/// What the card says when a limit comes back.
///
/// A reset is good news, and the card used to announce it the way a receipt
/// does — "Claude Reset / 5-hour limit refreshed". These are the lines it
/// says instead. One is picked per event, and the pick is a function of the
/// event rather than of the draw, so a card that redraws while it is up
/// keeps saying the same thing, and the next reset says something else.
enum ResetCheer {
    struct Line: Equatable {
        let title: String
        let subtitle: String
    }

    /// The line for this reset.
    static func line(for event: UsageAlertEvent) -> Line {
        let all = lines(provider: event.providerName, window: event.windowLabel)
        return all[index(for: event, count: all.count)]
    }

    /// Which of the lines an event gets. Seeded from the reset time and the
    /// provider, not from `hashValue`: Swift's hashing is salted per process,
    /// which would be stable enough for one card but is not something a test
    /// can pin.
    ///
    /// The seed is mixed before it is reduced. Reset times come on a fixed
    /// cadence — Claude's every five hours — and a plain modulo of the
    /// timestamp walks that cadence through only a couple of the lines.
    static func index(for event: UsageAlertEvent, count: Int) -> Int {
        let stamp = Int64(event.resetsAt?.timeIntervalSince1970 ?? event.previousFraction * 1000)
        let provider = event.providerID.utf8.reduce(Int64(0)) { $0 &* 31 &+ Int64($1) }
        return mix(stamp / 60, provider, count: count)
    }

    /// Two numbers to one of `count` lines. SplitMix64's finaliser: cheap,
    /// deterministic, and every input bit reaches every output bit, which
    /// is all that is asked of it — shared with the other cheers so they
    /// all pick the same way.
    static func mix(_ a: Int64, _ b: Int64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var x = UInt64(bitPattern: a) &+ UInt64(bitPattern: b) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 30; x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x &*= 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Int(x % UInt64(count))
    }

    /// Every line, filled in for one provider and one window, in cycle order.
    static func lines(provider: String, window: String) -> [Line] {
        let limit = limitPhrase(window)
        let mid = midSentence(limit)
        return [
            Line(title: L10n.t("Hurray! \(provider) is back"),
                 subtitle: L10n.t("\(limit) reset — let's build.")),
            Line(title: L10n.t("Fresh window, \(provider)"),
                 subtitle: L10n.t("\(limit) reset. Go ship it.")),
            Line(title: L10n.t("Tank's full again"),
                 subtitle: L10n.t("\(provider)'s \(mid) is reset.")),
            Line(title: L10n.t("Green light from \(provider)"),
                 subtitle: L10n.t("\(limit) reset. Back to work.")),
            Line(title: L10n.t("Reloaded and ready"),
                 subtitle: L10n.t("\(limit) reset. Go, \(provider).")),
            Line(title: L10n.t("Zero percent, all yours"),
                 subtitle: L10n.t("\(provider)'s \(mid) just reset.")),
            Line(title: L10n.t("Clean slate, \(provider)"),
                 subtitle: L10n.t("\(limit) reset — make it count.")),
            Line(title: L10n.t("\(provider) says go"),
                 subtitle: L10n.t("\(limit) reset. Let's build.")),
        ]
    }

    /// "Current session" is what Claude calls its window and "Session limit"
    /// is what a person calls it; any other label is used as the vendor
    /// wrote it — "5-hour limit", "All models limit".
    static func limitPhrase(_ window: String) -> String {
        let lower = window.lowercased()
        if lower.contains("session") { return L10n.t("Session limit") }
        // "Weekly limit" is already a limit — never "Weekly limit limit".
        if lower.contains("limit") || lower.contains("quota") { return window }
        return L10n.t("\(window) limit")
    }

    /// The same phrase after a possessive: "Claude's session limit".
    private static func midSentence(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        // Vendor labels that are names or numbers keep their case — "5-hour",
        // "API usage" — only a capitalised ordinary word is lowered.
        let rest = phrase.dropFirst()
        guard first.isUppercase, rest.first?.isLowercase == true else { return phrase }
        return first.lowercased() + rest
    }
}
