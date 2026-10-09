import SwiftUI

/// Columns over time as Screen Time draws them: a faint track behind each,
/// the bar in colour, labels under some. The pointer lights the column under
/// it, dims the rest and says what it holds.
struct HoverBars: View {
    let values: [Double]
    let tint: Color
    /// Under a column; empty for none.
    var label: (Int) -> String = { _ in "" }
    /// What the pointer on a column says.
    let tip: (Int) -> String
    /// Columns still to come, drawn fainter.
    var future: (Int) -> Bool = { _ in false }
    /// The column for now, ringed.
    var current: Int? = nil
    var spacing: CGFloat = 3
    @State private var hovered: Int?

    private static let labelHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let count = max(values.count, 1)
            let width = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let showsLabels = values.indices.contains { !label($0).isEmpty }
            let height = max(1, geo.size.height - (showsLabels ? Self.labelHeight + 3 : 0))
            let top = values.max() ?? 0
            let radius = min(width / 2, 3.5)
            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(values.indices, id: \.self) { index in
                        let value = values[index]
                        let lit = hovered == nil || hovered == index
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Color.primary.opacity(future(index) ? 0.035 : (hovered == index ? 0.12 : 0.07)))
                            if value > 0, top > 0 {
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                                    .fill(tint.gradient)
                                    .frame(height: max(radius * 2, height * value / top))
                                    .opacity(lit ? 1 : 0.4)
                            }
                        }
                        .overlay {
                            if current == index {
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                                    .strokeBorder(tint.opacity(0.7), lineWidth: 1)
                            }
                        }
                        .frame(width: width, height: height)
                        .scaleEffect(x: hovered == index ? 1.12 : 1, y: 1, anchor: .bottom)
                    }
                }
                if showsLabels {
                    ForEach(values.indices, id: \.self) { index in
                        let text = label(index)
                        if !text.isEmpty {
                            Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                .fixedSize()
                                .position(x: CGFloat(index) * (width + spacing) + width / 2, y: height + 3 + Self.labelHeight / 2)
                        }
                    }
                }
                if let hovered, values.indices.contains(hovered) {
                    let x = CGFloat(hovered) * (width + spacing) + width / 2
                    let barTop = top > 0 ? height - height * values[hovered] / top : height
                    TipBubble(text: tip(hovered))
                        .position(x: min(max(x, 44), max(44, geo.size.width - 44)), y: max(9, barTop - 13))
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let index = Int(point.x / (width + spacing))
                    hovered = values.indices.contains(index) ? index : nil
                case .ended:
                    hovered = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

/// A square a day as GitHub draws it, sized to fill what it is given: as many
/// weeks as fit, this month's days in full colour, earlier ones softer.
struct CommitCalendar: View {
    let days: [Date: Int]
    @State private var hovered: Date?

    var body: some View {
        GeometryReader { geo in
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let ratio: CGFloat = 0.24
            let cell = max(4, min(18, geo.size.height / (7 + 6 * ratio)))
            let gap = cell * ratio
            let weeks = max(1, Int((geo.size.width + gap) / (cell + gap)))
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
            let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
            let month = calendar.dateInterval(of: .month, for: today)!
            let top = max(1, days.filter { $0.key >= first }.values.max() ?? 1)
            // Right-aligned, so this week sits at the edge.
            let inset = geo.size.width - (CGFloat(weeks) * (cell + gap) - gap)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for week in 0..<weeks {
                        for weekday in 0..<7 {
                            let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: first)!
                            guard day <= today else { continue }
                            let rect = CGRect(x: inset + CGFloat(week) * (cell + gap), y: CGFloat(weekday) * (cell + gap),
                                              width: cell, height: cell)
                            let shape = Path(roundedRect: rect, cornerRadius: cell * 0.26, style: .continuous)
                            let soft = month.contains(day) ? 1 : 0.55
                            context.fill(shape, with: .color(CommitGrid.shade(days[day] ?? 0, top: top).opacity(soft)))
                            if hovered == day {
                                context.stroke(shape, with: .color(.primary.opacity(0.6)), lineWidth: 1.2)
                            }
                        }
                    }
                }
                if let hovered {
                    let week = calendar.dateComponents([.day], from: first, to: hovered).day! / 7
                    let weekday = calendar.dateComponents([.day], from: first, to: hovered).day! % 7
                    let x = inset + CGFloat(week) * (cell + gap) + cell / 2
                    TipBubble(text: L10n.t("\(days[hovered] ?? 0) commits on \(hovered.formatted(.dateTime.day().month(.abbreviated)))"))
                        .position(x: min(max(x, 56), max(56, geo.size.width - 56)), y: max(9, CGFloat(weekday) * (cell + gap) - 12))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let week = Int((point.x - inset) / (cell + gap))
                    let weekday = Int(point.y / (cell + gap))
                    guard point.x >= inset, (0..<weeks).contains(week), (0..<7).contains(weekday),
                          let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: first), day <= today
                    else { hovered = nil; return }
                    hovered = day
                case .ended:
                    hovered = nil
                }
            }
        }
        .accessibilityLabel(L10n.t("Commits per day"))
    }
}

/// A list row that lights up under the pointer.
struct HoverRow: ViewModifier {
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(inside ? 0.08 : 0)))
            .padding(.horizontal, -5)
            .onHover { inside = $0 }
            .animation(.easeOut(duration: 0.12), value: inside)
    }
}

extension View {
    func hoverRow() -> some View { modifier(HoverRow()) }
}
