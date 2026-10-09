import SwiftUI

/// The sky behind the dashboard, at this Mac's own hour, in the landing
/// page's pixels: a blue noon, a golden afternoon, a pink sunset, a starry
/// night with the moon up and fireflies over the meadow. The sun and the
/// moon cross it as the day goes; clouds drift, stars twinkle, grass sways.
///
/// With Reduce Motion it holds still and is only redrawn once a minute, so
/// the hour still shows.
struct DashboardSky: View {
    /// A fixed moment, for renders; nil follows the clock.
    var date: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let date {
                scene(at: date, moving: false)
            } else if reduceMotion {
                TimelineView(.periodic(from: .now, by: 60)) { scene(at: $0.date, moving: false) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15)) { scene(at: $0.date, moving: true) }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func scene(at date: Date, moving: Bool) -> some View {
        Canvas { context, size in
            SkyPainter(hour: SkyClock.hour(of: date), time: moving ? date.timeIntervalSinceReferenceDate : 0)
                .paint(&context, size: size)
        }
    }
}

/// The local hour as a fraction: 14.5 is half past two in the afternoon.
enum SkyClock {
    static func hour(of date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }

    /// The part of the day an hour is in, as the sky draws it.
    enum Part: Equatable { case night, dawn, morning, noon, afternoon, sunset, dusk }

    static func part(_ hour: Double) -> Part {
        switch hour {
        case 5..<6.8: return .dawn
        case 6.8..<11: return .morning
        case 11..<15: return .noon
        case 15..<17.3: return .afternoon
        case 17.3..<18.8: return .sunset
        case 18.8..<20.2: return .dusk
        default: return .night
        }
    }
}

/// One hour's light: the sky top to bottom, how bright the day is, and the
/// colour clouds take.
struct SkyLight {
    var top: SIMD3<Double>
    var middle: SIMD3<Double>
    var bottom: SIMD3<Double>
    var cloud: SIMD3<Double>
    var cloudAlpha: Double
    /// 0 at night, 1 at noon: dims the meadow, brings out the stars.
    var day: Double

    static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)) / 255
    }

    private static func key(_ top: UInt32, _ middle: UInt32, _ bottom: UInt32, cloud: UInt32, _ alpha: Double, day: Double) -> SkyLight {
        SkyLight(top: rgb(top), middle: rgb(middle), bottom: rgb(bottom), cloud: rgb(cloud), cloudAlpha: alpha, day: day)
    }

    /// The day's keyframes, by hour; the landing page's skies.
    static let keys: [(hour: Double, light: SkyLight)] = {
        let night = key(0x03061A, 0x0A1446, 0x1B2F75, cloud: 0x3A4675, 0.45, day: 0)
        return [
            (0, night),
            (4.6, night),
            (5.6, key(0x0B1240, 0x3A2E7A, 0xB06A9A, cloud: 0x8A6A9E, 0.6, day: 0.25)),
            (6.6, key(0x2A3F8F, 0xE58A7A, 0xFFD08A, cloud: 0xFFD6C2, 0.8, day: 0.6)),
            (8, key(0x2C6FD1, 0x5FA3EA, 0xBFE0FA, cloud: 0xFFFFFF, 0.9, day: 0.92)),
            (12, key(0x0F2F86, 0x3A7FD6, 0x8CC4F2, cloud: 0xFFFFFF, 0.92, day: 1)),
            (15.2, key(0x1B4BB0, 0x4F8FD8, 0xB9D7F2, cloud: 0xFFFFFF, 0.9, day: 0.95)),
            (16.6, key(0x1D3F96, 0x4F6FC0, 0xFFD27A, cloud: 0xFFF0D0, 0.88, day: 0.82)),
            (17.9, key(0x2A1B5E, 0xC04F8A, 0xFF9F5A, cloud: 0xFFC2A8, 0.85, day: 0.55)),
            (19, key(0x0B1240, 0x3A2C7E, 0xC08AC2, cloud: 0x9A86B8, 0.7, day: 0.28)),
            (20.3, night),
            (24, night),
        ]
    }()

    static func at(_ hour: Double) -> SkyLight {
        let hour = max(0, min(24, hour))
        guard let after = keys.firstIndex(where: { $0.hour >= hour }), after > 0 else { return keys[0].light }
        let (h0, a) = keys[after - 1]
        let (h1, b) = keys[after]
        let t = h1 > h0 ? (hour - h0) / (h1 - h0) : 0
        func mix(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> SIMD3<Double> { x + (y - x) * t }
        return SkyLight(top: mix(a.top, b.top), middle: mix(a.middle, b.middle), bottom: mix(a.bottom, b.bottom),
                        cloud: mix(a.cloud, b.cloud), cloudAlpha: a.cloudAlpha + (b.cloudAlpha - a.cloudAlpha) * t,
                        day: a.day + (b.day - a.day) * t)
    }
}

/// Draws the sky in square pixels.
struct SkyPainter {
    let hour: Double
    /// Seconds, for what moves; 0 holds everything still.
    let time: Double
    /// The side of one pixel, in points.
    var cell: CGFloat = 3

    static func color(_ rgb: SIMD3<Double>, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: alpha)
    }

    func paint(_ context: inout GraphicsContext, size: CGSize) {
        let light = SkyLight.at(hour)
        let ground = size.height - 4 * cell
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: Self.color(light.top), location: 0),
                             .init(color: Self.color(light.middle), location: 0.6),
                             .init(color: Self.color(light.bottom), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        let night = max(0, 1 - light.day * 2.2)
        if night > 0 { stars(&context, size: size, alpha: night) }
        if night > 0.4 { shootingStar(&context, size: size, alpha: night) }
        sun(&context, size: size, horizon: ground)
        moon(&context, size: size, horizon: ground, alpha: night)
        clouds(&context, size: size, light: light)
        meadow(&context, size: size, ground: ground, day: light.day)
        if night > 0.5 { fireflies(&context, size: size, ground: ground, alpha: night) }
    }

    // MARK: Pieces

    private func pixel(_ context: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ color: Color, w: CGFloat = 1, h: CGFloat = 1) {
        context.fill(Path(CGRect(x: (x / cell).rounded(.down) * cell, y: (y / cell).rounded(.down) * cell,
                                 width: w * cell, height: h * cell)), with: .color(color))
    }

    /// A seeded number in 0..<1, the same every frame.
    private static func noise(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed)) &* 0x9E3779B97F4A7C15 &+ 0x6D2B79F5
        x ^= x >> 33; x = x &* 0xFF51AFD7ED558CCD; x ^= x >> 33; x = x &* 0xC4CEB9FE1A85EC53; x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }

    private func stars(_ context: inout GraphicsContext, size: CGSize, alpha: Double) {
        let count = min(160, max(30, Int(size.width * size.height / 900)))
        for i in 0..<count {
            let x = Self.noise(i * 3) * size.width
            let y = Self.noise(i * 3 + 1) * size.height * 0.8
            let big = Self.noise(i * 3 + 2) < 0.12
            let twinkle = time == 0 ? 0.8 : 0.55 + 0.45 * sin(time * (1.2 + Self.noise(i) * 2.4) + Double(i))
            pixel(&context, x, y, Color(red: 1, green: 0.96, blue: 0.85).opacity(alpha * twinkle * (big ? 1 : 0.75)),
                  w: big ? 2 : 1, h: big ? 2 : 1)
        }
    }

    /// Now and then, a streak across the night.
    private func shootingStar(_ context: inout GraphicsContext, size: CGSize, alpha: Double) {
        guard time > 0 else { return }
        let every = 11.0
        let round = Int(time / every)
        let into = time - Double(round) * every
        guard into < 0.9 else { return }
        let start = CGPoint(x: size.width * (0.2 + 0.6 * Self.noise(round)), y: size.height * 0.15 * Self.noise(round + 7))
        let travel = CGFloat(into / 0.9)
        for step in 0..<8 {
            let t = travel - CGFloat(step) * 0.03
            guard t > 0 else { continue }
            pixel(&context, start.x - t * 140, start.y + t * 50, Color.white.opacity(alpha * (1 - Double(step) / 8)))
        }
    }

    /// Up at six, down at seven, across the sky between.
    private func sun(_ context: inout GraphicsContext, size: CGSize, horizon: CGFloat) {
        let rise = 5.9, set = 19.0
        guard hour > rise - 0.3, hour < set + 0.3 else { return }
        let p = (hour - rise) / (set - rise)
        let x = size.width * (0.06 + 0.88 * p)
        let height = sin(Double.pi * max(0, min(1, p)))
        let y = horizon - CGFloat(height) * (horizon - 22) + 6
        let low = 1 - height
        let disc = SIMD3<Double>(1, 0.95 - 0.35 * low, 0.69 - 0.4 * low)
        let glow = Gradient(colors: [Self.color(disc, 0.55), Self.color(disc, 0)])
        context.fill(Path(ellipseIn: CGRect(x: x - 70, y: y - 70, width: 140, height: 140)),
                     with: .radialGradient(glow, center: CGPoint(x: x, y: y), startRadius: 4, endRadius: 70))
        let r = 6
        for j in -r...r {
            for i in -r...r where i * i + j * j <= r * r + 3 {
                pixel(&context, x + CGFloat(i) * cell, y + CGFloat(j) * cell, Self.color(disc))
            }
        }
    }

    /// A crescent, up from dusk to dawn.
    private func moon(_ context: inout GraphicsContext, size: CGSize, horizon: CGFloat, alpha: Double) {
        guard alpha > 0.05 else { return }
        let night = hour >= 12 ? hour - 19.2 : hour + 4.8
        let p = max(0, min(1, night / 10.6))
        let x = size.width * (0.1 + 0.8 * p)
        let y = horizon - CGFloat(sin(Double.pi * p)) * (horizon - 24) + 4
        context.fill(Path(ellipseIn: CGRect(x: x - 50, y: y - 50, width: 100, height: 100)),
                     with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.94, blue: 0.75).opacity(0.22 * alpha), .clear]),
                                           center: CGPoint(x: x, y: y), startRadius: 2, endRadius: 50))
        let r = 5
        for j in -r...r {
            for i in -r...r {
                let disc = i * i + j * j <= r * r + 2
                let bite = (i - 3) * (i - 3) + (j + 2) * (j + 2) <= r * r - 5
                guard disc, !bite else { continue }
                let shade = i + j < -3 ? Color(red: 1, green: 0.97, blue: 0.86) : Color(red: 0.95, green: 0.9, blue: 0.72)
                pixel(&context, x + CGFloat(i) * cell, y + CGFloat(j) * cell, shade.opacity(alpha))
            }
        }
    }

    /// Cloud shapes, a row of pixels a line.
    private static let shapes: [[String]] = [
        ["   ####    ", " ########  ", "###########", " ######### "],
        ["  ###   ", " ###### ", "########"],
        ["     ####     ", "  ##########  ", " ############ ", "##############"],
    ]

    private func clouds(_ context: inout GraphicsContext, size: CGSize, light: SkyLight) {
        let tint = Self.color(light.cloud)
        let shade = Self.color(light.cloud * 0.86)
        let count = max(4, Int(size.width / 120))
        for i in 0..<count {
            let shape = Self.shapes[i % Self.shapes.count]
            let width = CGFloat(shape[0].count) * cell * 2
            let speed = 3 + Self.noise(i + 40) * 5
            let span = size.width + width * 2
            let x = (CGFloat(Self.noise(i + 20)) * span + CGFloat(time * speed)).truncatingRemainder(dividingBy: span) - width
            let y = size.height * CGFloat(0.06 + 0.62 * Self.noise(i + 60))
            let alpha = light.cloudAlpha * (0.55 + 0.45 * Self.noise(i + 80))
            for (row, line) in shape.enumerated() {
                for (col, mark) in line.enumerated() where mark == "#" {
                    let fill = row == shape.count - 1 ? shade : tint
                    pixel(&context, x + CGFloat(col) * cell * 2, y + CGFloat(row) * cell * 2, fill.opacity(alpha), w: 2, h: 2)
                }
            }
        }
    }

    private static let grass: [SIMD3<Double>] = [0x1F6B3A, 0x2B8A47, 0x36A254, 0x45B862, 0x5BCB74].map(SkyLight.rgb)
    private static let flowers: [(SIMD3<Double>, SIMD3<Double>)] = [
        (0xFF5D73, 0xFFD23F), (0xFFFFFF, 0xFFD23F), (0xFF9F45, 0x7A3A12), (0x8A7BFF, 0xFFF2B0), (0xFF7AC6, 0xFFFFFF),
    ].map { (SkyLight.rgb($0.0), SkyLight.rgb($0.1)) }

    /// Grass along the foot, swaying, with a flower here and there; darker
    /// as the light goes.
    private func meadow(_ context: inout GraphicsContext, size: CGSize, ground: CGFloat, day: Double) {
        let dim = 0.32 + 0.68 * day
        func lit(_ rgb: SIMD3<Double>) -> Color { Self.color(rgb * dim) }
        let columns = Int(size.width / cell) + 1
        context.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: size.height - ground)), with: .color(lit(Self.grass[1])))
        context.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: cell)), with: .color(lit(Self.grass[3])))
        context.fill(Path(CGRect(x: 0, y: size.height - cell, width: size.width, height: cell)),
                     with: .color(lit(SkyLight.rgb(0x4A3120))))
        for column in 0..<columns {
            let x = CGFloat(column) * cell
            guard Self.noise(column + 500) < 0.65 else { continue }
            let tall = 1 + Int(Self.noise(column + 900) * 3)
            let lean = time == 0 ? 0 : (sin(time * 1.6 + Double(column) * 0.35) > 0.7 ? cell : 0)
            let color = lit(Self.grass[2 + column % 3])
            for k in 0..<tall {
                pixel(&context, x + (k == tall - 1 ? lean : 0), ground - CGFloat(k + 1) * cell, color)
            }
        }
        var column = 4
        while column < columns - 3 {
            let (petal, heart) = Self.flowers[Int(Self.noise(column + 300) * Double(Self.flowers.count))]
            let x = CGFloat(column) * cell
            let top = ground - CGFloat(5 + Int(Self.noise(column + 700) * 2)) * cell
            context.fill(Path(CGRect(x: x, y: top + cell, width: cell, height: ground - top - cell)), with: .color(lit(Self.grass[0])))
            pixel(&context, x - cell, top, lit(petal), w: 3)
            pixel(&context, x, top - cell, lit(petal), h: 3)
            pixel(&context, x, top, lit(heart))
            column += 14 + Int(Self.noise(column + 100) * 18)
        }
    }

    private func fireflies(_ context: inout GraphicsContext, size: CGSize, ground: CGFloat, alpha: Double) {
        let count = max(6, Int(size.width / 60))
        for i in 0..<count {
            let blink = time == 0 ? 0.8 : max(0, sin(time * (0.8 + Self.noise(i + 10)) + Double(i) * 1.7))
            guard blink > 0.05 else { continue }
            let drift = time == 0 ? 0 : CGFloat(sin(time * 0.4 + Double(i))) * 10
            let x = CGFloat(Self.noise(i + 200)) * size.width + drift
            let y = ground - 6 - CGFloat(Self.noise(i + 210)) * 30 + drift * 0.5
            let center = CGPoint(x: x, y: y)
            context.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)),
                         with: .radialGradient(Gradient(colors: [Color(red: 0.9, green: 1, blue: 0.35).opacity(0.5 * alpha * blink), .clear]),
                                               center: center, startRadius: 0, endRadius: 7))
            pixel(&context, x, y, Color(red: 0.97, green: 1, blue: 0.48).opacity(alpha * blink))
        }
    }
}
