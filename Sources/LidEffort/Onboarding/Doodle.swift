import SwiftUI

/// Hand-drawn strokes for the intro tour: lines that wobble the way a pen
/// does, arrows with a flicked head, a loop scribbled round something.
///
/// Every wobble comes from a seed, so a doodle is the same drawing every
/// time it is drawn — a line that re-jittered on each frame would shimmer
/// instead of looking drawn.
enum Doodle {
    /// The tour's palette: ink for drawing on paper, a marker yellow for
    /// drawing on the screen itself, where anything could be underneath.
    static let ink = Color(red: 0.13, green: 0.13, blue: 0.17)
    static let paper = Color(red: 1, green: 0.984, blue: 0.94)
    static let marker = Color(red: 1, green: 0.81, blue: 0.18)
    static let blue = Color(red: 0.22, green: 0.52, blue: 1)
    static let green = Color(red: 0.36, green: 0.84, blue: 0.56)

    /// The hand the tour writes in. Noteworthy ships with every Mac.
    static func hand(_ size: CGFloat) -> Font { .custom("Noteworthy-Bold", size: size) }

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

    /// A pen line through the points: resampled every so often and nudged,
    /// then smoothed — close enough to straight to read as meant, loose
    /// enough to read as drawn.
    static func line(_ points: [CGPoint], seed: UInt64, wobble: CGFloat = 1.3, step: CGFloat = 26) -> Path {
        var rng = Random(seed)
        var sampled: [CGPoint] = []
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                let wobbleHere = (i == 0 && k == 0) ? 0 : wobble
                sampled.append(CGPoint(x: a.x + (b.x - a.x) * t + rng.jitter(wobbleHere),
                                       y: a.y + (b.y - a.y) * t + rng.jitter(wobbleHere)))
            }
        }
        sampled.append(points[points.count - 1])
        return smooth(sampled)
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

    /// An arrow's shaft along a bowed curve, and its head: two flicks back
    /// from the tip, not quite equal, the way a hand draws them.
    static func arrow(from a: CGPoint, to b: CGPoint, bend: CGFloat, seed: UInt64,
                      head: CGFloat = 16) -> (shaft: Path, head: Path) {
        let points = curve(from: a, to: b, bend: bend)
        // A short arrow drawn with a long one's shake reads as a squiggle.
        let length = hypot(b.x - a.x, b.y - a.y)
        let shaft = line(points, seed: seed, wobble: min(1.6, length / 110), step: max(24, length / 7))
        let tip = points[points.count - 1], back = points[points.count - 3]
        let angle = atan2(tip.y - back.y, tip.x - back.x)
        var rng = Random(seed &+ 7)
        var headPath = Path()
        for (side, spread) in [(-1.0, 0.52), (1.0, 0.46)] {
            let a2 = angle + .pi - CGFloat(side) * CGFloat(spread)
            let length = head * (0.9 + rng.next() * 0.25)
            headPath.move(to: tip)
            headPath.addQuadCurve(to: CGPoint(x: tip.x + cos(a2) * length, y: tip.y + sin(a2) * length),
                                  control: CGPoint(x: tip.x + cos(a2 + 0.08) * length * 0.55 + rng.jitter(1.5),
                                                   y: tip.y + sin(a2 + 0.08) * length * 0.55 + rng.jitter(1.5)))
        }
        return (shaft, headPath)
    }

    /// A loop scribbled round something: a little more than once round, the
    /// radius drifting, the ends not meeting.
    static func loop(around rect: CGRect, seed: UInt64, turns: CGFloat = 1.14) -> Path {
        var rng = Random(seed)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let start = rng.next() * .pi * 2
        let steps = 22
        let points = (0...steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps)
            let angle = start + t * turns * 2 * .pi
            let drift = 1 + rng.jitter(0.045) + t * 0.05
            return CGPoint(x: centre.x + cos(angle) * rect.width / 2 * drift,
                           y: centre.y + sin(angle) * rect.height / 2 * drift)
        }
        return smooth(points)
    }

    /// The outline walked at an even pace. A smooth curve through points
    /// bunched at the corners and sparse along the sides overshoots where
    /// the two meet, and drew little crosses at every corner.
    static func resample(_ points: [CGPoint], every spacing: CGFloat, closed: Bool) -> [CGPoint] {
        let ring = closed ? points + [points[0]] : points
        var out: [CGPoint] = [ring[0]]
        var carry: CGFloat = 0
        for i in 0..<(ring.count - 1) {
            let a = ring[i], b = ring[i + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            var d = spacing - carry
            while d <= length {
                let t = d / length
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                d += spacing
            }
            carry = length - (d - spacing)
        }
        if closed, let last = out.last, hypot(last.x - ring[0].x, last.y - ring[0].y) < spacing / 2 { out.removeLast() }
        return out
    }

    /// A rounded rectangle drawn freehand, for paper edges and boxes.
    static func box(_ rect: CGRect, radius: CGFloat, seed: UInt64, wobble: CGFloat = 1.1) -> Path {
        var rng = Random(seed)
        var points: [CGPoint] = []
        let r = min(radius, rect.width / 2, rect.height / 2)
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: rect.maxX - r, y: rect.minY + r), -.pi / 2),
            (CGPoint(x: rect.maxX - r, y: rect.maxY - r), 0),
            (CGPoint(x: rect.minX + r, y: rect.maxY - r), .pi / 2),
            (CGPoint(x: rect.minX + r, y: rect.minY + r), .pi),
        ]
        for (centre, start) in corners {
            for k in 0...6 {
                let angle = start + CGFloat(k) / 6 * .pi / 2
                points.append(CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r))
            }
        }
        let even = resample(points, every: max(6, min(rect.width, rect.height) / 8), closed: true)
            .map { CGPoint(x: $0.x + rng.jitter(wobble * 0.6), y: $0.y + rng.jitter(wobble * 0.6)) }
        return smooth(even, closed: true)
    }

    /// A four-point sparkle.
    static func sparkle(at c: CGPoint, size s: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - s))
        path.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + s * 0.18, y: c.y - s * 0.18))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + s * 0.18, y: c.y + s * 0.18))
        path.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - s * 0.18, y: c.y + s * 0.18))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - s * 0.18, y: c.y - s * 0.18))
        return path
    }
}

/// A marker stroke on the screen: yellow over a soft dark halo, so it reads
/// over a white document and a black terminal alike. Drawn on, not shown —
/// against a clock the tour keeps, so rebuilding the view mid-stroke picks
/// the drawing up where it was rather than starting it over.
struct MarkerStroke: View {
    let path: Path
    var width: CGFloat = 4.5
    var dash: [CGFloat] = []
    var delay: Double = 0
    /// When the drawing began.
    var since: Date = .distantPast
    static let duration: Double = 0.7

    var body: some View {
        let finished = Date().timeIntervalSince(since) > delay + Self.duration
        TimelineView(.animation(minimumInterval: 1 / 60, paused: finished)) { context in
            let drawn = Self.progress(at: context.date, since: since, delay: delay)
            ZStack {
                path.trim(from: 0, to: drawn)
                    .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: width + 4, lineCap: .round, lineJoin: .round, dash: dash))
                    .blur(radius: 1.5)
                path.trim(from: 0, to: drawn)
                    .stroke(Doodle.marker, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            }
        }
    }

    /// Eased out: quick off the mark, settling as the pen lifts.
    static func progress(at date: Date, since: Date, delay: Double) -> CGFloat {
        let x = min(1, max(0, (date.timeIntervalSince(since) - delay) / duration))
        return CGFloat(1 - (1 - x) * (1 - x))
    }
}

/// An ink stroke on paper.
struct InkStroke: View {
    let path: Path
    var width: CGFloat = 2.4
    var color: Color = Doodle.ink

    var body: some View {
        path.stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
