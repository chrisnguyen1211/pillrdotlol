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

/// The dashboard at the head of Settings, in widgets: a few that matter,
/// folded; Productivity and API usage in full, unfolded from the bar at its
/// foot; or hidden to a single line, to keep to the settings.
struct DashboardPanel: View {
    @ObservedObject var preferences: Preferences
    @Binding var mode: DashboardMode
    @StateObject private var model: DashboardModel
    /// What the arrow under the pointer will do, said beside it.
    @State private var hint: String?

    init(preferences: Preferences, mode: Binding<DashboardMode>) {
        self.preferences = preferences
        _mode = mode
        _model = StateObject(wrappedValue: DashboardModel(extraKeys: { [weak preferences] in preferences?.extraKeys ?? [] },
                                                          range: .today))
    }

    /// For renders: a model set by hand.
    init(model: DashboardModel, preferences: Preferences, mode: Binding<DashboardMode>) {
        self.preferences = preferences
        _mode = mode
        _model = StateObject(wrappedValue: model)
    }

    /// The panel's height when folded, and when hidden to one line.
    static let foldedHeight: CGFloat = 200
    static let hiddenHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 2)
                .padding(.bottom, mode == .hidden ? 0 : 10)
            switch mode {
            case .hidden:
                EmptyView()
            case .folded:
                DashboardFolded(model: model)
                footer
            case .expanded:
                ScrollView {
                    DashboardSections(model: model)
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                footer
            }
        }
        .task {
            // While Settings is up, kept as fresh as the ledgers are.
            while !Task.isCancelled {
                model.load()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.t("Dashboard")).font(.system(size: 13, weight: .semibold))
            if model.loading && mode != .hidden {
                ProgressView().controlSize(.mini)
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
        .frame(height: mode == .hidden ? Self.hiddenHeight : nil)
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
                Text(hint).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    .offset(x: mode == .folded ? 110 : 80)
                    .transition(.opacity)
            }
        }
        .frame(height: 26)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.12), value: hint)
    }

    private func arrow(up: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 22)
                .background(Capsule().fill(Color.primary.opacity(hint == label ? 0.1 : 0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in hint = inside ? label : (hint == label ? nil : hint) }
        .help(label)
        .accessibilityLabel(label)
    }

    private func set(_ new: DashboardMode) {
        hint = nil
        withAnimation(.snappy(duration: 0.25)) { mode = new }
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
        .frame(height: WidgetSize.rowHeight)
    }
}

/// Unfolded: Productivity, then API usage.
struct DashboardSections: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetSectionTitle(title: L10n.t("Productivity"), symbol: "bolt.fill")
            if let latest = model.coach.first(where: { $0.kind != .badge }), latest.at > Date().addingTimeInterval(-7 * 86_400) {
                CoachBanner(event: latest)
            }
            WidgetRow {
                AgentsAtWorkWidget(model: model).widgetSize(.small)
                WaitingWidget(model: model).widgetSize(.small)
                LinesWidget(model: model).widgetSize(.small)
                StreakWidget(model: model).widgetSize(.small)
            }
            .frame(height: WidgetSize.rowHeight)
            CommitsWidget(model: model, compact: false)
                .frame(height: 158)
            AchievementsWidget(model: model)
                .frame(height: 168)
            WidgetRow {
                PlansWidget(model: model).widgetSize(.medium)
                ModelsWidget(model: model).widgetSize(.medium)
            }
            .frame(height: 150)
            WidgetRow {
                AgentTimeWidget(model: model).widgetSize(.medium)
                HoursWidget(model: model).widgetSize(.medium)
            }
            .frame(height: 142)
            RecentSessionsWidget(model: model)
                .frame(height: 176)

            WidgetSectionTitle(title: L10n.t("API usage"), symbol: "chart.bar.fill")
                .padding(.top, 8)
            SpendChartWidget(model: model)
                .frame(height: 190)
            WidgetRow {
                KeysWidget(model: model).widgetSize(.medium)
                APISpentWidget(model: model).widgetSize(.small)
                KeyCountWidget(model: model).widgetSize(.small)
            }
            .frame(height: 150)
            Text(L10n.t("Everything here is worked out on this Mac and stays on it."))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }
}

// MARK: - Layout

/// Widgets on a grid of four columns: small takes one, medium two.
enum WidgetSize {
    case small, medium
    var columns: CGFloat { self == .small ? 1 : 2 }
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.85))
                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The big figure a small widget is about, and a line under it.
struct WidgetFigure: View {
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.5)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
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
            Spacer(minLength: 0)
            WidgetFigure(value: TimelinePane.duration(a.busy),
                         detail: a.parallel >= 60 ? L10n.t("\(TimelinePane.duration(a.parallel)) with two or more at once")
                                                  : L10n.t("\(model.streak)-day streak"))
        }
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

/// Commits shipped, drawn for the range: today hour by hour, this week day
/// by day, this month a square a day like GitHub's. The pointer on a square
/// says how many.
struct CommitsWidget: View {
    @ObservedObject var model: DashboardModel
    let compact: Bool

    var body: some View {
        WidgetCard(title: L10n.t("Commits shipped"), symbol: "point.3.connected.trianglepath.dotted", tint: .green) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.commitsInRange)")
                        .font(.system(size: compact ? 24 : 28, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(model.range.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .frame(width: compact ? 58 : 110, alignment: .leading)
                Spacer(minLength: 0)
                switch model.range {
                case .today: CommitHours(times: model.commitTimes, compact: compact)
                case .week: CommitWeek(days: model.commits, compact: compact)
                case .month: CommitGrid(days: model.commits, weeks: compact ? 15 : 22, cell: compact ? 8 : 11)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Today, an hour a column: a dot for each commit, up to four, then a figure.
struct CommitHours: View {
    let times: [Date]
    let compact: Bool
    @State private var hovered: Int?

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var counts = Array(repeating: 0, count: 24)
        for time in times where calendar.isDate(time, inSameDayAs: today) { counts[calendar.component(.hour, from: time)] += 1 }
        let now = calendar.component(.hour, from: Date())
        let dot: CGFloat = compact ? 5 : 7
        return HStack(alignment: .bottom, spacing: compact ? 2.5 : 4) {
            ForEach(0..<24, id: \.self) { hour in
                VStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { level in
                        Circle()
                            .fill(counts[hour] > 3 - level ? Color.green : Color.primary.opacity(hour <= now ? 0.08 : 0.03))
                            .frame(width: dot, height: dot)
                    }
                    Text(hour % 6 == 0 ? "\(hour)" : " ").font(.system(size: 8)).foregroundStyle(.secondary).fixedSize()
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? hour : (hovered == hour ? nil : hovered) }
                .overlay(alignment: .top) {
                    if hovered == hour {
                        TipBubble(text: L10n.t("\(counts[hour]) commits, \(hour):00 to \(hour + 1):00")).offset(y: -26)
                    }
                }
                .zIndex(hovered == hour ? 1 : 0)
            }
        }
    }
}

/// This week, a day a square, the count written in it.
struct CommitWeek: View {
    let days: [Date: Int]
    let compact: Bool
    @State private var hovered: Int?

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let today = calendar.startOfDay(for: Date())
        let top = max(1, (0..<7).map { days[calendar.date(byAdding: .day, value: $0, to: start)!] ?? 0 }.max() ?? 1)
        let side: CGFloat = compact ? 22 : 34
        let formatter = DashboardWords.dayFormatter("EEEEE")
        return HStack(spacing: compact ? 4 : 7) {
            ForEach(0..<7, id: \.self) { index in
                let day = calendar.date(byAdding: .day, value: index, to: start)!
                let count = days[day] ?? 0
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                        .fill(day > today ? Color.primary.opacity(0.03) : CommitGrid.shade(count, top: top))
                        .frame(width: side, height: side)
                        .overlay {
                            if count > 0 && !compact {
                                Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                            }
                        }
                    Text(formatter.string(from: day)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                .overlay(alignment: .top) {
                    if hovered == index {
                        TipBubble(text: L10n.t("\(count) commits on \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"))
                            .offset(y: -26)
                    }
                }
                .zIndex(hovered == index ? 1 : 0)
            }
        }
    }
}

/// A square a day like GitHub's, darker for more.
struct CommitGrid: View {
    let days: [Date: Int]
    let weeks: Int
    let cell: CGFloat
    @State private var hovered: Date?

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        let top = max(1, days.values.max() ?? 1)
        return HStack(spacing: cell * 0.28) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: cell * 0.28) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: first)!
                        let count = days[day] ?? 0
                        RoundedRectangle(cornerRadius: cell * 0.25, style: .continuous)
                            .fill(day > today ? Color.clear : Self.shade(count, top: top))
                            .frame(width: cell, height: cell)
                            .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
                            .overlay(alignment: .top) {
                                if hovered == day {
                                    TipBubble(text: L10n.t("\(count) commits on \(day.formatted(.dateTime.day().month(.abbreviated)))"))
                                        .offset(y: -24)
                                }
                            }
                            .zIndex(hovered == day ? 1 : 0)
                    }
                }
                .zIndex(hovered.map { calendar.dateInterval(of: .weekOfYear, for: $0)?.start == calendar.date(byAdding: .weekOfYear, value: week, to: first) } ?? false ? 1 : 0)
            }
        }
        .accessibilityLabel(L10n.t("Commits per day"))
    }

    static func shade(_ count: Int, top: Int) -> Color {
        guard count > 0 else { return Color.primary.opacity(0.07) }
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
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.plans.prefix(4)) { plan in
                        HStack(spacing: 7) {
                            ProviderGlyphView(glyph: plan.glyph, size: 12)
                            Text(plan.agentName).font(.system(size: 11.5)).lineLimit(1)
                            Text(plan.name ?? plan.reported).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(plan.monthly.map { MoneyFormat.string($0, currency: plan.currency) } ?? "—")
                                .font(.system(size: 11.5).monospacedDigit())
                        }
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(list), id: \.key) { agent, seconds in
                        HStack(spacing: 8) {
                            Text(DashboardWords.agentName(agent)).font(.system(size: 11.5)).frame(width: 74, alignment: .leading)
                                .lineLimit(1)
                            Bar(fraction: seconds / max(top, 1), tint: .green)
                            Text(TimelinePane.duration(seconds)).font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                        }
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
            Columns(values: model.activity.busyByHour, tint: .teal,
                    label: { $0 % 6 == 0 ? "\($0)" : "" }, help: { TimelinePane.duration($0) })
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
            if span == 1 {
                Columns(values: model.paidByHour, tint: .orange, label: { $0 % 6 == 0 ? "\($0)" : "" }, help: money)
            } else {
                let days = Array(model.paidByDay.suffix(span))
                let formatter = DashboardWords.dayFormatter(span == 7 ? "EEE" : "EEE d")
                Columns(values: days.map(\.amount), tint: .orange,
                        label: { formatter.string(from: days[$0].day) }, help: money)
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
                VStack(alignment: .leading, spacing: 7) {
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
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(item.name).font(.system(size: 11.5)).frame(width: 92, alignment: .leading).lineLimit(1)
                            Bar(fraction: item.cost / top, tint: .pink)
                            Text(MoneyFormat.string(item.cost, currency: model.currency)).font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                        }
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

/// Columns over time, with a label under some.
struct Columns: View {
    let values: [Double]
    let tint: Color
    let label: (Int) -> String
    let help: (Double) -> String

    var body: some View {
        let top = values.max() ?? 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(tint.opacity(value > 0 ? 0.8 : 0.12))
                        .frame(height: top > 0 ? max(2, 70 * value / top) : 2)
                        .help(help(value))
                    Text(label(index)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
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
            Spacer(minLength: 0)
            WidgetFigure(value: L10n.t("\(model.streak) days"), detail: L10n.t("Best: \(model.bestStreak) days"))
        }
    }
}

/// What was paid by use: tokens of logins paid per token, and keys.
struct APISpentWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let money = { (v: Double) in MoneyFormat.string(v, currency: model.currency) }
        WidgetCard(title: L10n.t("API spent"), symbol: "dollarsign.circle.fill", tint: .orange) {
            Spacer(minLength: 0)
            WidgetFigure(value: money(model.apiSpent),
                         detail: L10n.t("Keys \(money(model.keySpend)) · tokens \(money(model.tokenSpend))"))
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
                VStack(alignment: .leading, spacing: 6) {
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
                    }
                }
            }
        }
    }
}

/// Badges, bronze to gold: those held in colour, the rest waiting in grey.
/// The pointer on one says what it is for.
struct AchievementsWidget: View {
    @ObservedObject var model: DashboardModel
    @State private var hovered: String?

    var body: some View {
        let held = model.earned
        let all = Achievements.families.flatMap { family in
            Achievements.Tier.allCases.map { Achievements.Badge(family: family.id, tier: $0) }
        }
        WidgetCard(title: L10n.t("Achievements"), symbol: "medal.fill", tint: .yellow) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("\(held.count) of \(all.count) earned"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let hovered, let badge = all.first(where: { $0.id == hovered }) {
                    Text(describe(badge, earned: held[badge.id]))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 18), spacing: 6) {
                ForEach(all) { badge in
                    Medal(badge: badge, earned: held[badge.id] != nil, size: 30)
                        .onHover { hovered = $0 ? badge.id : (hovered == badge.id ? nil : hovered) }
                        .help(describe(badge, earned: held[badge.id]))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
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
