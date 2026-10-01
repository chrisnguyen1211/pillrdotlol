import SwiftUI

/// When everything in the Liquid Glass intro happens — shared by the picture
/// and the sound, so a drop lands on its plip and the drone opens on the name.
enum IntroTimeline {
    static let length: TimeInterval = 14.6
    /// The drops meet the gathering pill, one by one.
    static let drops: [Double] = [1.35, 1.75, 2.08, 2.38, 2.62, 2.84]
    /// Liquid becomes glass.
    static let glassFrom: Double = 2.9, glassTo: Double = 3.7
    /// Every agent it reads runs past inside the pill, quicker and quicker,
    /// then slows and settles on yours.
    static let scrollFrom: Double = 3.7, scrollTo: Double = 9.2
    /// The name, on the bowl — and held long enough to be read.
    static let strike: Double = 9.2
    /// Small, and home into the folded pill on the edge.
    static let flyFrom: Double = 12.0, flyTo: Double = 13.6
    /// The real pill shows as this one lands on it.
    static let reveal: Double = 13.45

    /// Distance between two agents in the scroll.
    static let pitch: CGFloat = 84

    /// How far the scroll has run: slow off the mark, fastest just past the
    /// middle, easing to a stop — 1 − (1 − x²)², whose speed is zero at both
    /// ends and peaks at x = 1/√3.
    ///
    /// Gentler than that at the start: the first agents go by one at a time,
    /// slowly enough to be named, before the run quickens.
    static func scrolled(_ t: Double, total: CGFloat) -> CGFloat {
        CGFloat(shape(progress(t))) * total
    }

    private static func progress(_ t: Double) -> Double {
        min(1, max(0, (t - scrollFrom) / (scrollTo - scrollFrom)))
    }

    /// 1 − (1 − x^1.6)²: slow off the mark, fastest around two thirds of
    /// the way, easing to rest.
    private static func shape(_ x: Double) -> Double { 1 - pow(1 - pow(x, 1.6), 2) }

    /// How fast, as a share of the fastest it goes — for blur and loudness.
    static func speed(_ t: Double) -> Double {
        let x = progress(t)
        guard x > 0, x < 1 else { return 0 }
        return slope(x) / peakSlope
    }

    private static func slope(_ x: Double) -> Double {
        let dx = 0.001
        let ahead: Double = shape(min(1, x + dx))
        let behind: Double = shape(max(0, x - dx))
        return (ahead - behind) / (2 * dx)
    }

    private static let peakSlope: Double = {
        var best = 0.0
        for step in 0...200 { best = max(best, slope(Double(step) / 200)) }
        return best
    }()

    /// Items scrolled past before the reader's own agents land: three laps
    /// of every mark spyx knows.
    static let laps = 1

    /// Every mark spyx reads, in the order the scroll runs them.
    static let scrollGlyphs: [ProviderGlyph] = [
        .claude, .openai, .cursor, .antigravity, .grok, .copilot, .devin, .deepseek, .kimi, .glm,
        .qwen, .mistral, .geminiSpark, .opencode, .commandcode, .meta, .ollama, .lmstudio, .gemma,
    ]

    /// How far the scroll runs before the reader's own agents are in place.
    static var scrollDistance: CGFloat { CGFloat(laps * scrollGlyphs.count) * pitch }

    // MARK: The drops

    /// One drop: where it comes from, when it sets off, and when it touches
    /// the pill — the moment its bloop sounds.
    struct Drop {
        let angle: Double
        let far: Double
        let leave: Double
        let arrive: Double
        let radius: CGFloat
    }

    static let dropPaths: [Drop] = {
        var rng = Doodle.Random(7)
        return drops.enumerated().map { k, arrive in
            let angle = Double(k) / Double(drops.count) * 2 * .pi + Double(rng.jitter(0.4))
            let far = 420 + Double(rng.next()) * 180
            return Drop(angle: angle, far: far, leave: 0.3 + Double(k) * 0.12, arrive: arrive,
                        radius: CGFloat(22 + Double(k % 3) * 8))
        }
    }()

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// How far the gathering pill has grown.
    static func pillExtent(_ t: Double, pill: CGSize) -> CGSize {
        let g = smooth(1.1, glassFrom, t)
        return CGSize(width: pill.width * CGFloat(0.35 + 0.65 * g), height: pill.height * CGFloat(0.2 + 0.8 * g))
    }

    /// How far from the pill's centre a drop just touches it, along its line.
    static func touchDistance(_ drop: Drop, pill: CGSize) -> Double {
        let size = pillExtent(drop.arrive, pill: pill)
        let a = drop.angle
        let edge = 1 / ((cos(a) / Double(size.width / 2)) * (cos(a) / Double(size.width / 2))
                        + (sin(a) / Double(size.height / 2)) * (sin(a) / Double(size.height / 2))).squareRoot()
        return edge + Double(drop.radius) - 4
    }

    /// Where a drop is at `t`, and how big — nil before it appears and once
    /// it has sunk into the pill. It touches the pill's edge exactly at
    /// `arrive`, which is where the sound puts its bloop.
    static func drop(_ drop: Drop, at t: Double, centre: CGPoint, pill: CGSize) -> (point: CGPoint, radius: CGFloat)? {
        let grow = smooth(drop.leave - 0.2, drop.leave + 0.3, t)
        guard grow > 0 else { return nil }
        var radius = drop.radius * CGFloat(0.4 + 0.6 * grow)
        let touch = touchDistance(drop, pill: pill)
        var angle = drop.angle
        let reach: Double
        if t <= drop.arrive {
            // Drawn in, quickening as it nears, along a gentle curve that
            // straightens by the time it touches.
            let x = min(1, max(0, (t - drop.leave) / (drop.arrive - drop.leave)))
            reach = touch + (drop.far - touch) * (1 - x * x)
            angle += sin(x * .pi) * 0.5
        } else {
            // Then sinking into the pill.
            let s = smooth(drop.arrive, drop.arrive + 0.35, t)
            guard s < 1 else { return nil }
            reach = touch * (1 - s)
            radius *= CGFloat(1 - 0.5 * s)
        }
        return (CGPoint(x: centre.x + CGFloat(cos(angle) * reach), y: centre.y + CGFloat(sin(angle) * reach)), radius)
    }
}
