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

    @Published var range: Range = .week { didSet { load() } }
    @Published private(set) var sessions: [TimelinePane.Row] = []
    @Published private(set) var keys: [KeyRow] = []
    @Published private(set) var plans: [CodingPlans.Row] = []
    @Published private(set) var activity = ActivityLedger.Summary()
    @Published private(set) var streak = 0
    @Published private(set) var loading = false

    private let extraKeys: () -> [ExtraKey]

    init(extraKeys: @escaping () -> [ExtraKey]) {
        self.extraKeys = extraKeys
    }

    /// For renders: figures set as they are, nothing loaded.
    private var frozen = false

    static func forRender(range: Range, sessions: [TimelinePane.Row], keys: [KeyRow], plans: [CodingPlans.Row] = [],
                          activity: ActivityLedger.Summary, streak: Int) -> DashboardModel {
        let model = DashboardModel(extraKeys: { [] })
        model.frozen = true
        model.range = range
        model.sessions = sessions
        model.keys = keys
        model.plans = plans
        model.activity = activity
        model.streak = streak
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
        Task {
            let sessions = await TimelinePane.sessions(in: interval, pricer: Self.pricer,
                                                       accounts: CostAccountStore.shared.accounts, titles: false)
            let (rows, summary, streak) = await Task.detached(priority: .userInitiated) { () -> ([KeyRow], ActivityLedger.Summary, Int) in
                let ledger = SpendLedger.shared
                let rows = keys.map { extra in
                    KeyRow(id: extra.id, name: extra.displayName,
                           glyph: APICatalog.entry(id: extra.base)?.glyph ?? .apiKey,
                           day: ledger?.used(provider: extra.id, in: .day),
                           week: ledger?.used(provider: extra.id, in: .week),
                           month: ledger?.used(provider: extra.id, in: .month))
                }
                let activity = ActivityLedger.shared
                return (rows, activity?.summary(from: interval.start, to: interval.end) ?? .init(), activity?.streak() ?? 0)
            }.value
            guard range == self.range else { return }
            self.sessions = sessions
            self.keys = rows
            self.activity = summary
            self.streak = streak
            self.loading = false
        }
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

struct DashboardView: View {
    @StateObject var model: DashboardModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L10n.t("Overview")).tag(0)
                Text(L10n.t("Sessions")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.top, 14)
            .accessibilityLabel(L10n.t("Dashboard view"))
            if tab == 0 {
                DashboardOverview(model: model)
            } else {
                TimelinePane()
            }
        }
    }
}

struct DashboardOverview: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ScrollView { DashboardContent(model: model) }
            .onAppear { model.load() }
    }
}

/// The dashboard itself, outside its scroll view so it can be drawn.
struct DashboardContent: View {
    @ObservedObject var model: DashboardModel

    private var money: (Double) -> String { { MoneyFormat.string($0, currency: model.currency) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            cards
            HStack(alignment: .top, spacing: 18) {
                chart
                agents
            }
            planTable
            keyTable
            modelTable
            footnotes
        }
        .padding(.horizontal, 48).padding(.top, 22).padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Dashboard")).font(.system(size: 20, weight: .semibold))
                Text(L10n.t("What your coding cost, and how the work went.")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.range) {
                ForEach(DashboardModel.Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            .accessibilityLabel(L10n.t("Period"))
            Button { model.load() } label: { Image(systemName: "arrow.clockwise") }
                .controlSize(.small)
                .accessibilityLabel(L10n.t("Refresh"))
        }
    }

    // MARK: Cards

    private var cards: some View {
        let a = model.activity
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            card(L10n.t("Spent"), money(model.totalSpend),
                 L10n.t("Plans \(money(model.planSpend)) · pay as you go \(payAsYouGo)"), tint: .orange)
            card(L10n.t("Agents at work"), TimelinePane.duration(a.busy),
                 a.parallel >= 60 ? L10n.t("\(TimelinePane.duration(a.parallel)) with two or more at once") : L10n.t("One at a time"),
                 tint: .green)
            card(L10n.t("Waiting on you"), TimelinePane.duration(a.waiting),
                 a.medianAnswer.map { L10n.t("\(a.answered) answered · usually in \(Self.seconds($0))") } ?? L10n.t("Nothing answered from the notch"),
                 tint: .yellow)
            card(L10n.t("Sessions finished"), "\(a.finished)",
                 L10n.t("\(a.sessions) sessions · \(model.streak)-day streak"), tint: .blue)
            card(L10n.t("Lines changed"), "+\(a.added) −\(a.removed)",
                 L10n.t("Grown between finishes, from git"), tint: .purple)
            card(L10n.t("Cost per finished session"), model.costPerFinish.map(money) ?? "—",
                 model.costPerHundredLines.map { L10n.t("\(money($0)) per 100 lines") } ?? L10n.t("No lines counted yet"),
                 tint: .pink)
        }
    }

    /// The keys' spend in the Mac's currency, and in its own where there is
    /// no rate to bring it over.
    private var payAsYouGo: String {
        let here = model.tokenSpend + model.keySpend
        let elsewhere = model.keySpendElsewhere.map { MoneyFormat.string($0.amount, currency: $0.code) }
        if elsewhere.isEmpty { return money(here) }
        return ((here > 0 ? [money(here)] : []) + elsewhere).joined(separator: " + ")
    }

    private func card(_ title: String, _ value: String, _ detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Charts

    @ViewBuilder
    private var chart: some View {
        if model.range == .today {
            panel(L10n.t("Work by hour")) {
                bars(model.activity.busyByHour.enumerated().map { (label: $0.offset % 3 == 0 ? "\($0.offset)" : "", value: $0.element) },
                     tint: .green, format: { TimelinePane.duration($0) })
            }
        } else {
            panel(L10n.t("Agent spend by day")) {
                let formatter = Self.dayFormatter(model.range)
                bars(model.spendByDay.map { (label: formatter.string(from: $0.day), value: $0.cost) }, tint: .orange, format: money)
            }
        }
    }

    private var agents: some View {
        panel(L10n.t("Time at work by agent")) {
            let list = model.activity.busyByAgent.sorted { $0.value > $1.value }
            if list.isEmpty {
                Text(L10n.t("No agent has worked in this period yet.")).font(.caption).foregroundStyle(.secondary)
            } else {
                let top = list.first!.value
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(list, id: \.key) { agent, seconds in
                        HStack(spacing: 8) {
                            Text(Self.agentName(agent)).font(.system(size: 12)).frame(width: 110, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                Capsule().fill(Color.green.opacity(0.7))
                                    .frame(width: max(4, geo.size.width * seconds / max(top, 1)), height: 8)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: 14)
                            Text(TimelinePane.duration(seconds)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .frame(width: 360)
    }

    private func bars(_ items: [(label: String, value: Double)], tint: Color, format: @escaping (Double) -> String) -> some View {
        let top = items.map(\.value).max() ?? 0
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint.opacity(item.value > 0 ? 0.8 : 0.15))
                        .frame(height: top > 0 ? max(2, 110 * item.value / top) : 2)
                        .help(format(item.value))
                    Text(item.label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 132, alignment: .bottom)
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    // MARK: Tables

    private var keyTable: some View {
        panel(L10n.t("API keys")) {
            if model.keys.isEmpty {
                Text(L10n.t("No API keys added. Add one in Settings → API.")).font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text(L10n.t("Key")).gridColumnAlignment(.leading)
                        Text(L10n.t("Today")).gridColumnAlignment(.trailing)
                        Text(L10n.t("This week")).gridColumnAlignment(.trailing)
                        Text(L10n.t("This month")).gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(model.keys) { key in
                        GridRow {
                            HStack(spacing: 7) {
                                ProviderGlyphView(glyph: key.glyph, size: 13)
                                Text(key.name).lineLimit(1)
                            }
                            figure(key.day)
                            figure(key.week)
                            figure(key.month)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private var planTable: some View {
        panel(L10n.t("Coding plans")) {
            if model.plans.isEmpty {
                Text(L10n.t("No agent reports a plan yet. Claude and Codex logins count here when set to Monthly plan in Settings → Costs."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text(L10n.t("Agent"))
                        Text(L10n.t("Plan"))
                        Text(L10n.t("Per month")).gridColumnAlignment(.trailing)
                        Text(model.range.title).gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(model.plans) { plan in
                        GridRow {
                            HStack(spacing: 7) {
                                ProviderGlyphView(glyph: plan.glyph, size: 13)
                                Text(plan.agentName).lineLimit(1)
                            }
                            Text(plan.name ?? plan.reported).lineLimit(1)
                            if let monthly = plan.monthly {
                                Text(MoneyFormat.string(monthly, currency: plan.currency)).monospacedDigit()
                                Text(model.local(monthly, plan.currency).map { money($0 * CodingPlans.share(of: model.range)) } ?? "—")
                                    .monospacedDigit()
                            } else {
                                Text(L10n.t("Price unknown")).foregroundStyle(.secondary)
                                Text("—")
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func figure(_ figure: SpendLedger.Figure?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(figure.map { APIAmount.short($0.amount, $0.unit) } ?? "—").monospacedDigit()
            if let since = figure?.since {
                Text(L10n.t("since \(since.formatted(.dateTime.day().month(.abbreviated)))"))
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private var modelTable: some View {
        panel(L10n.t("What the agents' money went on")) {
            let list = model.models.prefix(6)
            if list.isEmpty {
                Text(L10n.t("No Claude or Codex session in this period.")).font(.caption).foregroundStyle(.secondary)
            } else {
                let total = max(model.agentSpend, 0.0001)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Text(item.name).font(.system(size: 12)).frame(width: 180, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                Capsule().fill(Color.orange.opacity(0.7))
                                    .frame(width: max(4, geo.size.width * item.cost / total), height: 8)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: 14)
                            Text(L10n.t("\(item.sessions) sessions")).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .trailing)
                            Text(money(item.cost)).font(.system(size: 12).monospacedDigit()).frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Plans count as a day's, a week's or the month's share of their list price. A login paid per token counts its tokens; API keys are what their providers report, by UTC day, week and month."))
            Text(L10n.t("A key with only a balance or a monthly total is followed from when pillr first read it. Lines are counted from git as trees grow between finishes."))
            if let since = model.activitySince {
                Text(L10n.t("Time at work is known since \(since.formatted(date: .abbreviated, time: .shortened))."))
            }
            if DashboardModel.inDollars {
                Text(L10n.t("Shown in US dollars: turn on Market data in Settings → Costs to see your own currency."))
            }
            if !model.keySpendElsewhere.isEmpty {
                Text(L10n.t("Keys billed in another currency are not added to the total until Market data in Settings → Costs has an exchange rate."))
            }
            Text(L10n.t("Everything here is worked out on this Mac and stays on it."))
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    // MARK: Words

    static func seconds(_ value: TimeInterval) -> String {
        value < 90 ? L10n.t("\(Int(value)) s") : TimelinePane.duration(value)
    }

    static func agentName(_ providerID: String) -> String {
        ProviderGlyph.forProvider(providerID)?.agentName ?? providerID.capitalized
    }

    static func dayFormatter(_ range: DashboardModel.Range) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(range == .week ? "EEE" : "d")
        return formatter
    }
}
