import SwiftUI

/// A badge as a struck medal, after the Fitness awards: each family its own
/// shape and enamel, the tier its metal. Bronze is plain, silver adds a
/// second rim, gold rays out behind; one to three stars on the rim say the
/// tier at a glance. The pointer on it sends a shine across.
struct Medal: View {
    let badge: Achievements.Badge
    let earned: Bool
    let size: CGFloat
    /// Sends a shine across, each time it turns true.
    var shine = false
    @State private var sweep: CGFloat = -1.2

    var body: some View {
        let style = BadgeStyle.of(badge.family)
        let metal = BadgeMetal(tier: badge.tier, earned: earned)
        let shape = BadgeShape(kind: style.shape)
        ZStack {
            if badge.tier == .gold && earned {
                Rays(count: 16)
                    .fill(RadialGradient(colors: [metal.light.opacity(0.75), metal.light.opacity(0)],
                                         center: .center, startRadius: size * 0.2, endRadius: size * 0.62))
                    .frame(width: size * 1.22, height: size * 1.22)
            }
            // The rim, struck metal catching the light around it.
            shape
                .fill(AngularGradient(colors: [metal.light, metal.mid, metal.dark, metal.mid, metal.light, metal.mid,
                                               metal.dark, metal.mid, metal.light], center: .center, angle: .degrees(-35)))
                .shadow(color: .black.opacity(earned ? 0.28 : 0.08), radius: size * 0.05, y: size * 0.03)
            shape
                .stroke(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0), .black.opacity(0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1, size * 0.025))
            if badge.tier >= .silver {
                shape.scale(0.88)
                    .stroke(metal.dark.opacity(0.55), lineWidth: max(0.6, size * 0.012))
            }
            // The enamel face.
            shape.scale(0.74)
                .fill(LinearGradient(colors: earned ? [style.light, style.dark] : [Color.gray.opacity(0.5), Color.gray.opacity(0.35)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.scale(0.74).stroke(.black.opacity(0.28), lineWidth: max(1, size * 0.03)).blur(radius: size * 0.015)
                    .mask(shape.scale(0.74)))
            shape.scale(0.74)
                .stroke(metal.light.opacity(0.9), lineWidth: max(0.8, size * 0.02))
            // Struck into the face.
            Image(systemName: Achievements.family(badge.family)?.symbol ?? "star.fill")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.white, metal.light], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.4), radius: size * 0.01, y: size * 0.02)
                .offset(y: -size * 0.02)
            // A gloss over the top half.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0)], startPoint: .top, endPoint: .center))
                .frame(width: size * 0.9, height: size * 0.62)
                .offset(y: -size * 0.2)
                .mask(shape)
                .allowsHitTesting(false)
            // The shine, masked to the medal.
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: size * 0.3, height: size * 1.6)
                .rotationEffect(.degrees(24))
                .offset(x: sweep * size)
                .mask(shape)
                .allowsHitTesting(false)
            stars(metal)
                .offset(y: size * 0.43)
        }
        .frame(width: size, height: size)
        .opacity(earned ? 1 : 0.55)
        .onChange(of: shine) { _, on in
            guard on else { return }
            sweep = -1.2
            withAnimation(.easeInOut(duration: 0.85)) { sweep = 1.2 }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Achievements.name(badge)), \(badge.tier.name)")
    }

    /// One star for bronze, two for silver, three for gold, on the rim's foot.
    private func stars(_ metal: BadgeMetal) -> some View {
        HStack(spacing: size * 0.012) {
            ForEach(0..<badge.tier.rawValue, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.1, weight: .black))
                    .foregroundStyle(LinearGradient(colors: [.white, metal.light], startPoint: .top, endPoint: .bottom))
            }
        }
        .padding(.horizontal, size * 0.05).padding(.vertical, size * 0.02)
        .background(Capsule().fill(LinearGradient(colors: [metal.mid, metal.dark], startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().stroke(metal.light.opacity(0.8), lineWidth: max(0.5, size * 0.01)))
        .shadow(color: .black.opacity(0.3), radius: size * 0.015, y: size * 0.01)
    }
}

/// The metal of a tier: its highlight, body and shadow.
struct BadgeMetal {
    let light: Color
    let mid: Color
    let dark: Color

    init(tier: Achievements.Tier, earned: Bool) {
        guard earned else {
            light = Color(white: 0.85); mid = Color(white: 0.7); dark = Color(white: 0.55)
            return
        }
        switch tier {
        case .bronze:
            light = Color(red: 1.0, green: 0.8, blue: 0.62)
            mid = Color(red: 0.8, green: 0.5, blue: 0.28)
            dark = Color(red: 0.5, green: 0.27, blue: 0.12)
        case .silver:
            light = Color(red: 0.98, green: 0.99, blue: 1.0)
            mid = Color(red: 0.75, green: 0.78, blue: 0.83)
            dark = Color(red: 0.46, green: 0.5, blue: 0.56)
        case .gold:
            light = Color(red: 1.0, green: 0.95, blue: 0.66)
            mid = Color(red: 0.95, green: 0.74, blue: 0.22)
            dark = Color(red: 0.65, green: 0.43, blue: 0.05)
        }
    }
}

/// Each family's shape and enamel.
struct BadgeStyle {
    let shape: BadgeShape.Kind
    let light: Color
    let dark: Color

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    private init(_ shape: BadgeShape.Kind, _ light: UInt32, _ dark: UInt32) {
        self.shape = shape
        self.light = Self.rgb(light)
        self.dark = Self.rgb(dark)
    }

    static let styles: [String: BadgeStyle] = [
        "hours": .init(.circle, 0x4FD1E8, 0x0E7490),
        "dayHours": .init(.shield, 0xFF8A4C, 0xC2410C),
        "commits": .init(.hexagon, 0x5EE38A, 0x15803D),
        "dayCommits": .init(.diamond, 0xB18CFF, 0x6D28D9),
        "streak": .init(.rosette, 0xFFB347, 0xD9480F),
        "lines": .init(.octagon, 0x8B9CFF, 0x3730A3),
        "parallel": .init(.hexagon, 0x5CC8FF, 0x0369A1),
        "answers": .init(.circle, 0xFF7EB6, 0xBE185D),
        "finished": .init(.rosette, 0x6EE7B7, 0x047857),
        "early": .init(.pentagon, 0xFFA98A, 0xE0567A),
        "late": .init(.shield, 0x6A7BFF, 0x1E2A78),
        "tokenMaxxer": .init(.octagon, 0xFF6B6B, 0xB91C1C),
        "bigDay": .init(.circle, 0x4ADE80, 0x166534),
        "keys": .init(.shield, 0xFCD34D, 0xB45309),
        "plans": .init(.squircle, 0xC084FC, 0x7E22CE),
        "thrifty": .init(.rosette, 0xBEF264, 0x4D7C0F),
    ]

    static func of(_ family: String) -> BadgeStyle { styles[family] ?? .init(.circle, 0x9CA3AF, 0x4B5563) }
}

/// The outline a badge is struck in.
struct BadgeShape: Shape {
    enum Kind { case circle, hexagon, octagon, pentagon, diamond, shield, rosette, squircle }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        switch kind {
        case .circle:
            return Path(ellipseIn: box)
        case .hexagon:
            return Self.polygon(in: box, sides: 6, rotation: 0, corner: side * 0.08)
        case .octagon:
            return Self.polygon(in: box, sides: 8, rotation: .pi / 8, corner: side * 0.06)
        case .pentagon:
            return Self.polygon(in: box, sides: 5, rotation: -.pi / 2, corner: side * 0.08)
        case .diamond:
            return Path(roundedRect: box.insetBy(dx: side * 0.15, dy: side * 0.15), cornerRadius: side * 0.12, style: .continuous)
                .applying(CGAffineTransform(translationX: -box.midX, y: -box.midY)
                    .concatenating(CGAffineTransform(rotationAngle: .pi / 4))
                    .concatenating(CGAffineTransform(translationX: box.midX, y: box.midY)))
        case .squircle:
            return Path(roundedRect: box.insetBy(dx: side * 0.05, dy: side * 0.05), cornerRadius: side * 0.28, style: .continuous)
        case .shield:
            var path = Path()
            let w = box.width, h = box.height, x = box.minX, y = box.minY
            path.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.02))
            path.addCurve(to: CGPoint(x: x + w * 0.94, y: y + h * 0.2),
                          control1: CGPoint(x: x + w * 0.66, y: y + h * 0.13), control2: CGPoint(x: x + w * 0.82, y: y + h * 0.16))
            path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.98),
                          control1: CGPoint(x: x + w * 0.96, y: y + h * 0.6), control2: CGPoint(x: x + w * 0.76, y: y + h * 0.84))
            path.addCurve(to: CGPoint(x: x + w * 0.06, y: y + h * 0.2),
                          control1: CGPoint(x: x + w * 0.24, y: y + h * 0.84), control2: CGPoint(x: x + w * 0.04, y: y + h * 0.6))
            path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.02),
                          control1: CGPoint(x: x + w * 0.18, y: y + h * 0.16), control2: CGPoint(x: x + w * 0.34, y: y + h * 0.13))
            path.closeSubpath()
            return path
        case .rosette:
            // A scalloped edge, twelve lobes.
            var path = Path()
            let lobes = 12
            let center = CGPoint(x: box.midX, y: box.midY)
            let outer = side / 2, inner = side / 2 * 0.86
            for i in 0...(lobes * 2) {
                let angle = Double(i) / Double(lobes * 2) * 2 * .pi - .pi / 2
                let r = i % 2 == 0 ? outer : inner
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                if i == 0 {
                    path.move(to: point)
                } else {
                    let mid = Double(i * 2 - 1) / Double(lobes * 4) * 2 * .pi - .pi / 2
                    let reach = (i % 2 == 0 ? outer : inner) * 1.0 + (outer - inner) * 0.6
                    path.addQuadCurve(to: point, control: CGPoint(x: center.x + CGFloat(cos(mid)) * reach,
                                                                  y: center.y + CGFloat(sin(mid)) * reach))
                }
            }
            path.closeSubpath()
            return path
        }
    }

    /// A regular polygon with rounded corners.
    static func polygon(in box: CGRect, sides: Int, rotation: Double, corner: CGFloat) -> Path {
        let center = CGPoint(x: box.midX, y: box.midY)
        let radius = box.width / 2
        let points = (0..<sides).map { i -> CGPoint in
            let angle = rotation + Double(i) / Double(sides) * 2 * .pi
            return CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
        }
        var path = Path()
        for i in 0..<sides {
            let a = points[(i + sides - 1) % sides], b = points[i], c = points[(i + 1) % sides]
            let start = CGPoint(x: b.x + (a.x - b.x) * 0.18, y: b.y + (a.y - b.y) * 0.18)
            let end = CGPoint(x: b.x + (c.x - b.x) * 0.18, y: b.y + (c.y - b.y) * 0.18)
            if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addQuadCurve(to: end, control: b)
        }
        path.closeSubpath()
        _ = corner
        return path
    }
}

/// Rays behind a gold badge.
struct Rays: Shape {
    let count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi
            let spread = .pi / Double(count) * 0.45
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle - spread)) * radius, y: center.y + CGFloat(sin(angle - spread)) * radius))
            path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle + spread)) * radius, y: center.y + CGFloat(sin(angle + spread)) * radius))
            path.closeSubpath()
        }
        return path
    }
}

/// A badge arriving on the notch: it flips in and lands with a bounce,
/// rays turn behind it, confetti bursts out and sparkles stay on, and a
/// shine crosses it once it has landed. Several take turns, each flipping
/// in with its own burst. Still, with Reduce Motion: the badge and its glow.
struct BadgeBurst: View {
    let badges: [Achievements.Badge]
    var size: CGFloat = 50
    /// A fixed moment into the burst, for renders.
    var frozenAt: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.badgeBurstFrozenAt) private var frozenByRender
    private var frozen: Double? { frozenAt ?? frozenByRender }
    @State private var landed = false
    @State private var flip: Double = -180
    @State private var shown = 0
    @State private var burstStart = Date()

    private var badge: Achievements.Badge { badges[shown % max(1, badges.count)] }

    var body: some View {
        let metal = BadgeMetal(tier: badge.tier, earned: true)
        let style = BadgeStyle.of(badge.family)
        let still = reduceMotion || frozen != nil
        ZStack {
            if still {
                glow(metal: metal, style: style, elapsed: frozen ?? 2.4)
            } else {
                TimelineView(.animation) { context in
                    glow(metal: metal, style: style, elapsed: context.date.timeIntervalSince(burstStart))
                }
            }
            Medal(badge: badge, earned: true, size: size, shine: landed)
                .scaleEffect(landed || still ? 1 : 0.3)
                .rotation3DEffect(.degrees(still ? 0 : flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .shadow(color: metal.light.opacity(0.6), radius: landed || still ? 8 : 0)
            if badges.count > 1 {
                Text("\(shown % badges.count + 1)/\(badges.count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .offset(x: size * 0.48, y: -size * 0.48)
            }
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .onAppear {
            guard !still else { landed = true; flip = 0; return }
            arrive()
        }
        .task {
            guard !still, badges.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.18)) { flip = 90; landed = false }
                try? await Task.sleep(nanoseconds: 180_000_000)
                shown += 1
                flip = -90
                arrive()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(badges.map { "\(Achievements.name($0)), \($0.tier.name)" }.joined(separator: "; "))
    }

    private func arrive() {
        burstStart = Date()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) { landed = true }
        withAnimation(.easeOut(duration: 0.7)) { flip = 0 }
    }

    /// Rays, confetti and sparkles, `elapsed` seconds into the burst.
    private func glow(metal: BadgeMetal, style: BadgeStyle, elapsed: Double) -> some View {
        ZStack {
            Rays(count: 14)
                .fill(RadialGradient(colors: [metal.light.opacity(0.85), metal.light.opacity(0)],
                                     center: .center, startRadius: size * 0.15, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
                .rotationEffect(.degrees(elapsed * 22))
                .opacity(min(1, elapsed * 3))
            Canvas { context, canvas in
                BurstPainter(elapsed: elapsed, colors: [metal.light, metal.mid, style.light, .white, Color(red: 1, green: 0.45, blue: 0.6)])
                    .paint(&context, size: canvas)
            }
            .frame(width: size * 2.2, height: size * 2.2)
        }
        .allowsHitTesting(false)
    }
}

/// Confetti thrown out from the middle and falling away, then sparkles
/// that come and go around the badge.
struct BurstPainter {
    let elapsed: Double
    let colors: [Color]

    private static func noise(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed)) &* 0x9E3779B97F4A7C15 &+ 0x6D2B79F5
        x ^= x >> 33; x = x &* 0xFF51AFD7ED558CCD; x ^= x >> 33
        return Double(x % 10_000) / 10_000
    }

    func paint(_ context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = Double(min(size.width, size.height)) / 2
        // Confetti: the first second and a half.
        let life = 1.5
        if elapsed < life {
            let t = elapsed
            for i in 0..<34 {
                let angle = Double(i) / 34 * 2 * .pi + Self.noise(i) * 0.4
                let speed = reach * (0.9 + Self.noise(i + 40) * 0.9)
                let x = center.x + CGFloat(cos(angle) * speed * t)
                let y = center.y + CGFloat(sin(angle) * speed * t + 0.5 * reach * 1.6 * t * t)
                let alpha = max(0, 1 - t / life)
                let side = 2.5 + CGFloat(Self.noise(i + 80)) * 2
                var piece = context
                piece.translateBy(x: x, y: y)
                piece.rotate(by: .radians(t * (4 + Self.noise(i + 7) * 8)))
                piece.fill(Path(CGRect(x: -side / 2, y: -side * 0.35, width: side, height: side * 0.7)),
                           with: .color(colors[i % colors.count].opacity(alpha)))
            }
        }
        // Sparkles: four-pointed stars that twinkle on around it.
        for i in 0..<7 {
            let angle = Self.noise(i + 300) * 2 * .pi
            let distance = reach * (0.55 + Self.noise(i + 310) * 0.35)
            let point = CGPoint(x: center.x + CGFloat(cos(angle) * distance), y: center.y + CGFloat(sin(angle) * distance))
            let beat = sin(elapsed * (2.2 + Self.noise(i + 320) * 2) + Double(i) * 1.3)
            let fade = min(1, max(0, elapsed - 0.3) * 2)
            guard beat > 0 else { continue }
            let r = CGFloat(2 + 3 * beat)
            var star = Path()
            star.move(to: CGPoint(x: point.x, y: point.y - r))
            star.addQuadCurve(to: CGPoint(x: point.x + r, y: point.y), control: point)
            star.addQuadCurve(to: CGPoint(x: point.x, y: point.y + r), control: point)
            star.addQuadCurve(to: CGPoint(x: point.x - r, y: point.y), control: point)
            star.addQuadCurve(to: CGPoint(x: point.x, y: point.y - r), control: point)
            context.fill(star, with: .color(.white.opacity(0.9 * beat * fade)))
        }
    }
}

private struct BadgeBurstFrozenKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Holds every badge burst at a moment, for renders.
    var badgeBurstFrozenAt: Double? {
        get { self[BadgeBurstFrozenKey.self] }
        set { self[BadgeBurstFrozenKey.self] = newValue }
    }
}
