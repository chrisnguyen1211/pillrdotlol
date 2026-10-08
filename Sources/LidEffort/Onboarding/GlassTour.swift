import AppKit
import LidEffortCore
import SwiftUI

/// What the tour draws over the screen: the film, then the glass steps.
struct TourOverlay: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        switch tour.phase {
        case .intro: GlassIntro(tour: tour)
        case .steps: GlassTourOverlay(tour: tour)
        }
    }
}

// MARK: - Pieces

enum GlassTour {
    static let accent = Color(red: 0.38, green: 0.62, blue: 1)
    static let glow = Color(red: 0.55, green: 0.78, blue: 1)

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        MeditationRise.smooth(a, b, x)
    }

    /// Overshoots a touch and settles — the way glass lands.
    static func back(_ x: Double) -> Double {
        let c = 1.5, y = x - 1
        return 1 + (c + 1) * y * y * y + c * y * y
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

/// Real Liquid Glass where the system has it, the nearest material where not;
/// over a blur of the desktop, so the glass has something to bend.
struct GlassSurface<S: Shape>: View {
    let shape: S
    var tint: Color? = nil
    var clear = false

    var body: some View {
        ZStack {
            GlassBackdrop(shape: shape, frost: 1)
            if #available(macOS 26.0, *), NotchSurfaceStyle.glassAvailable {
                if let tint {
                    Color.clear.glassEffect(clear ? .clear.tint(tint) : .regular.tint(tint), in: shape)
                } else {
                    Color.clear.glassEffect(clear ? .clear : .regular, in: shape)
                }
            } else {
                shape.fill(.ultraThinMaterial)
                if let tint { shape.fill(tint) }
            }
        }
    }
}

/// The desktop behind the window, blurred.
struct BehindBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - The intro

/// The film before the first card, every frame worked out from the time
/// since it began, so it keeps its place with the sound whatever the frame
/// rate does.
struct GlassIntro: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation) { context in
                IntroFrame(t: context.date.timeIntervalSince(tour.introStart),
                           size: geometry.size,
                           target: tour.pillRect.map { local($0) },
                           agents: tour.introAgents)
            }
        }
        .ignoresSafeArea()
        // A click anywhere skips the film to the first card.
        .contentShape(Rectangle())
        .onTapGesture { tour.skipIntro() }
        .overlay(alignment: .bottom) {
            Text(L10n.t("Click anywhere to skip"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.bottom, 36)
                .allowsHitTesting(false)
        }
    }

    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - tour.screenFrame.minX, y: tour.screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }
}

struct IntroFrame: View {
    let t: Double
    let size: CGSize
    let target: CGRect?
    /// The reader's own agents, for the scroll to come to rest on.
    var agents: [ProviderGlyph] = [.claude, .openai, .grok]
    /// The softened desktop and the landing page's sky behind it all. Off
    /// for the tests that measure the pill, which either would drown — an
    /// image renderer draws the desktop's blur as a bright placeholder.
    var showsBackdrop = true

    private typealias G = GlassTour
    private typealias T = IntroTimeline
    static let pillSize = CGSize(width: 132, height: 392)

    var body: some View {
        let dim = G.smooth(0, 1.2, t) * (1 - G.smooth(T.flyTo - 0.2, T.length - 0.3, t))
        let swell = G.smooth(0.3, T.strike, t)
        let glass = G.smooth(T.glassFrom, T.glassTo, t)
        let word = G.smooth(T.strike - 0.2, T.strike + 1.3, t) * (1 - G.smooth(T.flyFrom - 0.6, T.flyFrom, t))
        let line = G.smooth(T.strike + 0.8, T.strike + 1.9, t) * (1 - G.smooth(T.flyFrom - 0.6, T.flyFrom, t))
        // Eased both ways, so it leaves gently and settles into the notch.
        let fly = G.smooth(T.flyFrom, T.flyTo, t)
        let gone = G.smooth(T.reveal, T.reveal + 0.45, t)

        let centre = CGPoint(x: size.width / 2 + 170, y: size.height / 2)
        let goal = target ?? CGRect(x: size.width - 14, y: size.height / 2 - 60, width: 14, height: 120)
        let w = G.lerp(Self.pillSize.width, goal.width, fly)
        let h = G.lerp(Self.pillSize.height, goal.height, fly)
        let x = G.lerp(centre.x, goal.midX, fly)
        let y = G.lerp(centre.y, goal.midY, fly)

        // The sky comes in out of a blur as the desktop softens, and goes
        // back into one — while the pill flies home, so the two leave
        // together and the pill lands on the desktop as the sky clears.
        let skyIn = G.smooth(0.15, 1.7, t)
        let skyOut = G.smooth(T.flyFrom - 0.35, T.flyTo + 0.05, t)
        let sky = skyIn * (1 - skyOut)

        ZStack {
            // The desktop, softened: under the sky's soft edges on the way
            // in and out, never seen sharp behind it.
            if showsBackdrop { BehindBlur().opacity(dim) }
            if showsBackdrop, sky > 0.001 {
                PixelSkyView(t: t, size: size, blur: 5 + 24 * CGFloat(1 - skyIn) + 24 * CGFloat(skyOut))
                    .scaleEffect(1.06 - 0.06 * skyIn + 0.04 * skyOut)
                    .opacity(sky)
            }
            Color.black.opacity(0.12 * dim)
            RadialGradient(colors: [G.glow.opacity(0.3 * swell), .clear], center: .center, startRadius: 0, endRadius: 440)
                .frame(width: 960, height: 960)
                .position(centre)
                .opacity(dim * (0.85 + 0.15 * sin(t * 2.2)) * (1 - fly))
                .blendMode(.plusLighter)

            // Liquid first: drops running together into the pill.
            if glass < 1 {
                DropsBlob(t: t, centre: centre, pill: Self.pillSize)
                    .opacity(1 - glass)
            }

            // Then glass, with every agent it reads running through it. The
            // scroll is laid over the glass, not beside it: as a sibling its
            // fixed height held the glass at full size, and only the icons
            // shrank as it flew home.
            GlassSurface(shape: Capsule(), clear: true)
                .overlay(
                    AngularGradient(colors: [G.accent, .purple, .cyan, .mint, G.accent], center: .center, angle: .degrees(t * 50))
                        .blur(radius: 26)
                        .opacity(0.35 * (1 - fly))
                        .blendMode(.plusLighter)
                )
                .overlay {
                    AgentScroll(t: t, agents: agents, viewport: CGSize(width: Self.pillSize.width, height: Self.pillSize.height - 40))
                        .frame(width: Self.pillSize.width, height: Self.pillSize.height - 40)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                                     .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        // One scale for both axes, so the rings stay round.
                        .scaleEffect(min(w / Self.pillSize.width, h / Self.pillSize.height))
                        // Gone before the pill is small: the folded pill it
                        // lands in carries no rings.
                        .opacity(1 - G.smooth(T.flyFrom + 0.1, T.flyFrom + 0.7, t))
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.1), .white.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.3))
                .frame(width: max(1, w), height: max(1, h))
                .shadow(color: G.glow.opacity(0.45 * (1 - fly)), radius: 44)
                .position(x: x, y: y)
                .opacity(glass * (1 - gone))

            VStack(alignment: .trailing, spacing: 12) {
                Text("pillr")
                    .font(.system(size: 108, weight: .bold, design: .rounded))
                    .tracking(G.lerp(26, -2, word))
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                    .blur(radius: CGFloat(1 - word) * 16)
                    .opacity(word)
                    .scaleEffect(0.94 + 0.06 * word)
                Text(L10n.t("Every coding agent. One pill."))
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .opacity(line)
                    .offset(y: CGFloat(1 - line) * 8)
            }
            .shadow(color: G.glow.opacity(0.5 * word), radius: 24)
            // As on the page: a soft shadow keeps the words legible over a cloud.
            .shadow(color: Color(red: 0.04, green: 0.12, blue: 0.35).opacity(0.45 * word), radius: 14, y: 2)
            .position(x: size.width / 2 - 170, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Drops of liquid coming in from all round and running together into the
/// pill — circles blurred into one another and cut back to a hard edge, the
/// way water beads merge.
struct DropsBlob: View {
    let t: Double
    let centre: CGPoint
    let pill: CGSize

    var body: some View {
        let shape = Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: .white))
            context.addFilter(.blur(radius: 14))
            context.drawLayer { layer in
                // The pill itself, gathering as the drops arrive.
                let extent = IntroTimeline.pillExtent(t, pill: pill)
                let pw = extent.width, ph = extent.height
                layer.fill(Path(roundedRect: CGRect(x: centre.x - pw / 2, y: centre.y - ph / 2, width: pw, height: ph),
                                 cornerRadius: pw / 2),
                           with: .color(.black))
                for path in IntroTimeline.dropPaths {
                    guard let drop = IntroTimeline.drop(path, at: t, centre: centre, pill: pill) else { continue }
                    layer.fill(Path(ellipseIn: CGRect(x: drop.point.x - drop.radius, y: drop.point.y - drop.radius,
                                                      width: 2 * drop.radius, height: 2 * drop.radius)),
                               with: .color(.black))
                }
            }
        }
        return LinearGradient(colors: [.white.opacity(0.95), GlassTour.glow.opacity(0.85), .purple.opacity(0.7)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .mask(shape)
            .overlay(
                RadialGradient(colors: [.white.opacity(0.7), .clear], center: UnitPoint(x: 0.42, y: 0.4), startRadius: 0, endRadius: 260)
                    .mask(shape)
                    .blendMode(.plusLighter)
            )
            .shadow(color: GlassTour.glow.opacity(0.6), radius: 30)
    }
}

/// Every agent pillr reads, as the pill draws them — its own ring and badge —
/// running up through the pill, faster and faster, then easing to a stop on
/// the reader's own agents.
struct AgentScroll: View {
    let t: Double
    let agents: [ProviderGlyph]
    let viewport: CGSize

    var body: some View {
        let T = IntroTimeline.self
        let glyphs = Array(repeating: T.scrollGlyphs, count: T.laps).flatMap { $0 } + agents
        let settle = (viewport.height - CGFloat(agents.count) * T.pitch) / 2
        let offset = T.scrolled(t, total: T.scrollDistance) - settle
        let blur = CGFloat(T.speed(t)) * 1.5
        let appear = GlassTour.smooth(T.glassFrom, T.scrollFrom + 0.2, t)
        VStack(spacing: 0) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { index, glyph in
                // Only what can be in view: the list is sixty long.
                let y = CGFloat(index) * T.pitch - offset
                if y > -T.pitch * 2 && y < viewport.height + T.pitch {
                    ProviderRing(usedFraction: 0.2 + Double((index * 37) % 70) / 100, glyph: glyph)
                        .scaleEffect(1.25)
                        .frame(height: T.pitch)
                } else {
                    Color.clear.frame(height: T.pitch)
                }
            }
        }
        .offset(y: -offset)
        .frame(width: viewport.width, height: viewport.height, alignment: .top)
        .blur(radius: blur)
        .opacity(appear)
        .clipped()
    }
}

// MARK: - Over the screen, during the steps

/// The glass tour's pointer: the screen dimmed a little, a pool of light
/// round what the card is about, a glowing line from the card to it with a
/// bead of light running along, and — for "anywhere" — lines out to every
/// edge not yet visited.
struct GlassTourOverlay: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let drawn = MarkerStroke.progress(at: context.date, since: tour.drawingSince, delay: 0.15)
            ZStack {
                spotlight
                if let anchor = tour.anchor.map(local) {
                    let card = local(tour.cardFrame)
                    beam(from: nearest(on: card.insetBy(dx: -8, dy: -8), toward: anchor),
                         to: nearest(on: anchor.insetBy(dx: -14, dy: -14), toward: card),
                         drawn: drawn, t: t)
                    halo(around: anchor, t: t)
                    if tour.celebration != nil { sparkles(at: anchor) }
                }
                if tour.step == .anywhere && !tour.hasVisitedEveryEdge {
                    edgeBeams(drawn: drawn, t: t)
                }
                if let result = tour.result, let rect = result.rect {
                    TourResultCard(result: result, edge: tour.edge)
                        .frame(width: body(of: local(rect)).width, height: body(of: local(rect)).height)
                        .position(x: body(of: local(rect)).midX, y: body(of: local(rect)).midY)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
    }

    private var spotlight: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.2)))
            guard let anchor = tour.anchor.map(local) else { return }
            context.blendMode = .destinationOut
            context.addFilter(.blur(radius: 30))
            context.fill(Path(roundedRect: anchor.insetBy(dx: -40, dy: -40), cornerRadius: 60), with: .color(.black))
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }

    private func halo(around rect: CGRect, t: Double) -> some View {
        let pulse = 0.5 + 0.5 * sin(t * 2.6)
        let r = rect.insetBy(dx: -12, dy: -12)
        // A capsule round the pill, a card's own rounding round a card —
        // rounded by half its short side, a card came out a circle.
        return RoundedRectangle(cornerRadius: min(min(r.width, r.height) / 2, 30), style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.95), GlassTour.glow], startPoint: .top, endPoint: .bottom),
                          lineWidth: 2.2)
            .shadow(color: GlassTour.glow.opacity(0.9), radius: 10 + 8 * pulse)
            .frame(width: r.width, height: r.height)
            .scaleEffect(1 + 0.035 * pulse)
            .position(x: r.midX, y: r.midY)
    }

    private func beam(from a: CGPoint, to b: CGPoint, drawn: CGFloat, t: Double, dashed: Bool = false) -> some View {
        let points = Doodle.curve(from: a, to: b, bend: 0.16, samples: 30)
        let path = Doodle.smooth(points)
        let bead = points[min(points.count - 1, Int(Double(points.count - 1) * (t * 0.55).truncatingRemainder(dividingBy: 1)))]
        return ZStack {
            path.trim(from: 0, to: drawn)
                .stroke(GlassTour.glow.opacity(0.5), style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: dashed ? [2, 12] : []))
                .blur(radius: 6)
            path.trim(from: 0, to: drawn)
                .stroke(LinearGradient(colors: [.white.opacity(0.35), .white], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [2, 12] : []))
            if drawn >= 1 {
                Circle().fill(.white).frame(width: 7, height: 7)
                    .shadow(color: GlassTour.glow, radius: 8)
                    .position(bead)
            }
        }
    }

    @ViewBuilder private func edgeBeams(drawn: CGFloat, t: Double) -> some View {
        let size = tour.screenFrame.size
        let card = local(tour.cardFrame)
        let targets: [(NotchEdge, CGPoint)] = [
            (.top, CGPoint(x: size.width / 2, y: 36)), (.bottom, CGPoint(x: size.width / 2, y: size.height - 36)),
            (.left, CGPoint(x: 36, y: size.height / 2)), (.right, CGPoint(x: size.width - 36, y: size.height / 2)),
        ]
        ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
            if !tour.visitedEdges.contains(target.0) {
                beam(from: nearest(on: card.insetBy(dx: -12, dy: -12), toward: CGRect(origin: target.1, size: .zero)),
                     to: target.1, drawn: drawn, t: t, dashed: true)
                Circle().fill(.white.opacity(0.9)).frame(width: 10, height: 10)
                    .shadow(color: GlassTour.glow, radius: 10)
                    .position(target.1)
            }
        }
    }

    private func sparkles(at rect: CGRect) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: GlassTour.glow, radius: 10)
            .position(x: rect.minX - 18, y: rect.minY - 12)
            .transition(.scale.combined(with: .opacity))
    }

    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - tour.screenFrame.minX, y: tour.screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func body(of rect: CGRect) -> CGRect {
        let inset = tour.resultTailInset
        switch tour.edge {
        case .right:  return CGRect(x: rect.minX, y: rect.minY, width: rect.width - inset, height: rect.height)
        case .left:   return CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset, height: rect.height)
        case .top:    return CGRect(x: rect.minX, y: rect.minY + inset, width: rect.width, height: rect.height - inset)
        case .bottom: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - inset)
        }
    }

    private func nearest(on rect: CGRect, toward other: CGRect) -> CGPoint {
        let target = CGPoint(x: other.midX, y: other.midY)
        let dx = target.x - rect.midX, dy = target.y - rect.midY
        guard dx != 0 || dy != 0 else { return CGPoint(x: rect.midX, y: rect.midY) }
        let s = min(dx == 0 ? .greatestFiniteMagnitude : (rect.width / 2) / abs(dx),
                    dy == 0 ? .greatestFiniteMagnitude : (rect.height / 2) / abs(dy))
        return CGPoint(x: rect.midX + dx * s, y: rect.midY + dy * s)
    }
}

// MARK: - The card

struct GlassTourCard: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(alignment: .leading, spacing: 11) {
            GlassIllustration(tour: tour)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
            Text(tour.stepTitle)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(tour.stepText)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let celebration = tour.celebration {
                Label(celebration, systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(GlassTour.accent)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 22)
        .frame(width: IntroTour.cardSize.width - 20, height: IntroTour.cardSize.height - 20)
        .background {
            // The shadow is cast by the card's own shape. Cast by the glass —
            // an AppKit view, square to the window — it came out as a grey
            // box round every card.
            shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            GlassSurface(shape: shape)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .frame(width: IntroTour.cardSize.width, height: IntroTour.cardSize.height)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: tour.step)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: tour.celebration)
    }

    /// The dots and the buttons on one line where they fit; where a step
    /// has a button of its own as well, the dots go above them rather than
    /// every button's title being cut short.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hint = tour.tryHint {
                TryHint(text: hint)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            footerRow
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tour.tryHint)
    }

    private var footerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                dots
                Spacer(minLength: 0)
                buttons
            }
            VStack(alignment: .leading, spacing: 12) {
                dots
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(tour.steps, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= tour.step.rawValue ? AnyShapeStyle(GlassTour.accent) : AnyShapeStyle(.quaternary))
                    .frame(width: step == tour.step ? 18 : 6, height: 6)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if tour.step == .finish, let before = tour.edgeBeforeTour {
                GlassButton(title: L10n.t("Back to \(before.title.lowercased())"), prominent: false) { tour.restoreEdge() }
            }
            if tour.step == .anywhere, !tour.hasVisitedEveryEdge || tour.isFlying {
                // The thing to try on this step, so it is the loud button
                // until it has been pressed.
                GlassButton(title: tour.isFlying ? L10n.t("Flying…") : L10n.t("Show me"), prominent: tour.invitesTry) { tour.flyRound() }
                    .disabled(tour.isFlying)
                    .tourPulse(tour.invitesTry)
            }
            if tour.step == .reply {
                GlassButton(title: L10n.t("Show me"), prominent: false) { tour.playReply() }
                    .disabled(tour.isReplying)
            }
            if tour.step != .finish {
                GlassButton(title: L10n.t("Skip tour"), prominent: false) { tour.end() }
            }
            GlassButton(title: tour.step == .finish ? (tour.leadsIntoSetup ? L10n.t("Continue to Setup") : L10n.t("Let's go")) : L10n.t("Next"),
                        prominent: !tour.invitesTry) { tour.next() }
        }
        .fixedSize()
    }
}

/// "Try it": what the step wants you to do yourself, in the accent colour,
/// breathing gently so the eye finds it — the demo is the point of the step.
struct TryHint: View {
    let text: String
    @State private var lit = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(GlassTour.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(GlassTour.accent.opacity(lit ? 0.22 : 0.12)))
        .overlay(Capsule().strokeBorder(GlassTour.accent.opacity(lit ? 0.7 : 0.35), lineWidth: 1))
        .fixedSize()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A soft glow that comes and goes round the button to press.
    func tourPulse(_ active: Bool) -> some View { modifier(TourPulse(active: active)) }
}

private struct TourPulse: ViewModifier {
    let active: Bool
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .shadow(color: GlassTour.accent.opacity(active ? (lit ? 0.75 : 0.25) : 0), radius: lit ? 12 : 5)
            .scaleEffect(active && lit ? 1.04 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}

struct GlassButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            if prominent {
                Button(action: action) { Text(title).fontWeight(.semibold).padding(.horizontal, 6) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(GlassTour.accent)
            } else {
                Button(action: action) { Text(title).padding(.horizontal, 4) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        } else {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - The drawings

/// Each step, drawn clean: the pill as the product draws it, the note it
/// slides out, the lid swinging.
struct GlassIllustration: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                switch tour.step {
                case .hello: helloScene(t)
                case .apiKeys: apiKeysScene(t)
                case .sessions: sessionsScene(t)
                case .done: doneScene(t)
                case .reply: replyScene(t)
                case .approval: approvalScene(t)
                case .question: questionScene(t)
                case .anywhere: anywhereScene(t)
                case .lid: lidScene(t)
                case .finish: finishScene(t)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The real pill, as it stands on a right edge: the reader's own
    /// agents, drawn by the ring the notch draws them with — and, for the
    /// keys, their one cell after them.
    private func pill(scale: CGFloat = 0.52, keys: Bool = false) -> some View {
        let cells = tour.pillAgents + (keys ? [TourDemo.keyGroup()] : [])
        return RealPill(agents: cells).scaleEffect(scale).frame(width: RealPill.width * scale,
                                                                height: RealPill.height(cells.count) * scale)
    }

    /// A real card of the notch's, drawn at its own size and scaled down.
    private func real<Content: View>(_ size: CGSize, scale: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .allowsHitTesting(false)
            .environment(\.colorScheme, .dark)
            // The notch's solid look: glass set inside the card's own glass
            // refracted into a smear of colour.
            .environment(\.notchSurfaceStyle, .solid)
    }

    private var cardSize: CGSize { CGSize(width: NotchLayout.cardWidth + NotchLayout.tailLength, height: 0) }

    private func helloScene(_ t: Double) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "eye.fill")
                .font(.system(size: 26))
                .foregroundStyle(GlassTour.accent)
                .symbolEffect(.pulse)
                .offset(x: CGFloat(sin(t * 1.4)) * 4)
            pill(scale: 0.6)
        }
    }

    /// The API keys cell's own card — every key, every figure it reads —
    /// beside the pill with the cell among the agents.
    private func apiKeysScene(_ t: Double) -> some View {
        let group = TourDemo.keyGroup()
        let height = NotchLayout.cardHeight(windowCount: 1,
                                            keyGroupBody: NotchLayout.keyGroupPlan(group.keyGroup ?? []).body)
        return HStack(spacing: 4) {
            real(CGSize(width: cardSize.width, height: height), scale: min(0.5, 146 / height)) {
                TooltipCard(snapshot: group, now: Date(), direction: NotchEdge.right.tooltipDirection)
            }
            pill(scale: 0.46, keys: true)
        }
    }

    /// The notch's own session rows, as a tooltip lists them.
    private func sessionsScene(_ t: Double) -> some View {
        let lists = TourDemo.sessions()
        let rows = [lists["claude"]?[0], lists["claude"]?[1], lists["codex"]?[1]].compactMap { $0 }
        return HStack(spacing: 6) {
            sessionCard(rows)
            pill()
        }
    }

    /// A session under the pointer, its Reply showing, above one at work.
    private func replyScene(_ t: Double) -> some View {
        let lists = TourDemo.sessions()
        let rows = [lists["claude"]?[0], TourDemo.replySession()].compactMap { $0 }
        return HStack(spacing: 6) {
            sessionCard(rows, replyingTo: TourDemo.replySession()?.id)
            pill()
        }
    }

    /// Rows as the tooltip lists them, on the notch's card.
    private func sessionCard(_ rows: [AgentSession], replyingTo: AgentSession.ID? = nil) -> some View {
        real(CGSize(width: NotchLayout.cardWidth,
                    height: 2 * NotchLayout.cardPadding
                        + CGFloat(rows.count) * (2 * NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap)
                        + CGFloat(rows.count - 1) * NotchLayout.blockSpacing),
             scale: 0.66) {
            VStack(alignment: .leading, spacing: NotchLayout.blockSpacing) {
                ForEach(rows) { row in
                    SessionRow(session: row, now: Date(), onAction: row.id == replyingTo ? { _ in } : nil,
                               showsReply: row.id == replyingTo)
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .continuous).fill(Palette.notch))
        }
    }

    private func doneScene(_ t: Double) -> some View {
        HStack(spacing: 4) {
            real(CGSize(width: cardSize.width, height: DoneToastView.cardHeight), scale: 0.62) {
                DoneToastView(toast: DoneToast(event: IntroTour.demoFinished(), glyph: .claude),
                              direction: NotchEdge.right.tooltipDirection)
            }
            .offset(x: -CGFloat((sin(t * 1.3) + 1) / 2) * 6)
            pill()
        }
    }

    private func promptScene(_ prompt: PendingPrompt?) -> some View {
        HStack(spacing: 4) {
            if let prompt {
                real(CGSize(width: cardSize.width, height: PromptCard.cardHeight(for: prompt)), scale: 0.5) {
                    PromptCard(prompt: prompt, draft: .constant(PromptDraft(questions: prompt.questions)),
                               direction: NotchEdge.right.tooltipDirection, onAnswer: { _ in })
                }
            }
            pill()
        }
    }

    private func approvalScene(_ t: Double) -> some View { promptScene(tour.sampleApproval) }
    private func questionScene(_ t: Double) -> some View { promptScene(tour.sampleQuestion) }

    private func anywhereScene(_ t: Double) -> some View {
        Canvas { canvas, size in
            let screen = CGRect(x: size.width / 2 - 110, y: 6, width: 220, height: size.height - 12)
            canvas.stroke(Path(roundedRect: screen, cornerRadius: 16), with: .color(.primary.opacity(0.25)), lineWidth: 1.2)
            let sides: [(NotchEdge, CGPoint, CGPoint)] = [
                (.top, CGPoint(x: screen.minX + 24, y: screen.minY - 5), CGPoint(x: screen.maxX - 24, y: screen.minY - 5)),
                (.right, CGPoint(x: screen.maxX + 5, y: screen.minY + 18), CGPoint(x: screen.maxX + 5, y: screen.maxY - 18)),
                (.bottom, CGPoint(x: screen.maxX - 24, y: screen.maxY + 5), CGPoint(x: screen.minX + 24, y: screen.maxY + 5)),
                (.left, CGPoint(x: screen.minX - 5, y: screen.maxY - 18), CGPoint(x: screen.minX - 5, y: screen.minY + 18)),
            ]
            for (side, a, b) in sides where tour.visitedEdges.contains(side) {
                canvas.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(GlassTour.accent),
                              style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
            let inner = screen.insetBy(dx: 9, dy: 9)
            let lap = (t / 4).truncatingRemainder(dividingBy: 1)
            let total = 2 * (inner.width + inner.height)
            var d = CGFloat(lap) * total
            let point: CGPoint
            var vertical = false
            if d < inner.width { point = CGPoint(x: inner.minX + d, y: inner.minY) } else {
                d -= inner.width
                if d < inner.height { point = CGPoint(x: inner.maxX, y: inner.minY + d); vertical = true } else {
                    d -= inner.height
                    if d < inner.width { point = CGPoint(x: inner.maxX - d, y: inner.maxY) } else {
                        d -= inner.width
                        point = CGPoint(x: inner.minX, y: inner.maxY - d); vertical = true
                    }
                }
            }
            let pillSize = vertical ? CGSize(width: 11, height: 38) : CGSize(width: 38, height: 11)
            canvas.fill(Path(roundedRect: CGRect(x: point.x - pillSize.width / 2, y: point.y - pillSize.height / 2,
                                                 width: pillSize.width, height: pillSize.height), cornerRadius: 5.5),
                        with: .color(.black.opacity(0.85)))
            canvas.draw(Text("\(tour.visitedEdges.count)/4").font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(GlassTour.accent),
                        at: CGPoint(x: screen.midX, y: screen.midY))
        }
    }

    private func lidScene(_ t: Double) -> some View {
        HStack(spacing: 6) {
            laptop(t).frame(width: 170)
            let event = EffortChangeEvent(level: tour.effortState.level, values: tour.effortValues, at: Date())
            real(CGSize(width: NotchLayout.cardWidth + NotchLayout.tailLength,
                        height: EffortChangeCard.cardHeight(for: event)), scale: 0.5) {
                EffortChangeCard(event: event, direction: NotchEdge.right.tooltipDirection)
            }
        }
    }

    private func laptop(_ t: Double) -> some View {
        Canvas { canvas, size in
            let hinge = CGPoint(x: size.width * 0.5, y: size.height - 26)
            let slab: CGFloat = 8
            canvas.fill(Path(roundedRect: CGRect(x: hinge.x - 4, y: hinge.y, width: 84, height: slab), cornerRadius: 4),
                        with: .color(.primary.opacity(0.75)))
            let swing = (sin(t * 2.3) + 1) / 2
            let degrees = 58 + swing * 54
            let length: CGFloat = 80
            let lid = Path(roundedRect: CGRect(x: 0, y: -slab, width: length, height: slab), cornerRadius: 4)
                .applying(CGAffineTransform(rotationAngle: -CGFloat(degrees) * .pi / 180)
                    .concatenating(CGAffineTransform(translationX: hinge.x, y: hinge.y)))
            canvas.fill(lid, with: .color(.primary.opacity(0.75)))
            let angle = CGFloat(degrees) * .pi / 180
            let glowStart = CGPoint(x: hinge.x + cos(angle) * 12 + sin(angle) * 3, y: hinge.y - sin(angle) * 12 + cos(angle) * 3)
            let glowEnd = CGPoint(x: hinge.x + cos(angle) * (length - 10) + sin(angle) * 3, y: hinge.y - sin(angle) * (length - 10) + cos(angle) * 3)
            var glow = canvas
            glow.addFilter(.shadow(color: GlassTour.glow, radius: 8))
            glow.stroke(Path { $0.move(to: glowStart); $0.addLine(to: glowEnd) },
                        with: .color(GlassTour.glow.opacity(0.35 + 0.6 * swing)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            // ⌘, lit while held, blinking otherwise.
            let key = CGRect(x: 4, y: 8, width: 40, height: 40)
            let held = tour.effortState.armed
            let blink = held ? 1 : 0.45 + 0.55 * (sin(t * 4.6) + 1) / 2
            canvas.fill(Path(roundedRect: key, cornerRadius: 11), with: .color(GlassTour.accent.opacity(0.15 + 0.3 * blink)))
            canvas.stroke(Path(roundedRect: key, cornerRadius: 11), with: .color(.primary.opacity(0.3 + 0.5 * blink)), lineWidth: 1.2)
            canvas.draw(Text("⌘").font(.system(size: 21, weight: .semibold)).foregroundColor(.primary.opacity(0.5 + 0.5 * blink)),
                        at: CGPoint(x: key.midX, y: key.midY))
        }
    }

    private func finishScene(_ t: Double) -> some View {
        HStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 50))
                .foregroundStyle(GlassTour.accent, .white)
                .symbolEffect(.bounce, options: .repeating.speed(0.4))
            ZStack {
                Capsule().fill(GlassTour.glow.opacity(0.35)).frame(width: 60, height: 150).blur(radius: 18)
                    .scaleEffect(1 + 0.06 * sin(t * 2))
                pill(scale: 0.6)
            }
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(GlassTour.accent)
                .opacity(0.5 + 0.5 * sin(t * 3))
        }
    }
}

/// The pill as the notch draws it on a right edge — black capsule, one real
/// ring per agent — for the tour's pictures.
struct RealPill: View {
    let agents: [ProviderSnapshot]
    static let width = NotchLayout.sideBodyDepth
    static func height(_ count: Int) -> CGFloat {
        NotchLayout.bodyLength(cellCount: max(1, count), edge: .right)
    }

    var body: some View {
        ZStack {
            Capsule().fill(Palette.notch)
            Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1)
            VStack(spacing: NotchLayout.cellSpacing) {
                ForEach(agents) { agent in
                    ProviderCell(snapshot: agent)
                }
            }
            .padding(.top, NotchLayout.padTop - NotchLayout.cellSpacing / 2)
        }
        .frame(width: Self.width, height: Self.height(agents.count))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - The tour's own tooltip

/// Where a demo prompt was, once it is answered: the notch's own card, dark
/// and quiet, saying what was done and what it would have meant — with a
/// note that this was the tour, so nothing went anywhere.
struct TourResultCard: View {
    let result: TourResult
    let edge: NotchEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: result.isPositive ? "checkmark.circle.fill" : "arrow.uturn.left.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(result.isPositive ? Color.green : Color.orange)
                Text(result.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if let detail = result.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            Text(result.meaning)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Label(L10n.t("Just the tour, nothing was sent"), systemImage: "sparkles")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(GlassTour.glow)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // Glass under a dark wash: the type is white, and glass alone
            // over a light window left it unreadable.
            ZStack {
                // The glow from the card's shape, not the glass's square view.
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.001))
                    .shadow(color: GlassTour.glow.opacity(0.35), radius: 18)
                GlassSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.62))
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.2))
            }
        }
    }
}
