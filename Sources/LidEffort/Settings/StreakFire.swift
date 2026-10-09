import SwiftUI

/// The fire in the Streak card: none before ten days, then a flame along its
/// foot that grows at each milestone (10, 50, 100, 150 and 365 days) until,
/// at a year, it fills the card, sparks fly and the frame glows.
struct StreakFire: View {
    let level: Int
    /// A fixed moment, for renders; nil follows the clock.
    var date: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Days a streak must reach for each bigger flame.
    static let milestones = [10, 50, 100, 150, 365]

    /// How many milestones a streak has passed, 0 to 5.
    static func level(_ days: Int) -> Int { milestones.filter { days >= $0 }.count }

    /// The next milestone, or nil past a year.
    static func next(_ days: Int) -> Int? { milestones.first { days < $0 } }

    /// The flame's height as a share of the card, by level.
    static func reach(_ level: Int) -> CGFloat {
        [0, 0.14, 0.24, 0.36, 0.48, 0.6][max(0, min(5, level))]
    }

    var body: some View {
        if level > 0 {
            ZStack {
                if let date {
                    flames(at: date.timeIntervalSinceReferenceDate)
                } else if reduceMotion {
                    flames(at: 0)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { flames(at: $0.date.timeIntervalSinceReferenceDate) }
                }
                // The frame warms with the fire, and burns at a year.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.15 + 0.13 * Double(level)), lineWidth: level >= 4 ? 2 : 1.2)
                    .shadow(color: .orange.opacity(level >= 3 ? 0.6 : 0), radius: CGFloat(level) * 2)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func flames(at time: Double) -> some View {
        Canvas { context, size in
            FirePainter(level: level, time: time).paint(&context, size: size)
        }
    }
}

/// Square-pixel flames, white-hot at the root and red at the tips.
struct FirePainter {
    let level: Int
    let time: Double
    var cell: CGFloat = 3

    private static let heat: [(Double, Color)] = [
        (0.0, Color(red: 1, green: 0.98, blue: 0.82)),
        (0.18, Color(red: 1, green: 0.88, blue: 0.3)),
        (0.45, Color(red: 1, green: 0.58, blue: 0.1)),
        (0.75, Color(red: 0.93, green: 0.27, blue: 0.08)),
        (1.0, Color(red: 0.6, green: 0.08, blue: 0.05)),
    ]

    private static func color(_ t: Double) -> Color {
        Self.heat.last { $0.0 <= t }?.1 ?? Self.heat[0].1
    }

    private static func noise(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed)) &* 0x9E3779B97F4A7C15 &+ 0x6D2B79F5
        x ^= x >> 33; x = x &* 0xFF51AFD7ED558CCD; x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }

    func paint(_ context: inout GraphicsContext, size: CGSize) {
        let top = size.height * StreakFire.reach(level)
        guard top > 0 else { return }
        let columns = Int(size.width / cell) + 1
        // A glow behind the flames.
        context.fill(Path(CGRect(x: 0, y: size.height - top * 1.3, width: size.width, height: top * 1.3)),
                     with: .linearGradient(Gradient(colors: [.clear, Color.orange.opacity(0.18 + 0.05 * Double(level))]),
                                           startPoint: CGPoint(x: 0, y: size.height - top * 1.3),
                                           endPoint: CGPoint(x: 0, y: size.height)))
        for column in 0..<columns {
            let x = Double(column)
            // Tongues: a few slow waves and a fast flicker, never the same twice.
            let wave = 0.55 + 0.25 * sin(x * 0.21 + time * 2.1) + 0.15 * sin(x * 0.57 - time * 3.7)
                + 0.1 * sin(time * 9 + Self.noise(column) * 6.3)
            let height = max(cell, top * CGFloat(min(1.15, max(0.15, wave))))
            let rows = Int(height / cell)
            for row in 0..<rows {
                let t = Double(row) / Double(max(1, rows - 1))
                // The tips break up into separate pixels.
                if t > 0.7, Self.noise(column * 131 + row * 17 + Int(time * 12)) < (t - 0.7) * 2.2 { continue }
                let y = size.height - CGFloat(row + 1) * cell
                context.fill(Path(CGRect(x: CGFloat(column) * cell, y: y, width: cell, height: cell)),
                             with: .color(Self.color(t).opacity(0.92 - 0.35 * t)))
            }
        }
        // Sparks, from a hundred days on.
        guard level >= 3 else { return }
        let sparks = 6 * (level - 2)
        for i in 0..<sparks {
            let life = 1.6 + Self.noise(i + 50) * 1.4
            let phase = (time / life + Self.noise(i)).truncatingRemainder(dividingBy: 1)
            let x = CGFloat(Self.noise(i + 90)) * size.width + CGFloat(sin(time * 2 + Double(i))) * 6
            let y = size.height - top * 0.6 - CGFloat(phase) * (size.height - top * 0.6 + 6)
            guard y > 0 else { continue }
            let size = cell * (Self.noise(i + 70) < 0.3 ? 2 : 1)
            context.fill(Path(CGRect(x: (x / cell).rounded() * cell, y: (y / cell).rounded() * cell, width: size, height: size)),
                         with: .color(Color(red: 1, green: 0.8, blue: 0.3).opacity(1 - phase)))
        }
    }
}
