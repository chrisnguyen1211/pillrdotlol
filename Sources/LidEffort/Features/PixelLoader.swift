import SwiftUI

/// A pixel-grid loader for work in progress: a 3×3 grid with a chevron
/// wavefront driving right. Each cell lights on its own delay — its column
/// plus how far its row is from the middle, 90 ms a step — and the cycle
/// (650 ms) is shorter than the sweep, so two fronts are always in flight.
/// Under Reduce Motion the grid holds its dim state.
struct PixelLoader: View {
    var color: Color = Palette.textPrimary
    var round = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cycle: Double = 0.65
    static let step: Double = 0.09
    static let dim: Double = 0.15
    /// 30 frames a second: a 650 ms pulse reads just as smooth, for half
    /// the redraws of the display's full rate.
    static let frameInterval: Double = 1.0 / 30

    /// The chevron: column, plus distance from the middle row.
    static func delay(cell: Int) -> Double {
        let row = cell / 3, column = cell % 3
        return Double(column + abs(row - 1)) * step
    }

    /// How lit a cell is at time `t`: dim, up to full and back down once
    /// per cycle, easing in and out.
    static func opacity(cell: Int, at t: TimeInterval) -> Double {
        let phase = ((t - delay(cell: cell)).truncatingRemainder(dividingBy: cycle) + cycle)
            .truncatingRemainder(dividingBy: cycle) / cycle
        let pulse = pow(sin(.pi * phase), 2)
        return dim + (1 - dim) * pulse
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            // Cells 4, gaps 1.5: the grid is 15 wide in those units.
            let unit = side / 15
            let cell = 4 * unit, gap = 1.5 * unit
            if reduceMotion {
                grid(cell: cell, gap: gap) { _ in Self.dim }
            } else {
                TimelineView(.animation(minimumInterval: PixelLoader.frameInterval)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    grid(cell: cell, gap: gap) { Self.opacity(cell: $0, at: t) }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func grid(cell: CGFloat, gap: CGFloat, opacity: @escaping (Int) -> Double) -> some View {
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        RoundedRectangle(cornerRadius: round ? cell / 2 : cell / 4, style: .continuous)
                            .fill(color)
                            .frame(width: cell, height: cell)
                            .opacity(opacity(index))
                    }
                }
            }
        }
    }
}

/// A label with light sweeping through it — the running state's word.
struct ShimmerText: View {
    let text: String
    var base: Color = Palette.textSecondary
    var highlight: Color = Palette.textPrimary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let period: Double = 1.4

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(highlight)
        } else {
            TimelineView(.animation(minimumInterval: PixelLoader.frameInterval)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: Self.period) / Self.period
                // The bright band crosses from right to left over a gradient
                // twice the text's width, as a background-position sweep does.
                let centre = 1.5 - 2 * phase
                Text(text)
                    .foregroundStyle(LinearGradient(
                        stops: [
                            .init(color: base, location: centre - 0.3),
                            .init(color: highlight, location: centre),
                            .init(color: base, location: centre + 0.3),
                        ],
                        startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}

/// How long it has been running, in tenths, ticking — mono figures so the
/// digits do not jitter as they change.
struct ElapsedClock: View {
    let since: Date
    var color: Color = Palette.textSecondary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Text(ElapsedCopy.clock(since: since, now: context.date))
                .font(Typography.clock)
                .foregroundStyle(color)
        }
    }
}
