import SwiftUI
import AppKit

// MARK: - The panel

/// The dashboard at the head of Settings, in widgets: a few that matter,
/// folded; Productivity and API usage in full, unfolded from the bar at its
/// foot. It takes the place a small copy of the notch used to hold.
struct DashboardPanel: View {
    @ObservedObject var preferences: Preferences
    @Binding var expanded: Bool
    @StateObject private var model: DashboardModel

    init(preferences: Preferences, expanded: Binding<Bool>) {
        self.preferences = preferences
        _expanded = expanded
        _model = StateObject(wrappedValue: DashboardModel(extraKeys: { [weak preferences] in preferences?.extraKeys ?? [] },
                                                          range: .today))
    }

    /// For renders: a model set by hand.
    init(model: DashboardModel, preferences: Preferences, expanded: Binding<Bool>) {
        self.preferences = preferences
        _expanded = expanded
        _model = StateObject(wrappedValue: model)
    }

    /// Folded, the panel is this tall.
    static let foldedHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 2)
                .padding(.bottom, 10)
            if expanded {
                ScrollView {
                    DashboardSections(model: model)
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            } else {
                DashboardFolded(model: model)
            }
            footer
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
            if model.loading {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Picker("", selection: $model.range) {
                ForEach(DashboardModel.Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 250)
            .accessibilityLabel(L10n.t("Period"))
        }
    }

    /// The bar at the foot: more, or less.
    private var footer: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(expanded ? L10n.t("Show less") : L10n.t("Show all metrics"))
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityLabel(expanded ? L10n.t("Show less") : L10n.t("Show all metrics"))
    }
}

/// Folded: the three that matter most — work, shipped, spent.
struct DashboardFolded: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        WidgetRow {
            AgentsAtWorkWidget(model: model).widgetSize(.small)
            CommitsWidget(model: model, weeks: 17, compact: true).widgetSize(.medium)
            SpentWidget(model: model).widgetSize(.small)
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
            if let latest = model.coach.first, latest.at > Date().addingTimeInterval(-7 * 86_400) {
                CoachBanner(event: latest)
            }
            WidgetRow {
                AgentsAtWorkWidget(model: model).widgetSize(.small)
                WaitingWidget(model: model).widgetSize(.small)
                FinishedWidget(model: model).widgetSize(.small)
                LinesWidget(model: model).widgetSize(.small)
            }
            .frame(height: WidgetSize.rowHeight)
            CommitsWidget(model: model, weeks: 17, compact: false)
                .frame(height: 158)
            WidgetRow {
                PlansWidget(model: model).widgetSize(.medium)
                RecordsWidget(model: model).widgetSize(.medium)
            }
            .frame(height: 138)
            WidgetRow {
                AgentTimeWidget(model: model).widgetSize(.medium)
                HoursWidget(model: model).widgetSize(.medium)
            }
            .frame(height: 142)

            WidgetSectionTitle(title: L10n.t("API usage"), symbol: "chart.bar.fill")
                .padding(.top, 8)
            SpendChartWidget(model: model)
                .frame(height: 190)
            WidgetRow {
                KeysWidget(model: model).widgetSize(.medium)
                ModelsWidget(model: model).widgetSize(.medium)
            }
            .frame(height: 150)
            WidgetRow {
                SpentWidget(model: model).widgetSize(.small)
                CostPerSessionWidget(model: model).widgetSize(.small)
                PlansShareWidget(model: model).widgetSize(.small)
                SessionsLinkWidget().widgetSize(.small)
            }
            .frame(height: WidgetSize.rowHeight)
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

struct FinishedWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Sessions finished"), symbol: "checkmark.circle.fill", tint: .blue) {
            Spacer(minLength: 0)
            WidgetFigure(value: "\(model.activity.finished)", detail: L10n.t("of \(model.activity.sessions) sessions"))
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

/// Commits, a square a day like GitHub's: darker for more.
struct CommitsWidget: View {
    @ObservedObject var model: DashboardModel
    let weeks: Int
    let compact: Bool

    var body: some View {
        WidgetCard(title: L10n.t("Commits shipped"), symbol: "point.3.connected.trianglepath.dotted", tint: .green) {
            HStack(alignment: .bottom, spacing: 14) {
                if !compact {
                    VStack(alignment: .leading, spacing: 4) {
                        WidgetFigure(value: "\(model.commitsInRange)", detail: model.range.title)
                        Text(L10n.t("\(model.commits.values.reduce(0, +)) in the last \(weeks) weeks"))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .frame(width: 130, alignment: .leading)
                }
                CommitGrid(days: model.commits, weeks: weeks, cell: compact ? 8 : 12)
                if compact {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(model.commitsInRange)")
                            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(model.range.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct CommitGrid: View {
    let days: [Date: Int]
    let weeks: Int
    let cell: CGFloat

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        let top = max(1, days.values.max() ?? 1)
        HStack(spacing: cell * 0.28) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: cell * 0.28) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: first)!
                        let count = days[day] ?? 0
                        RoundedRectangle(cornerRadius: cell * 0.25, style: .continuous)
                            .fill(day > today ? Color.clear : Self.shade(count, top: top))
                            .frame(width: cell, height: cell)
                            .help(L10n.t("\(count) commits on \(day.formatted(date: .abbreviated, time: .omitted))"))
                    }
                }
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

/// Records broken and nudges given, newest first.
struct RecordsWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        WidgetCard(title: L10n.t("Records"), symbol: "trophy.fill", tint: .yellow) {
            if model.coach.isEmpty {
                Text(L10n.t("Beat your own best day, week or month and it shows here."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.coach.prefix(4).enumerated()), id: \.offset) { _, event in
                        HStack(spacing: 7) {
                            Image(systemName: event.kind == .record ? "star.fill" : "leaf.fill")
                                .font(.system(size: 10)).foregroundStyle(event.kind == .record ? .yellow : .teal)
                            Text(DashboardWords.coachTitle(event)).font(.system(size: 11.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(event.at.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
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

struct SpentWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let money = { (v: Double) in MoneyFormat.string(v, currency: model.currency) }
        WidgetCard(title: L10n.t("Spent"), symbol: "dollarsign.circle.fill", tint: .orange) {
            Spacer(minLength: 0)
            WidgetFigure(value: money(model.totalSpend),
                         detail: L10n.t("Plans \(money(model.planSpend)) · used \(money(model.tokenSpend + model.keySpend))"))
        }
    }
}

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
        WidgetCard(title: L10n.t("Models"), symbol: "cpu.fill", tint: .pink) {
            let list = model.models.prefix(5)
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

struct CostPerSessionWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let money = { (v: Double) in MoneyFormat.string(v, currency: model.currency) }
        WidgetCard(title: L10n.t("Per session"), symbol: "gauge.with.dots.needle.33percent", tint: .pink) {
            Spacer(minLength: 0)
            WidgetFigure(value: model.costPerFinish.map(money) ?? "—",
                         detail: model.costPerHundredLines.map { L10n.t("\(money($0)) per 100 lines") } ?? L10n.t("No lines counted yet"))
        }
    }
}

struct PlansShareWidget: View {
    @ObservedObject var model: DashboardModel
    var body: some View {
        let money = { (v: Double) in MoneyFormat.string(v, currency: model.currency) }
        WidgetCard(title: L10n.t("Plans"), symbol: "calendar", tint: .indigo) {
            Spacer(minLength: 0)
            WidgetFigure(value: money(model.planSpend), detail: L10n.t("\(model.plans.count) plans · their share of \(model.range.title.lowercased())"))
        }
    }
}

struct SessionsLinkWidget: View {
    var body: some View {
        Button { Costs.showActivity() } label: {
            WidgetCard(title: L10n.t("Sessions"), symbol: "list.bullet.rectangle.fill", tint: .blue) {
                Spacer(minLength: 0)
                HStack {
                    Text(L10n.t("Every session, by project and hour")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("Open the sessions timeline"))
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
