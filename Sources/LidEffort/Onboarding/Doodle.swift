import SwiftUI

/// The curves the glass tour draws with: the bowed line of light from its
/// card to the pill, and the seeded randomness the intro's film scatters
/// its pieces with — the same every time it plays.
enum Doodle {
    struct Random {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> CGFloat {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return CGFloat(z % 10_000) / 10_000
        }
        /// −amount…amount.
        mutating func jitter(_ amount: CGFloat) -> CGFloat { (next() * 2 - 1) * amount }
    }

    /// A smooth curve through every point (Catmull-Rom).
    static func smooth(_ points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let pts = closed ? [points[points.count - 1]] + points + [points[0], points[1]]
                         : [points[0]] + points + [points[points.count - 1]]
        path.move(to: pts[1])
        for i in 1..<(pts.count - 2) {
            let p0 = pts[i - 1], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
        return path
    }

    /// Points along a curve from `a` to `b`, bowed sideways by `bend` of its
    /// length — positive bows to the left of the direction of travel.
    static func curve(from a: CGPoint, to b: CGPoint, bend: CGFloat, samples: Int = 14) -> [CGPoint] {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { return [a, b] }
        let normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
        let control = CGPoint(x: mid.x + normal.x * bend * length, y: mid.y + normal.y * bend * length)
        return (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples)
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                           y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        }
    }
}

/// How far a line the tour draws has got: drawn on against a clock the tour
/// keeps, so rebuilding the view mid-stroke picks it up where it was.
enum MarkerStroke {
    static let duration: Double = 0.7

    /// Eased out: quick off the mark, settling as the pen lifts.
    static func progress(at date: Date, since: Date, delay: Double) -> CGFloat {
        let x = min(1, max(0, (date.timeIntervalSince(since) - delay) / duration))
        return CGFloat(1 - (1 - x) * (1 - x))
    }
}
