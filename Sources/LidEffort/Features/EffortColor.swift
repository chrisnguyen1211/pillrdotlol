import LidEffortCore
import SwiftUI

/// One colour per effort level, on a heat scale: the calmer the level, the
/// cooler the colour. Read off the model's own scale as a fraction, so the
/// top of a four-level scale and the top of a six-level one are the same
/// red, and "half way" is the same green on both.
enum EffortColor {
    /// Stops from lowest to highest effort.
    private static let stops: [(r: Double, g: Double, b: Double)] = [
        (0.04, 0.52, 1.00),   // blue
        (0.00, 0.85, 0.55),   // green
        (0.95, 0.85, 0.10),   // yellow
        (1.00, 0.55, 0.10),   // orange
        (1.00, 0.25, 0.20),   // red
    ]

    static func color(fraction: Double) -> Color {
        let clamped = min(max(fraction, 0), 1)
        let position = clamped * Double(stops.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, stops.count - 1)
        let t = position - Double(lower)
        let a = stops[lower], b = stops[upper]
        return Color(red: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t)
    }

    /// The lid's own five levels.
    static func color(level: EffortLevel) -> Color {
        color(fraction: Double(level.rawValue) / Double(EffortLevel.allCases.count - 1))
    }

    /// Where a value sits on its model's scale: `filled` of `count`.
    static func color(filled: Int, of count: Int) -> Color {
        guard count > 1 else { return color(fraction: 1) }
        return color(fraction: Double(max(filled, 1) - 1) / Double(count - 1))
    }
}
