import SwiftUI
import AppKit

/// What today, this week or this month cost, and how the work went: the
/// agents' estimated spend and every API key's, beside how long the agents
/// worked, how long they waited on you, and what came of it.
@MainActor
final class DashboardModel: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case today, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return L10n.t("Today")
            case .week: return L10n.t("This week")
            case .month: return L10n.t("This month")
            }
        }
        /// The range the dashboard opens on: the last one chosen, else this
        /// month, so commits open on the GitHub-style grid.
        static let rememberedKey = "dashboard.range"
        static var remembered: Range {
            UserDefaults.standard.string(forKey: rememberedKey).flatMap(Range.init(rawValue:)) ?? .month
        }

        /// The local range, for the agents' own records.
        var interval: DateInterval {
            let calendar = Calendar.current
            switch self {
            case .today: return calendar.dateInterval(of: .day, for: Date())!
            case .week: return calendar.dateInterval(of: .weekOfYear, for: Date())!
            case .month: return calendar.dateInterval(of: .month, for: Date())!
            }
        }
        /// The UTC period, for the keys, as providers bill.
        var keyPeriod: SpendLedger.PeriodAmount.Period {
            switch self {
            case .today: return .day
            case .week: return .week
            case .month: return .month
            }
        }
    }

    struct KeyRow: Identifiable {
        let id: String
        let name: String
        let glyph: ProviderGlyph
        let day: SpendLedger.Figure?
        let week: SpendLedger.Figure?
        let month: SpendLedger.Figure?

        func figure(_ period: SpendLedger.PeriodAmount.Period) -> SpendLedger.Figure? {
            switch period {
            case .day: return day
            case .week: return week
            case .month: return month
            }
        }
    }

    @Published var range: Range = .week {
        didSet {
            if !frozen { UserDefaults.standard.set(range.rawValue, forKey: Range.rememberedKey) }
            load()
        }
    }
    @Published private(set) var sessions: [TimelinePane.Row] = []
    @Published private(set) var keys: [KeyRow] = []
    @Published private(set) var plans: [CodingPlans.Row] = []
    /// Commits per local day, for the grid; the last 120 days.
    @Published private(set) var commits: [Date: Int] = [:]
    /// Records broken and nudges given, newest first.
    @Published private(set) var coach: [ActivityLedger.CoachEvent] = []
    /// What was paid by use (tokens and keys) on each of the last seven
    /// local days, and in each hour of today.
    @Published private(set) var paidByDay: [(day: Date, amount: Double)] = []
    @Published private(set) var paidByHour: [Double] = Array(repeating: 0, count: 24)
    /// When each commit was made, for today's hour-by-hour view.
    @Published private(set) var commitTimes: [Date] = []
    /// Agent time per local day, the last 120 days.
    @Published private(set) var busyDays: [Date: TimeInterval] = [:]
    /// Badges held, with when each was earned.
    @Published private(set) var earned: [String: Date] = [:]
    /// The longest run of working days.
    @Published private(set) var bestStreak = 0
    @Published private(set) var activity = ActivityLedger.Summary()
    @Published private(set) var streak = 0
    @Published private(set) var loading = false

    private let extraKeys: () -> [ExtraKey]

    init(extraKeys: @escaping () -> [ExtraKey], range: Range = .week) {
        self.extraKeys = extraKeys
        _range = Published(initialValue: range)
    }

    /// For renders: figures set as they are, nothing loaded.
    private var frozen = false

    static func forRender(range: Range, sessions: [TimelinePane.Row], keys: [KeyRow], plans: [CodingPlans.Row] = [],
                          activity: ActivityLedger.Summary, streak: Int, commits: [Date: Int] = [:],
                          coach: [ActivityLedger.CoachEvent] = [], paidByDay: [(day: Date, amount: Double)] = [],
                          paidByHour: [Double] = Array(repeating: 0, count: 24), commitTimes: [Date] = [],
                          earned: [String: Date] = [:], bestStreak: Int = 0,
                          busyDays: [Date: TimeInterval] = [:]) -> DashboardModel {
        let model = DashboardModel(extraKeys: { [] })
        model.frozen = true
        model.range = range
        model.sessions = sessions
        model.keys = keys
        model.plans = plans
        model.activity = activity
        model.streak = streak
        model.commits = commits
        model.coach = coach
        model.paidByDay = paidByDay
        model.paidByHour = paidByHour
        model.commitTimes = commitTimes
        model.earned = earned
        model.bestStreak = bestStreak
        model.busyDays = busyDays
        return model
    }

    func load() {
        guard !frozen else { return }
        loading = true
        let range = range
        let interval = range.interval
        let keys = extraKeys()
        plans = CodingPlans.rows(snapshots: Costs.latestSnapshots, accounts: CostAccountStore.shared.accounts,
                                 localCurrency: PriceTable.shared.currency)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today)!
        // Sessions for the range, and for the last seven days the chart draws.
        let span = DateInterval(start: min(interval.start, weekAgo), end: max(interval.end, Date()))
        let perToken = Set(CostAccountStore.shared.accounts.filter { $0.billing == .api }.map(\.id))
        let stores = CostModels.all.compactMap(\.store_)
        let paidPlans = plans.filter { ($0.monthly ?? 0) > 0 }.count
        let toLocal: @Sendable (SpendLedger.Figure?) -> Double? = { [currency = PriceTable.shared.currency,
                                                                     rate = PriceTable.shared.effectiveRate] figure in
            guard let figure, case .money(let code) = figure.unit else { return nil }
            let from = code ?? "USD"
            if from == currency { return figure.amount }
            return from == "USD" && rate > 0 ? figure.amount * rate : nil
        }
        Task {
            let all = await TimelinePane.sessions(in: span, pricer: Self.pricer,
                                                  accounts: CostAccountStore.shared.accounts, titles: false)
            let result = await Task.detached(priority: .userInitiated) { () -> Loaded in
                let ledger = SpendLedger.shared
                let rows = keys.map { extra in
                    KeyRow(id: extra.id, name: extra.displayName,
                           glyph: APICatalog.entry(id: extra.base)?.glyph ?? .apiKey,
                           day: ledger?.used(provider: extra.id, in: .day),
                           week: ledger?.used(provider: extra.id, in: .week),
                           month: ledger?.used(provider: extra.id, in: .month))
                }
                func keysPaid(_ from: Date, _ to: Date) -> Double {
                    keys.compactMap { toLocal(ledger?.used(provider: $0.id, from: from, to: to)) }.reduce(0, +)
                }
                let paid = all.filter { perToken.contains($0.accountID) }
                var byDay: [(Date, Double)] = []
                for back in 0..<7 {
                    let start = calendar.date(byAdding: .day, value: back, to: weekAgo)!
                    let end = calendar.date(byAdding: .day, value: 1, to: start)!
                    let tokens = paid.filter { $0.first >= start && $0.first < end }.compactMap(\.cost).reduce(0, +)
                    byDay.append((start, tokens + keysPaid(start, end)))
                }
                var byHour = Array(repeating: 0.0, count: 24)
                for hour in 0..<24 {
                    let start = calendar.date(byAdding: .hour, value: hour, to: today)!
                    let end = calendar.date(byAdding: .hour, value: 1, to: start)!
                    guard start <= Date() else { break }
                    let tokens = paid.filter { $0.first >= start && $0.first < end }.compactMap(\.cost).reduce(0, +)
                    byHour[hour] = tokens + keysPaid(start, end)
                }
                let activity = ActivityLedger.shared
                let figures = activity.map { ProductivityCoach.gather(ledger: $0, stores: stores) }
                // Badges already reached are given here too, not only on the hour.
                if let activity {
                    Achievements.award(ProductivityCoach.badgeStats(ledger: activity, stores: stores,
                                                                    keyIDs: keys.map(\.id), plans: paidPlans))
                }
                return Loaded(keys: rows,
                              commitTimes: figures?.commitTimes ?? [],
                              busyDays: figures?.busy ?? [:],
                              bestStreak: figures.map { Achievements.longestStreak($0.busy) } ?? 0,
                              activity: activity?.summary(from: interval.start, to: interval.end) ?? .init(),
                              streak: activity?.streak() ?? 0,
                              commits: figures?.commits.mapValues { Int($0) } ?? [:],
                              coach: activity?.coachEvents(limit: 8) ?? [],
                              paidByDay: byDay, paidByHour: byHour)
            }.value
            guard range == self.range else { return }
            self.sessions = all.filter { interval.contains($0.first) }
            self.keys = result.keys
            self.activity = result.activity
            self.streak = result.streak
            self.commits = result.commits
            self.coach = result.coach
            self.paidByDay = result.paidByDay
            self.paidByHour = result.paidByHour
            self.commitTimes = result.commitTimes
            self.busyDays = result.busyDays
            self.bestStreak = result.bestStreak
            self.earned = Achievements.earned()
            self.loading = false
        }
    }

    private struct Loaded: @unchecked Sendable {
        let keys: [KeyRow]
        let commitTimes: [Date]
        let busyDays: [Date: TimeInterval]
        let bestStreak: Int
        let activity: ActivityLedger.Summary
        let streak: Int
        let commits: [Date: Int]
        let coach: [ActivityLedger.CoachEvent]
        let paidByDay: [(day: Date, amount: Double)]
        let paidByHour: [Double]
    }

    /// What was paid by use in the range: tokens of logins paid per token,
    /// and keys. Plans are not here; they belong to Productivity.
    var apiSpent: Double { tokenSpend + keySpend }

    /// The last few local days, oldest first, today last, each with a figure.
    func lastDays(_ count: Int, _ value: (Date) -> Double) -> [(day: Date, value: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).map { index in
            let day = calendar.date(byAdding: .day, value: index - count + 1, to: today)!
            return (day, value(day))
        }
    }

    /// Commits in the range.
    var commitsInRange: Int {
        commits.filter { range.interval.contains($0.key) }.values.reduce(0, +)
    }

    // MARK: Figures

    /// With no exchange rate yet (Market data is off), everything is shown
    /// in dollars, the currency token prices and most keys are in: better
    /// than a zero where the money could not be brought over.
    static var inDollars: Bool { PriceTable.shared.inDollars }

    static var pricer: Pricer { PriceTable.shared.pricer }

    var currency: String { PriceTable.shared.currency }

    /// A key's money in the Mac's currency, where it can be: as it is when
    /// the currencies agree, through the exchange rate from dollars.
    func local(_ figure: SpendLedger.Figure?) -> Double? {
        guard let figure, case .money(let code) = figure.unit else { return nil }
        return local(figure.amount, code ?? "USD")
    }

    func local(_ amount: Double, _ from: String) -> Double? {
        if from == currency { return amount }
        let rate = PriceTable.shared.effectiveRate
        return from == "USD" && rate > 0 ? amount * rate : nil
    }

    /// What every agent session cost, by its share of the plan or by its
    /// tokens: where the money went.
    var agentSpend: Double { sessions.compactMap(\.cost).reduce(0, +) }

    /// The sessions of logins paid per token: money spent, not a plan's share.
    var tokenSpend: Double {
        let perToken = Set(CostAccountStore.shared.accounts.filter { $0.billing == .api }.map(\.id))
        return sessions.filter { perToken.contains($0.accountID) }.compactMap(\.cost).reduce(0, +)
    }

    /// This range's share of every plan: a day's worth, a week's or the month.
    var planSpend: Double {
        let share = CodingPlans.share(of: range)
        return plans.compactMap { row in row.monthly.flatMap { local($0, row.currency) } }.reduce(0, +) * share
    }
    var keySpend: Double { keys.compactMap { local($0.figure(range.keyPeriod)) }.reduce(0, +) }
    /// Keys' money that can't be brought into the Mac's currency (no rate
    /// yet: Market data is off), by its own currency, so it is still shown.
    var keySpendElsewhere: [(code: String, amount: Double)] {
        var sums: [String: Double] = [:]
        for key in keys {
            guard let figure = key.figure(range.keyPeriod), local(figure) == nil, case .money(let code) = figure.unit else { continue }
            sums[code ?? "USD", default: 0] += figure.amount
        }
        return sums.map { ($0.key, $0.value) }.sorted { $0.code < $1.code }
    }
    /// Plans for the range, and what was paid by use: tokens and keys.
    var totalSpend: Double { planSpend + tokenSpend + keySpend }

    var costPerFinish: Double? { activity.finished > 0 && totalSpend > 0 ? totalSpend / Double(activity.finished) : nil }
    var costPerHundredLines: Double? {
        let lines = activity.added + activity.removed
        return lines > 0 && totalSpend > 0 ? totalSpend / Double(lines) * 100 : nil
    }

    /// The models that cost most, from the agents' sessions.
    var models: [(name: String, cost: Double, sessions: Int)] {
        Dictionary(grouping: sessions, by: { TimelinePane.shortModel($0.model) })
            .map { (name: $0.key.isEmpty ? L10n.t("Unknown") : $0.key, cost: $0.value.compactMap(\.cost).reduce(0, +), sessions: $0.value.count) }
            .sorted { $0.cost > $1.cost }
    }

    /// The agents' spend on each local day of the range.
    var spendByDay: [(day: Date, cost: Double)] {
        let calendar = Calendar.current
        var days: [Date: Double] = [:]
        var day = range.interval.start
        while day < range.interval.end, day <= Date() {
            days[day] = 0
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        for row in sessions { days[calendar.startOfDay(for: row.first), default: 0] += row.cost ?? 0 }
        return days.map { ($0.key, $0.value) }.sorted { $0.day < $1.day }
    }

    /// Since when the activity ledger knows, if that is inside the range.
    var activitySince: Date? { activity.since }
}
