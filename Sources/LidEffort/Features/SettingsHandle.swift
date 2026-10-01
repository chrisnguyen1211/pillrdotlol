import SwiftUI

/// The settings control, below the notch.
///
/// At rest it is a single arc — a segment of a circle's edge, tucked into the
/// corner the notch's bottom flare makes. On hover that same circle fills in and
/// takes a gear. The two states are the same circle, which is what makes the
/// change read as one object waking up rather than as one thing being swapped
/// for another.
///
/// It is a bare arc at rest because the notch is meant to be glanceable: a
/// permanently visible gear is a second thing competing with the readings, and
/// the readings are the point. An arc says "there is something here" without
/// asserting anything.
struct SettingsOrb: View {
    let isHovered: Bool
    var edge: NotchEdge = .right
    /// Riding inside a bar hung from the bezel: a glyph, not an arc.
    var inline = false
    /// True when the arc traces the bar's own rounded corner from outside
    /// rather than a flare from inside — a flush bar has no flare to tuck into.
    var convex: Bool = false
    /// The circle the resting arc follows.
    var arcRadius: CGFloat = NotchLayout.orbArcRadius
    /// How far the arc sits from the button. Zero inside a flare's pocket,
    /// where the two are the same object; back onto the corner when the button
    /// has had to move clear of the bar.
    var arcOffset: CGSize = .zero
    /// How many times the gear has been asked to turn. See
    /// `NotchViewModel.settingsSpins`.
    var spins: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which quarter of the circle the resting arc occupies.
    ///
    /// The arc has to parallel the flare at the far end of the notch, so it
    /// faces two ways at once: **back along the stack**, toward the notch it
    /// hangs off, and **outward**, toward the bezel it is about to merge into.
    /// On the right edge that is twelve o'clock round to three, which is the
    /// arc this was drawn as before there was any choice of edge. Turn the
    /// notch and the same two directions pick a different quadrant.
    ///
    /// SwiftUI's `Circle` trim starts at three o'clock and runs clockwise, with
    /// y growing downward.
    /// Hugging a corner from outside is the same relationship as hugging a
    /// flare from inside, turned through half a circle.
    static func restingTrim(for edge: NotchEdge, convex: Bool) -> ClosedRange<CGFloat> {
        let concave = restingTrim(for: edge)
        guard convex else { return concave }
        let turned = (concave.lowerBound + 0.5).truncatingRemainder(dividingBy: 1)
        return turned...(turned + 0.25)
    }

    static func restingTrim(for edge: NotchEdge) -> ClosedRange<CGFloat> {
        switch edge {
        case .right:  return 0.75...1.0      // up, round to the right
        case .left:   return 0.5...0.75      // left, round to up
        case .top:    return 0.5...0.75      // left, round to up
        case .bottom: return 0.25...0.5      // down, round to the left
        }
    }

    /// Where the resting arc is centred, as a fraction of the circle (0 is
    /// three o'clock, clockwise). Set for the capsule, whose orbs sit on the
    /// stack's axis: the arc is a short cap centred straight past the end,
    /// not a quadrant tucked into a corner. Nil keeps the notch's quadrants.
    var restingCentre: CGFloat? = nil

    /// A sixth of the circle. Drawn centred at nine o'clock and turned to
    /// where it belongs, because a trim range cannot wrap past 1.
    private static var capSpan: CGFloat { NotchLayout.pillArcSpan }
    private var restingTrim: ClosedRange<CGFloat> {
        restingCentre != nil
            ? (0.5 - Self.capSpan / 2)...(0.5 + Self.capSpan / 2)
            : Self.restingTrim(for: edge, convex: convex)
    }
    private var restingRotation: Double { restingCentre.map { Double($0 - 0.5) * 360 } ?? 0 }

    /// How far the button dips under a click.
    ///
    /// Shallow on purpose. This is a 22pt control tucked against the bezel, and
    /// a deeper press reads as the whole notch flinching rather than as one
    /// button being pushed.
    private static let squeezeScale: CGFloat = 0.84

    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.notchReduceTransparency) private var reduceTransparency

    /// Reduce transparency means "no see-through chrome", which for the orb is
    /// the solid style — the same precedence the Settings window applies to its
    /// own translucent chrome.
    private var glassy: Bool { surfaceStyle.effective == .glass && !reduceTransparency }

    /// The resting arc, on a circle one gap inside the flare's own.
    ///
    /// On glass the arc is the material itself rather than a stroke of our
    /// paint, so it reads as the same substance as the flare it hugs instead of
    /// a line drawn beside it.
    @ViewBuilder
    private var restingArc: some View {
        if glassy {
            // `effective` is only ever `.glass` where `glassEffect` exists; the
            // availability check is what tells the compiler so.
            if #available(macOS 26.0, *) {
                // The glass is the band itself, so it has a rim: glass cut
                // out of a larger sheet had none, and read as a tint.
                // The band's own inset cancels the extra stroke width here,
                // so this is the same circle the stroked arc follows.
                let band = ArcBand(trim: restingTrim, lineWidth: NotchLayout.orbStroke)
                ChromeGlass(shape: band, glass: Runtime.isUnderTest ? .regular : .clear)
                .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
                       height: arcRadius * 2 + NotchLayout.orbStroke)
            }
        } else {
            Circle()
                .trim(from: restingTrim.lowerBound, to: restingTrim.upperBound)
                .stroke(
                    Palette.notch,
                    style: StrokeStyle(lineWidth: NotchLayout.orbStroke, lineCap: .round)
                )
                .frame(width: arcRadius * 2, height: arcRadius * 2)
        }
    }

    /// The filled disc the arc becomes on hover. It is the one thing here you
    /// press, so its glass is `interactive` and reacts to the pointer.
    @ViewBuilder
    private var hoverDisc: some View {
        if glassy {
            if #available(macOS 26.0, *) {
                ChromeGlass(shape: Circle(),
                            glass: Runtime.isUnderTest ? .regular.interactive() : .clear.interactive())
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
            }
        } else {
            Circle()
                .fill(Palette.notch)
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
        }
    }

    var body: some View {
        if inline {
            InlineHandle(glyph: "plus", isHovered: isHovered, spins: spins, turn: 360)
        } else {
            orb
        }
    }

    private var orb: some View {
        ZStack {
            restingArc
                .rotationEffect(.degrees(restingRotation))
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(isHovered ? 0.86 : 1)
                .offset(arcOffset)

            hoverDisc
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 1.1)

            Image(systemName: "plus")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                // Two rotations on one glyph: the wake-up from the hover
                // state, and a full turn per click. Summed rather than
                // applied separately so a click mid-hover does not fight the
                // -60 the gear is still arriving from.
                .rotationEffect(.degrees((isHovered ? 0 : -60) + Double(spins) * 360))
                .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.55,
                                                                      dampingFraction: 0.72),
                                                              reduceMotion),
                           value: spins)
        }
        // Sized to the larger of the two states, and never clipped: the arc
        // may sit well outside this frame when it has stayed back on the
        // corner the button hangs from.
        .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
               height: arcRadius * 2 + NotchLayout.orbStroke)
        .animation(
            NotchMotion.respectingReduceMotion(
                .spring(response: 0.36, dampingFraction: 0.7), reduceMotion
            ),
            value: isHovered
        )
        // The press, on the same counter as the turn. A click reaches this
        // view as one event — the panel's own hit test and the SwiftUI
        // gesture both bump `spins`, and neither reports mouse-down and
        // mouse-up separately — so the dip and the release are keyframed off
        // that single tick rather than tracked from a press state that does
        // not exist here.
        //
        // Down fast and back slower: a press is sharp, a release settles.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: spins) { orb, scale in
            orb.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(reduceMotion ? 1 : Self.squeezeScale,
                           duration: 0.09, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
        }
    }
}

/// A segment of a circle's edge as a filled shape rather than a stroke.
///
/// Glass takes a shape, not a `ShapeStyle`, so the resting arc has to be an
/// area before it can be made of the material. The circle is inset by half the
/// line width because the glass is masked by this path *within the view's
/// bounds*: run the band along the frame's edge and the outer half of every
/// stroke is cut away.
struct ArcBand: Shape {
    let trim: ClosedRange<CGFloat>
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        Circle()
            .trim(from: trim.lowerBound, to: trim.upperBound)
            .path(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}

/// A handle riding inside the bar, at one end: its glyph faint at rest, a
/// disc of light behind it on hover. Inside the bar's own surface, so it
/// needs no glass or black of its own — the bar is both.
struct InlineHandle: View {
    let glyph: String
    let isHovered: Bool
    var isArmed = false
    var armedGlyph: String? = nil
    var spins: Int = 0
    /// Degrees per spin: a full turn for the gear, a quarter for the move.
    var turn: Double = 360

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.textPrimary.opacity(isHovered || isArmed ? 0.16 : 0))
            if isArmed {
                Circle()
                    .strokeBorder(Palette.textPrimary.opacity(0.9),
                                  style: StrokeStyle(lineWidth: Design.px(5), lineCap: .round, dash: [Design.px(8), Design.px(9)]))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Image(systemName: isArmed ? (armedGlyph ?? glyph) : glyph)
                .font(.system(size: NotchLayout.inlineOrbGlyph, weight: .medium))
                .foregroundStyle(Palette.textPrimary.opacity(isHovered || isArmed ? 1 : 0.4))
                .rotationEffect(.degrees(Double(spins) * turn))
                .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.55, dampingFraction: 0.72),
                                                              reduceMotion), value: spins)
        }
        .frame(width: NotchLayout.inlineOrbDiameter, height: NotchLayout.inlineOrbDiameter)
        .scaleEffect(isHovered ? 1.06 : 1)
        .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.3, dampingFraction: 0.75), reduceMotion),
                   value: isHovered)
        .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.4, dampingFraction: 0.68), reduceMotion),
                   value: isArmed)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: spins) { handle, scale in
            handle.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(reduceMotion ? 1 : 0.84, duration: 0.09, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
        }
    }
}
