import Foundation

/// Badges for milestones in your own work and spending, bronze, silver and
/// gold, given once and kept. Worked out on this Mac from the ledgers.
enum Achievements {
    enum Tier: Int, CaseIterable, Comparable {
        case bronze = 1, silver, gold
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .bronze: return L10n.t("Bronze")
            case .silver: return L10n.t("Silver")
            case .gold: return L10n.t("Gold")
            }
        }
    }

    enum Area { case productivity, spending }

    /// What the badges are measured on.
    struct Stats: Equatable {
        var hoursTotal: Double = 0
        var hoursBestDay: Double = 0
        var commitsTotal = 0
        var commitsBestDay = 0
        var bestStreak = 0
        var linesTotal = 0
        var parallelHours: Double = 0
        var answered = 0
        var medianAnswer: TimeInterval?
        var finishedTotal = 0
        var earlyHours: Double = 0
        var lateHours: Double = 0
        /// Paid by use this month and today: tokens and keys, in dollars.
        var paidThisMonth: Double = 0
        var paidToday: Double = 0
        var keys = 0
        var plans = 0
        /// This month's cost per finished session, with how many finished.
        var costPerSession: Double?
        var finishedThisMonth = 0
    }

    /// One family of badges: three thresholds on one figure.
    struct Family {
        let id: String
        let area: Area
        let symbol: String
        /// The badge's name at each tier.
        let names: [Tier: String]
        let thresholds: [Tier: Double]
        /// What is measured, said for the tier's threshold.
        let requirement: (Double) -> String
        /// The figure; nil when it can't be told yet.
        let value: (Stats) -> Double?
        /// Lower is better (fast answers, cheap sessions).
        var lowerIsBetter = false

        func reached(_ stats: Stats) -> Tier? {
            guard let value = value(stats) else { return nil }
            return Tier.allCases.reversed().first { tier in
                let bar = thresholds[tier]!
                return lowerIsBetter ? value <= bar : value >= bar
            }
        }
    }

    struct Badge: Identifiable, Equatable {
        let family: String
        let tier: Tier
        var id: String { "\(family).\(tier.rawValue)" }
    }

    static let families: [Family] = [
        Family(id: "hours", area: .productivity, symbol: "clock.fill",
               names: [.bronze: L10n.t("Clocked In"), .silver: L10n.t("Overtime"), .gold: L10n.t("Iron Pair")],
               thresholds: [.bronze: 10, .silver: 100, .gold: 500],
               requirement: { L10n.t("\(Int($0)) hours of agent work in all") }, value: { $0.hoursTotal }),
        Family(id: "dayHours", area: .productivity, symbol: "flame.fill",
               names: [.bronze: L10n.t("Deep Work"), .silver: L10n.t("Marathon"), .gold: L10n.t("Ultra")],
               thresholds: [.bronze: 2, .silver: 5, .gold: 8],
               requirement: { L10n.t("\(Int($0)) hours of agent work in one day") }, value: { $0.hoursBestDay }),
        Family(id: "commits", area: .productivity, symbol: "shippingbox.fill",
               names: [.bronze: L10n.t("Shipper"), .silver: L10n.t("Release Train"), .gold: L10n.t("Ship Machine")],
               thresholds: [.bronze: 50, .silver: 250, .gold: 1000],
               requirement: { L10n.t("\(Int($0)) commits shipped") }, value: { Double($0.commitsTotal) }),
        Family(id: "dayCommits", area: .productivity, symbol: "bolt.fill",
               names: [.bronze: L10n.t("Busy Day"), .silver: L10n.t("Commit Storm"), .gold: L10n.t("Hurricane")],
               thresholds: [.bronze: 5, .silver: 15, .gold: 30],
               requirement: { L10n.t("\(Int($0)) commits in one day") }, value: { Double($0.commitsBestDay) }),
        Family(id: "streak", area: .productivity, symbol: "calendar.badge.checkmark",
               names: [.bronze: L10n.t("On a Roll"), .silver: L10n.t("Week Warrior"), .gold: L10n.t("Unstoppable")],
               thresholds: [.bronze: 3, .silver: 7, .gold: 30],
               requirement: { L10n.t("\(Int($0)) working days in a row") }, value: { Double($0.bestStreak) }),
        Family(id: "lines", area: .productivity, symbol: "text.alignleft",
               names: [.bronze: L10n.t("Line Cook"), .silver: L10n.t("Codesmith"), .gold: L10n.t("Architect")],
               thresholds: [.bronze: 1_000, .silver: 10_000, .gold: 100_000],
               requirement: { L10n.t("\(Int($0)) lines changed") }, value: { Double($0.linesTotal) }),
        Family(id: "parallel", area: .productivity, symbol: "square.stack.3d.up.fill",
               names: [.bronze: L10n.t("Juggler"), .silver: L10n.t("Conductor"), .gold: L10n.t("Orchestra")],
               thresholds: [.bronze: 1, .silver: 10, .gold: 50],
               requirement: { L10n.t("\(Int($0)) hours with two or more agents at once") }, value: { $0.parallelHours }),
        Family(id: "answers", area: .productivity, symbol: "hand.tap.fill",
               names: [.bronze: L10n.t("Quick Draw"), .silver: L10n.t("Fast Hands"), .gold: L10n.t("Reflex")],
               thresholds: [.bronze: 60, .silver: 20, .gold: 8],
               requirement: { L10n.t("Usually answer within \(Int($0)) s, over 20 answers") },
               value: { $0.answered >= 20 ? $0.medianAnswer : nil }, lowerIsBetter: true),
        Family(id: "finished", area: .productivity, symbol: "checkmark.seal.fill",
               names: [.bronze: L10n.t("Closer"), .silver: L10n.t("Finisher"), .gold: L10n.t("Completionist")],
               thresholds: [.bronze: 25, .silver: 100, .gold: 500],
               requirement: { L10n.t("\(Int($0)) sessions finished") }, value: { Double($0.finishedTotal) }),
        Family(id: "early", area: .productivity, symbol: "sunrise.fill",
               names: [.bronze: L10n.t("Early Bird"), .silver: L10n.t("Dawn Patrol"), .gold: L10n.t("Sunrise Crew")],
               thresholds: [.bronze: 1, .silver: 10, .gold: 50],
               requirement: { L10n.t("\(Int($0)) hours of work before 7 in the morning") }, value: { $0.earlyHours }),
        Family(id: "late", area: .productivity, symbol: "moon.stars.fill",
               names: [.bronze: L10n.t("Night Owl"), .silver: L10n.t("Midnight Oil"), .gold: L10n.t("Nocturnal")],
               thresholds: [.bronze: 1, .silver: 10, .gold: 50],
               requirement: { L10n.t("\(Int($0)) hours of work after midnight") }, value: { $0.lateHours }),
        Family(id: "tokenMaxxer", area: .spending, symbol: "flame.circle.fill",
               names: [.bronze: L10n.t("Token Maxxer"), .silver: L10n.t("Token Maxxer"), .gold: L10n.t("Token Maxxer")],
               thresholds: [.bronze: 50, .silver: 200, .gold: 1_000],
               requirement: { L10n.t("$\(Int($0)) paid by use in a month") }, value: { $0.paidThisMonth }),
        Family(id: "bigDay", area: .spending, symbol: "dollarsign.circle.fill",
               names: [.bronze: L10n.t("Big Day"), .silver: L10n.t("High Roller"), .gold: L10n.t("Whale")],
               thresholds: [.bronze: 10, .silver: 50, .gold: 200],
               requirement: { L10n.t("$\(Int($0)) paid by use in one day") }, value: { $0.paidToday }),
        Family(id: "keys", area: .spending, symbol: "key.fill",
               names: [.bronze: L10n.t("Keyring"), .silver: L10n.t("Key Master"), .gold: L10n.t("Vault")],
               thresholds: [.bronze: 3, .silver: 7, .gold: 15],
               requirement: { L10n.t("\(Int($0)) API keys followed") }, value: { Double($0.keys) }),
        Family(id: "plans", area: .spending, symbol: "creditcard.fill",
               names: [.bronze: L10n.t("Multi-Plan"), .silver: L10n.t("Plan Stacker"), .gold: L10n.t("All Access")],
               thresholds: [.bronze: 2, .silver: 3, .gold: 5],
               requirement: { L10n.t("\(Int($0)) paid coding plans") }, value: { Double($0.plans) }),
        Family(id: "thrifty", area: .spending, symbol: "leaf.fill",
               names: [.bronze: L10n.t("Penny Pincher"), .silver: L10n.t("Thrifty"), .gold: L10n.t("Efficiency Expert")],
               thresholds: [.bronze: 2, .silver: 1, .gold: 0.5],
               requirement: { L10n.t("Under $\(String(format: "%.2f", $0)) a finished session for a month, over 20 sessions") },
               value: { $0.finishedThisMonth >= 20 ? $0.costPerSession : nil }, lowerIsBetter: true),
    ]

    static func family(_ id: String) -> Family? { families.first { $0.id == id } }

    /// Every badge the figures reach: each tier up to the one reached.
    static func reached(_ stats: Stats) -> [Badge] {
        families.flatMap { family -> [Badge] in
            guard let top = family.reached(stats) else { return [] }
            return Tier.allCases.filter { $0 <= top }.map { Badge(family: family.id, tier: $0) }
        }
    }

    // MARK: Kept

    static let earnedKey = "achievements.earned"

    /// Badges earned, with when, kept in the defaults.
    static func earned(_ defaults: UserDefaults = .standard) -> [String: Date] {
        (defaults.dictionary(forKey: earnedKey) as? [String: Double])?.mapValues { Date(timeIntervalSince1970: $0) } ?? [:]
    }

    /// Gives every badge the figures reach and isn't held yet; returns the
    /// new ones, best first.
    @discardableResult
    static func award(_ stats: Stats, now: Date = Date(), defaults: UserDefaults = .standard) -> [Badge] {
        var held = (defaults.dictionary(forKey: earnedKey) as? [String: Double]) ?? [:]
        let new = reached(stats).filter { held[$0.id] == nil }
        for badge in new { held[badge.id] = now.timeIntervalSince1970 }
        if !new.isEmpty { defaults.set(held, forKey: earnedKey) }
        return new.sorted { $0.tier > $1.tier }
    }

    static func name(_ badge: Badge) -> String {
        family(badge.family)?.names[badge.tier] ?? badge.family
    }

    static func requirement(_ badge: Badge) -> String {
        guard let family = family(badge.family), let bar = family.thresholds[badge.tier] else { return "" }
        return family.requirement(bar)
    }

    static func note(_ badge: Badge) -> CardNote {
        CardNote(title: L10n.t("Badge unlocked: \(name(badge))"),
                 subtitle: "\(badge.tier.name) · \(requirement(badge))",
                 status: L10n.t("See it in Settings → Dashboard"), good: true)
    }
}

extension Achievements {
    /// The longest run of days, each with a minute or more of agent work.
    static func longestStreak(_ busy: [Date: Double], calendar: Calendar = .current) -> Int {
        let days = Set(busy.filter { $0.value >= 60 }.keys.map { calendar.startOfDay(for: $0) })
        var best = 0
        for day in days where !days.contains(calendar.date(byAdding: .day, value: -1, to: day)!) {
            var length = 1
            var next = calendar.date(byAdding: .day, value: 1, to: day)!
            while days.contains(next) { length += 1; next = calendar.date(byAdding: .day, value: 1, to: next)! }
            best = max(best, length)
        }
        return best
    }

    /// The figures, from everything the activity ledger holds and the
    /// commits git gave; spending passed in, in dollars.
    static func stats(ledger: ActivityLedger, commits: [Date], paidThisMonth: Double, paidToday: Double,
                      keys: Int, plans: Int, costPerSession: Double?, finishedThisMonth: Int,
                      now: Date = Date(), calendar: Calendar = .current) -> Stats {
        let all = ledger.summary(from: Date(timeIntervalSince1970: 0), to: now, now: now, calendar: calendar)
        var stats = Stats()
        stats.hoursTotal = all.busy / 3600
        stats.hoursBestDay = (all.busyByDay.values.max() ?? 0) / 3600
        stats.parallelHours = all.parallel / 3600
        stats.linesTotal = all.added + all.removed
        stats.answered = all.answered
        stats.medianAnswer = all.medianAnswer
        stats.finishedTotal = all.finished
        stats.earlyHours = all.busyByHour[4..<7].reduce(0, +) / 3600
        stats.lateHours = all.busyByHour[0..<4].reduce(0, +) / 3600
        stats.bestStreak = longestStreak(all.busyByDay, calendar: calendar)
        stats.commitsTotal = commits.count
        var perDay: [Date: Int] = [:]
        for time in commits { perDay[calendar.startOfDay(for: time), default: 0] += 1 }
        stats.commitsBestDay = perDay.values.max() ?? 0
        stats.paidThisMonth = paidThisMonth
        stats.paidToday = paidToday
        stats.keys = keys
        stats.plans = plans
        stats.costPerSession = costPerSession
        stats.finishedThisMonth = finishedThisMonth
        return stats
    }
}
