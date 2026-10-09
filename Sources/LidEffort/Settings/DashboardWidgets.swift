import SwiftUI
import AppKit

// MARK: - The panel

/// How much of the dashboard shows at the head of Settings.
enum DashboardMode: String {
    /// A single line: out of the way of the settings below.
    case hidden
    /// The few widgets that matter.
    case folded
    /// Everything, over the panes.
    case expanded
}

/// The dashboard at the head of Settings, in widgets over a sky at this
/// Mac's own hour: a few that matter, folded; Productivity and API usage in
/// full, slid down from the bar at its foot; or slid up to a single line, to
/// keep to the settings.
struct DashboardPanel: View {
    @ObservedObject var preferences: Preferences
    @Binding var mode: DashboardMode
    @StateObject private var model: DashboardModel
    /// What the arrow under the pointer will do, said beside it.
    @State private var hint: String?
    /// A fixed hour for the sky, for renders.
    var skyDate: Date? = nil

    init(preferences: Preferences, mode: Binding<DashboardMode>) {
        self.preferences = preferences
        _mode = mode
        _model = StateObject(wrappedValue: DashboardModel(extraKeys: { [weak preferences] in preferences?.extraKeys ?? [] },
                                                          range: .today))
    }

    /// For renders: a model set by hand.
    init(model: DashboardModel, preferences: Preferences, mode: Binding<DashboardMode>, skyDate: Date? = nil) {
        self.preferences = preferences
        _mode = mode
        _model = StateObject(wrappedValue: model)
        self.skyDate = skyDate
    }

    /// The panel's height when folded, and when hidden to one line.
    static let foldedHeight: CGFloat = headerHeight + WidgetSize.rowHeight + 6 + footerHeight
    static let hiddenHeight: CGFloat = 36
    static let headerHeight: CGFloat = 42
    static let footerHeight: CGFloat = 32
    /// How it slides between the three.
    static let motion = Animation.spring(response: 0.5, dampingFraction: 0.88)

    var body: some View {
        ZStack(alignment: .top) {
            DashboardSky(date: skyDate)
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .frame(height: mode == .hidden ? Self.hiddenHeight : Self.headerHeight)
                if mode != .hidden {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                DashboardFolded(model: model)
                                    .frame(height: WidgetSize.rowHeight)
                                    .id(Self.top)
                                if mode == .expanded {
                                    DashboardSections(model: model)
                                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -28)),
                                                                removal: .opacity))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, mode == .expanded ? 12 : 6)
                        }
                        .scrollDisabled(mode != .expanded)
                        .scrollIndicators(.hidden)
                        .onChange(of: mode) { _, new in
                            if new != .expanded { reader.scrollTo(Self.top, anchor: .top) }
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -24)))
                    footer
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .task {
            // While Settings is up, kept as fresh as the ledgers are.
            while !Task.isCancelled {
                model.load()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private static let top = "dashboard.top"

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.t("Dashboard")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            if model.loading && mode != .hidden {
                ProgressView().controlSize(.mini).tint(.white)
            }
            Spacer()
            if mode == .hidden {
                arrow(up: false, label: L10n.t("Show dashboard")) { set(.folded) }
            } else {
                Picker("", selection: $model.range) {
                    ForEach(DashboardModel.Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 250)
                .accessibilityLabel(L10n.t("Period"))
            }
        }
    }

    /// The bar at the foot: up hides, down shows everything; or, unfolded,
    /// up folds it again. What each does is said while the pointer is on it.
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if mode == .folded {
                arrow(up: true, label: L10n.t("Hide dashboard")) { set(.hidden) }
                arrow(up: false, label: L10n.t("Show all metrics")) { set(.expanded) }
            } else {
                arrow(up: true, label: L10n.t("Show less")) { set(.folded) }
            }
            Spacer()
        }
        .overlay(alignment: .center) {
            if let hint {
                Text(hint).font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .offset(x: mode == .folded ? 118 : 88)
                    .transition(.opacity.combined(with: .offset(x: -6)))
            }
        }
        .frame(height: Self.footerHeight)
        .animation(.easeOut(duration: 0.14), value: hint)
    }

    private func arrow(up: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 22)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().fill(Color.primary.opacity(hint == label ? 0.1 : 0)))
                .scaleEffect(hint == label ? 1.08 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in hint = inside ? label : (hint == label ? nil : hint) }
        .help(label)
        .accessibilityLabel(label)
    }

    private func set(_ new: DashboardMode) {
        hint = nil
        withAnimation(Self.motion) { mode = new }
    }
}

/// Folded: the three that matter most — work, shipped, spent.
struct DashboardFolded: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        WidgetRow {
            AgentsAtWorkWidget(model: model).widgetSize(.small)
            CommitsWidget(model: model, compact: true).widgetSize(.medium)
            APISpentWidget(model: model).widgetSize(.small)
        }
    }
}

/// Unfolded, under the folded row: Productivity, then API usage. Each card
/// as tall as what it holds.
struct DashboardSections: View {
    @ObservedObject var model: DashboardModel

    /// A card listing rows: its head, then a row each.
    static func listHeight(_ rows: Int, extra: CGFloat = 0) -> CGFloat {
        max(96, 46 + CGFloat(max(1, rows)) * 23 + extra)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetSectionTitle(title: L10n.t("Productivity"), symbol: "bolt.fill")
                .padding(.top, 6)
            if let latest = model.coach.first(where: { $0.kind != .badge }), latest.at > Date().addingTimeInterval(-7 * 86_400) {
                CoachBanner(event: latest)
            }
            WidgetRow {
                WaitingWidget(model: model).widgetSize(.small)
                LinesWidget(model: model).widgetSize(.small)
                StreakWidget(model: model).widgetSize(.medium)
            }
            .frame(height: WidgetSize.rowHeight)
            AchievementsWidget(model: model)
            WidgetRow {
                AgentTimeWidget(model: model).widgetSize(.medium)
                HoursWidget(model: model).widgetSize(.medium)
            }
            .frame(height: 150)
            WidgetRow {
                PlansWidget(model: model).widgetSize(.medium)
                ModelsWidget(model: model).widgetSize(.medium)
            }
            .frame(height: Self.listHeight(max(min(model.plans.count, 4), min(model.models.count, 4)), extra: 16))
            RecentSessionsWidget(model: model)
                .frame(height: Self.listHeight(min(model.sessions.count, 5)))

            WidgetSectionTitle(title: L10n.t("API usage"), symbol: "chart.bar.fill")
                .padding(.top, 8)
            SpendChartWidget(model: model)
                .frame(height: 180)
            WidgetRow {
                KeysWidget(model: model).widgetSize(.large)
                KeyCountWidget(model: model).widgetSize(.small)
            }
            .frame(height: max(WidgetSize.rowHeight, Self.listHeight(min(model.keys.count, 5))))
            Text(L10n.t("Everything here is worked out on this Mac and stays on it."))
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .padding(.top, 2)
        }
    }
}

// MARK: - Layout

/// Widgets on a grid of four columns: small takes one, medium two, large
/// three.
enum WidgetSize {
    case small, medium, large
    var columns: CGFloat {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .large: return 3
        }
    }
    static let gap: CGFloat = 8
    static let rowHeight: CGFloat = 122
}

private struct WidgetSizeKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

extension View {
    func widgetSize(_ size: WidgetSize) -> some View { layoutValue(key: WidgetSizeKey.self, value: size.columns) }
}

/// A row of widgets, each as wide as the columns it takes, over four.
struct WidgetRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? WidgetSize.rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let unit = (bounds.width - 3 * WidgetSize.gap) / 4
        var x = bounds.minX
        for subview in subviews {
            let columns = subview[WidgetSizeKey.self]
            let width = unit * columns + WidgetSize.gap * (columns - 1)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + WidgetSize.gap
        }
    }
}

struct WidgetSectionTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 2)
    }
}

/// One widget, as on iOS and macOS: a rounded card, a small glyph and name
/// at its head, and what it says below.
struct WidgetCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Frosted over the sky, as widgets sit on a wallpaper.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(scheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.5)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(scheme == .dark ? 0.1 : 0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The big figure a small widget is about, and a line under it.
struct WidgetFigure: View {
    let value: String
    var detail: String? = nil
    var detailLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(detailLines)
            }
        }
    }
}

// MARK: - Productivity

struct AgentsAtWorkWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let a = model.activity
        WidgetCard(title: L10n.t("Agents at work"), symbol: "figure.run", tint: .green) {
            WidgetFigure(value: TimelinePane.duration(a.busy),
                         detail: a.parallel >= 60 ? L10n.t("\(TimelinePane.duration(a.parallel)) with two or more at once")
                                                  : L10n.t("\(model.streak)-day streak"),
                         detailLines: 1)
            WeekBars(values: model.lastDays(7) { model.busyDays[$0] ?? 0 }, tint: .green,
                     tip: TimelinePane.duration)
        }
    }
}

/// The last few days as small columns, today ringed; the pointer on one
/// says what it holds.
struct WeekBars: View {
    let values: [(day: Date, value: Double)]
    let tint: Color
    let tip: (Double) -> String
    var labels = false

    var body: some View {
        let formatter = DashboardWords.dayFormatter("EEE d")
        let letter = DashboardWords.dayFormatter("EEEEE")
        HoverBars(values: values.map(\.value), tint: tint,
                  label: { labels ? letter.string(from: values[$0].day) : "" },
                  tip: { L10n.t("\(tip(values[$0].value)) on \(formatter.string(from: values[$0].day))") },
                  current: values.isEmpty ? nil : values.count - 1)
            .frame(maxHeight: .infinity)
    }
}

struct WaitingWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let a = model.activity
        WidgetCard(title: L10n.t("Waiting on you"), symbol: "hourglass", tint: .orange) {
            Spacer(minLength: 0)
            WidgetFigure(value: TimelinePane.duration(a.waiting),
                         detail: a.medianAnswer.map { L10n.t("Answered in \(DashboardWords.seconds($0)), usually") }
                            ?? L10n.t("Nothing answered from the notch"))
        }
    }
}

struct LinesWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let a = model.activity
        WidgetCard(title: L10n.t("Lines changed"), symbol: "plusminus", tint: .purple) {
            Spacer(minLength: 0)
            WidgetFigure(value: "+\(a.added)", detail: L10n.t("−\(a.removed) · from git, between finishes"))
        }
    }
}

/// Commits shipped, drawn for the range: today an hour a column, this week
/// a day a column, this month a square a day like GitHub's. The pointer on
/// any says how many.
struct CommitsWidget: View {
    @ObservedObject var model: DashboardModel
    let compact: Bool

    var body: some View {
        WidgetCard(title: L10n.t("Commits shipped"), symbol: "point.3.connected.trianglepath.dotted", tint: .green) {
            HStack(alignment: .bottom, spacing: compact ? 10 : 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    Text("\(model.commitsInRange)")
                        .font(.system(size: compact ? 26 : 30, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(model.range.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                .frame(width: compact ? 70 : 120, alignment: .leading)
                Group {
                    switch model.range {
                    case .today: CommitHours(times: model.commitTimes)
                    case .week: CommitWeek(days: model.commits)
                    case .month: CommitCalendar(days: model.commits)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// One more thing worth knowing about the range.
    private var detail: String? {
        let calendar = Calendar.current
        switch model.range {
        case .today:
            guard let last = model.commitTimes.last(where: { calendar.isDateInToday($0) }) else { return nil }
            return L10n.t("Last at \(last.formatted(date: .omitted, time: .shortened))")
        case .week:
            let week = model.commits.filter { model.range.interval.contains($0.key) }
            guard let best = week.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
            return L10n.t("Busiest \(DashboardWords.dayFormatter("EEEE").string(from: best.key))")
        case .month:
            let active = model.commits.filter { model.range.interval.contains($0.key) && $0.value > 0 }.count
            return active > 0 ? L10n.t("\(active) active days") : nil
        }
    }
}

/// Today, an hour a column.
struct CommitHours: View {
    let times: [Date]

    var body: some View {
        let calendar = Calendar.current
        var counts = Array(repeating: 0.0, count: 24)
        for time in times where calendar.isDateInToday(time) { counts[calendar.component(.hour, from: time)] += 1 }
        let now = calendar.component(.hour, from: Date())
        return HoverBars(values: counts, tint: .green,
                         label: { $0 % 6 == 0 ? "\($0)" : "" },
                         tip: { L10n.t("\(Int(counts[$0])) commits, \($0):00 to \($0 + 1):00") },
                         future: { $0 > now }, current: now, spacing: 2.5)
    }
}

/// This week, a day a column.
struct CommitWeek: View {
    let days: [Date: Int]

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let today = calendar.startOfDay(for: Date())
        let week = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        let letter = DashboardWords.dayFormatter("EEE")
        return HoverBars(values: week.map { Double(days[$0] ?? 0) }, tint: .green,
                         label: { letter.string(from: week[$0]) },
                         tip: { L10n.t("\(days[week[$0]] ?? 0) commits on \(week[$0].formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))") },
                         future: { week[$0] > today }, current: week.firstIndex(of: today), spacing: 6)
    }
}

/// The shade of a commit square, darker for more.
enum CommitGrid {
    static func shade(_ count: Int, top: Int) -> Color {
        guard count > 0 else { return Color.primary.opacity(0.08) }
        let level = min(1, Double(count) / Double(top))
        return Color.green.opacity(0.3 + 0.7 * level)
    }
}

/// The small dark note GitHub shows over a square.
struct TipBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.85)))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

struct PlansWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Coding plans"), symbol: "creditcard.fill", tint: .indigo) {
            if model.plans.isEmpty {
                Text(L10n.t("No agent reports a plan yet.")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.plans.prefix(4)) { plan in
                        HStack(spacing: 7) {
                            ProviderGlyphView(glyph: plan.glyph, size: 12)
                            Text(plan.agentName).font(.system(size: 11.5)).lineLimit(1)
                            Text(plan.name ?? plan.reported).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(plan.monthly.map { MoneyFormat.string($0, currency: plan.currency) } ?? "—")
                                .font(.system(size: 11.5).monospacedDigit())
                        }
                        .hoverRow()
                    }
                }
            }
        }
    }
}

struct CoachBanner: View {
    let event: ActivityLedger.CoachEvent
    var body: some View {
        let note = DashboardWords.note(event)
        HStack(spacing: 10) {
            Image(systemName: note.good ? "trophy.fill" : "leaf.fill")
                .font(.system(size: 15)).foregroundStyle(note.good ? .yellow : .teal)
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title).font(.system(size: 12, weight: .semibold))
                Text(note.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill((note.good ? Color.yellow : Color.teal).opacity(0.13)))
    }
}

struct AgentTimeWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Time at work by agent"), symbol: "person.2.fill", tint: .green) {
            let list = model.activity.busyByAgent.sorted { $0.value > $1.value }.prefix(4)
            if list.isEmpty {
                Text(L10n.t("No agent has worked in this period yet.")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let top = list.first!.value
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(list), id: \.key) { agent, seconds in
                        HStack(spacing: 8) {
                            Text(DashboardWords.agentName(agent)).font(.system(size: 11.5)).frame(width: 74, alignment: .leading)
                                .lineLimit(1)
                            Bar(fraction: seconds / max(top, 1), tint: .green)
                            Text(TimelinePane.duration(seconds)).font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                        }
                        .hoverRow()
                    }
                }
            }
        }
    }
}

struct HoursWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Work by hour"), symbol: "clock.fill", tint: .teal) {
            let hours = model.activity.busyByHour
            HoverBars(values: hours, tint: .teal, label: { $0 % 6 == 0 ? "\($0)" : "" },
                      tip: { L10n.t("\(TimelinePane.duration(hours[$0])), \($0):00 to \($0 + 1):00") }, spacing: 2.5)
        }
    }
}

// MARK: - API usage

/// What was paid by use — tokens and keys — over today, three days or seven.
struct SpendChartWidget: View {
    @ObservedObject var model: DashboardModel
    @State private var span = 7

    var body: some View {
        let money = { (v: Double) in MoneyFormat.string(v, currency: model.currency) }
        WidgetCard(title: L10n.t("Pay-as-you-go spend"), symbol: "chart.bar.xaxis", tint: .orange) {
            HStack(alignment: .firstTextBaseline) {
                Text(money(total)).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                Spacer()
                Picker("", selection: $span) {
                    Text(L10n.t("Today")).tag(1)
                    Text(L10n.t("3 days")).tag(3)
                    Text(L10n.t("7 days")).tag(7)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 190)
                .accessibilityLabel(L10n.t("Chart span"))
            }
            .animation(.easeOut(duration: 0.2), value: span)
            if span == 1 {
                let hours = model.paidByHour
                let now = Calendar.current.component(.hour, from: Date())
                HoverBars(values: hours, tint: .orange, label: { $0 % 6 == 0 ? "\($0)" : "" },
                          tip: { L10n.t("\(money(hours[$0])), \($0):00 to \($0 + 1):00") },
                          future: { $0 > now }, current: now, spacing: 2.5)
            } else {
                let days = Array(model.paidByDay.suffix(span))
                let formatter = DashboardWords.dayFormatter(span == 7 ? "EEE" : "EEE d")
                let long = DashboardWords.dayFormatter("EEE d")
                HoverBars(values: days.map(\.amount), tint: .orange, label: { formatter.string(from: days[$0].day) },
                          tip: { L10n.t("\(money(days[$0].amount)) on \(long.string(from: days[$0].day))") },
                          current: days.count - 1, spacing: span == 7 ? 8 : 14)
            }
        }
    }

    private var total: Double {
        span == 1 ? model.paidByHour.reduce(0, +) : model.paidByDay.suffix(span).map(\.amount).reduce(0, +)
    }
}

struct KeysWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Spent by key"), symbol: "key.fill", tint: .yellow) {
            if model.keys.isEmpty {
                Text(L10n.t("No API keys added. Add one in Settings → API.")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let rows = model.keys.sorted { (model.local($0.figure(model.range.keyPeriod)) ?? -1) > (model.local($1.figure(model.range.keyPeriod)) ?? -1) }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.prefix(5)) { key in
                        HStack(spacing: 7) {
                            ProviderGlyphView(glyph: key.glyph, size: 12)
                            Text(key.name).font(.system(size: 11.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let figure = key.figure(model.range.keyPeriod) {
                                Text(APIAmount.short(figure.amount, figure.unit)).font(.system(size: 11.5).monospacedDigit())
                                if figure.since != nil {
                                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 9)).foregroundStyle(.tertiary)
                                        .help(L10n.t("Followed since pillr first read this key"))
                                }
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                        .hoverRow()
                    }
                }
            }
        }
    }
}

struct ModelsWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Agent models"), symbol: "cpu.fill", tint: .pink) {
            Text(L10n.t("Estimated from Claude Code and Codex tokens on this Mac, not API keys"))
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            let list = model.models.prefix(4)
            if list.isEmpty {
                Text(L10n.t("No Claude or Codex session in this period.")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let top = max(list.first!.cost, 0.0001)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.name).font(.system(size: 11.5)).frame(width: 92, alignment: .leading).lineLimit(1)
                            Bar(fraction: item.cost / top, tint: .pink)
                            Text(MoneyFormat.string(item.cost, currency: model.currency)).font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                        }
                        .hoverRow()
                    }
                }
            }
        }
    }
}

// MARK: - Small pieces

struct Bar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(tint.opacity(0.75)).frame(width: max(4, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 7)
    }
}

/// Words the widgets share.
enum DashboardWords {
    static func seconds(_ value: TimeInterval) -> String {
        value < 90 ? L10n.t("\(Int(value)) s") : TimelinePane.duration(value)
    }

    static func agentName(_ providerID: String) -> String {
        ProviderGlyph.forProvider(providerID)?.agentName ?? providerID.capitalized
    }

    static func dayFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    static func finding(_ event: ActivityLedger.CoachEvent) -> ProductivityCoach.Finding? {
        guard let metric = ProductivityCoach.Metric(rawValue: event.metric),
              let timeframe = ProductivityCoach.Timeframe(rawValue: event.timeframe) else { return nil }
        return .init(kind: event.kind, metric: metric, timeframe: timeframe, period: event.period,
                     value: event.value, previous: event.previous)
    }

    static func coachTitle(_ event: ActivityLedger.CoachEvent) -> String {
        finding(event).map(ProductivityCoach.title) ?? event.metric
    }

    static func note(_ event: ActivityLedger.CoachEvent) -> CardNote {
        finding(event).map(ProductivityCoach.note)
            ?? CardNote(title: event.metric, subtitle: "", status: "", good: event.kind == .record)
    }
}

// MARK: - More widgets

struct StreakWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Streak"), symbol: "flame.fill", tint: .orange) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading) {
                    Spacer(minLength: 0)
                    WidgetFigure(value: L10n.t("\(model.streak) days"), detail: L10n.t("Best: \(model.bestStreak) days"))
                }
                .frame(width: 96, alignment: .leading)
                WeekBars(values: model.lastDays(14) { model.busyDays[$0] ?? 0 }, tint: .orange,
                         tip: TimelinePane.duration, labels: true)
            }
        }
    }
}

/// What was paid by use: tokens of logins paid per token, and keys.
struct APISpentWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let money = { (v: Double) in MoneyFormat.string(v, currency: model.currency) }
        WidgetCard(title: L10n.t("API spent"), symbol: "dollarsign.circle.fill", tint: .orange) {
            WidgetFigure(value: money(model.apiSpent),
                         detail: L10n.t("Keys \(money(model.keySpend)) · tokens \(money(model.tokenSpend))"),
                         detailLines: 1)
            WeekBars(values: model.paidByDay.map { (day: $0.day, value: $0.amount) }, tint: .orange, tip: money)
        }
    }
}

struct KeyCountWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let used = model.keys.filter { ($0.figure(model.range.keyPeriod)?.amount ?? 0) > 0 }.count
        WidgetCard(title: L10n.t("Keys"), symbol: "key.horizontal.fill", tint: .yellow) {
            Spacer(minLength: 0)
            WidgetFigure(value: "\(model.keys.count)", detail: L10n.t("\(used) used \(model.range.title.lowercased())"))
        }
    }
}

/// The latest Claude Code and Codex sessions, in the dashboard itself.
struct RecentSessionsWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Recent sessions"), symbol: "list.bullet.rectangle.fill", tint: .blue) {
            let rows = model.sessions.sorted { $0.last > $1.last }.prefix(5)
            if rows.isEmpty {
                Text(L10n.t("No Claude or Codex session in this period.")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows)) { row in
                        HStack(spacing: 8) {
                            Text(ProjectCost(project: row.project, pct: 0).displayName)
                                .font(.system(size: 11.5)).lineLimit(1).frame(width: 150, alignment: .leading)
                            Text(TimelinePane.shortModel(row.model)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 90, alignment: .leading)
                            Text(row.last.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(TimelinePane.duration(row.duration)).font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                            Text(row.cost.map { MoneyFormat.string($0, currency: model.currency) } ?? "—")
                                .font(.system(size: 11.5).monospacedDigit()).frame(width: 64, alignment: .trailing)
                        }
                        .hoverRow()
                    }
                }
            }
        }
    }
}

/// The badges earned, newest first, each with its name; the pointer on one
/// says what it was for and when. Those still to come are not shown.
struct AchievementsWidget: View {
    @ObservedObject var model: DashboardModel
    @State private var hovered: String?

    /// The badges held, newest first.
    static func held(_ earned: [String: Date]) -> [Achievements.Badge] {
        earned.sorted { $0.value > $1.value }.compactMap { id, _ in
            guard let dot = id.lastIndex(of: "."), let raw = Int(id[id.index(after: dot)...]),
                  let tier = Achievements.Tier(rawValue: raw) else { return nil }
            let family = String(id[..<dot])
            guard Achievements.family(family) != nil else { return nil }
            return Achievements.Badge(family: family, tier: tier)
        }
    }

    var body: some View {
        let badges = Self.held(model.earned)
        let total = Achievements.families.count * Achievements.Tier.allCases.count
        WidgetCard(title: L10n.t("Achievements"), symbol: "medal.fill", tint: .yellow) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("\(badges.count) of \(total) earned"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let hovered, let badge = badges.first(where: { $0.id == hovered }) {
                    Text(describe(badge, earned: model.earned[badge.id]))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        .transition(.opacity)
                }
            }
            if badges.isEmpty {
                Text(L10n.t("No badges yet. The first comes with your first hour of agent work."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 6)], alignment: .leading, spacing: 8) {
                    ForEach(badges) { badge in
                        VStack(spacing: 4) {
                            Medal(badge: badge, earned: true, size: 40)
                                .scaleEffect(hovered == badge.id ? 1.14 : 1)
                                .shadow(color: .yellow.opacity(hovered == badge.id ? 0.35 : 0), radius: 6)
                            Text(Achievements.name(badge))
                                .font(.system(size: 9.5, weight: .medium)).multilineTextAlignment(.center)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(hovered == badge.id ? 0.07 : 0)))
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? badge.id : (hovered == badge.id ? nil : hovered) }
                        .help(describe(badge, earned: model.earned[badge.id]))
                    }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
    }

    private func describe(_ badge: Achievements.Badge, earned: Date?) -> String {
        let when = earned.map { L10n.t(" · earned \($0.formatted(.dateTime.day().month(.abbreviated))))") } ?? ""
        return "\(Achievements.name(badge)) (\(badge.tier.name)): \(Achievements.requirement(badge))\(when)"
    }
}

/// A medal: a disc in bronze, silver or gold with its emblem, on a ribbon.
struct Medal: View {
    let badge: Achievements.Badge
    let earned: Bool
    let size: CGFloat

    private var metal: [Color] {
        switch badge.tier {
        case .bronze: return [Color(red: 0.93, green: 0.66, blue: 0.42), Color(red: 0.62, green: 0.36, blue: 0.16)]
        case .silver: return [Color(red: 0.95, green: 0.96, blue: 0.97), Color(red: 0.58, green: 0.61, blue: 0.66)]
        case .gold: return [Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 0.80, green: 0.56, blue: 0.10)]
        }
    }

    var body: some View {
        let family = Achievements.family(badge.family)
        ZStack {
            // The ribbon behind the disc.
            HStack(spacing: size * 0.06) {
                Rectangle().fill(earned ? Color.blue.opacity(0.75) : Color.gray.opacity(0.3))
                    .frame(width: size * 0.18, height: size * 0.42).rotationEffect(.degrees(18))
                Rectangle().fill(earned ? Color.red.opacity(0.7) : Color.gray.opacity(0.3))
                    .frame(width: size * 0.18, height: size * 0.42).rotationEffect(.degrees(-18))
            }
            .offset(y: size * 0.3)
            Circle()
                .fill(LinearGradient(colors: earned ? metal : [Color.gray.opacity(0.35), Color.gray.opacity(0.2)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(Color.white.opacity(earned ? 0.55 : 0.2), lineWidth: size * 0.05).padding(size * 0.08))
                .shadow(color: .black.opacity(earned ? 0.25 : 0), radius: 1.5, y: 1)
                .frame(width: size * 0.8, height: size * 0.8)
            Image(systemName: family?.symbol ?? "star.fill")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(earned ? Color.white : Color.gray.opacity(0.6))
                .shadow(color: .black.opacity(earned ? 0.3 : 0), radius: 0.5, y: 0.5)
        }
        .frame(width: size, height: size)
        .opacity(earned ? 1 : 0.55)
        .accessibilityLabel("\(Achievements.name(badge)), \(badge.tier.name)")
    }
}
