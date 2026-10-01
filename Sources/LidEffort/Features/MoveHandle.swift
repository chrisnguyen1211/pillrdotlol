import SwiftUI

/// The move control, above the notch — the mirror of `SettingsOrb` below it.
///
/// At rest it is the same bare arc the settings orb is, for the same reason:
/// the notch is meant to be glanceable, and a second permanently visible glyph
/// competes with the readings. On hover the arc fills in and takes a hand,
/// which turns as it arrives. Holding it starts a move.
///
/// The hand rather than arrows because the gesture is a carry, not a nudge: you
/// pick the notch up and put it on another edge. Arrows would suggest the
/// ⌥-drag that already exists, which slides it *along* the edge it is on.
struct MoveHandle: View {
    let isHovered: Bool
    /// True once the handle has been held and the notch is waiting to be
    /// dropped. The disc goes dashed and the hand stops turning: it is being
    /// carried now, not offered.
    var isArmed: Bool = false
    var edge: NotchEdge = .right
    /// Riding inside a bar hung from the bezel: a glyph, not an arc.
    var inline = false
    /// True when the arc traces the bar's own rounded corner from outside
    /// rather than a flare from inside — see `SettingsOrb.convex`.
    var convex: Bool = false
    var arcRadius: CGFloat = NotchLayout.orbArcRadius
    var arcOffset: CGSize = .zero
    /// How many times the hand has been asked to turn, on the same counter
    /// pattern `SettingsOrb.spins` uses.
    var spins: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.notchReduceTransparency) private var reduceTransparency

    private var glassy: Bool { surfaceStyle.effective == .glass && !reduceTransparency }

    /// The resting arc occupies the quarter of the circle facing the notch it
    /// hangs off and the bezel it merges into — the same two directions
    /// `SettingsOrb` faces, with only the first of them reversed: this hangs
    /// off the *near* end of the stack rather than the far one, but it is on
    /// the same screen edge.
    ///
    /// Reflected along the stack, **not** rotated by half a circle. A half turn
    /// reverses both directions at once, which sends the arc away from the
    /// bezel and into the middle of the screen — it curls the wrong way, and on
    /// a side edge it reads as visibly crooked against the flare it is supposed
    /// to parallel. So a vertical edge swaps up for down and keeps its side of
    /// the screen; a horizontal one swaps left for right and keeps its top or
    /// bottom.
    static func restingTrim(for edge: NotchEdge, convex: Bool) -> ClosedRange<CGFloat> {
        let settings = SettingsOrb.restingTrim(for: edge, convex: convex)
        return mirroredAlongStack(settings, isVertical: edge.isVertical)
    }

    /// Reflects a quadrant across the axis that runs *out of* the screen edge,
    /// leaving the other axis — the one that says which edge this is — alone.
    ///
    /// A quadrant is identified by its lower bound, in SwiftUI's trim space:
    /// 0 is three o'clock and it runs clockwise with y growing downward. So
    /// reflecting vertically (up ↔ down) maps 0.75↔0.0 and 0.5↔0.25, and
    /// reflecting horizontally (left ↔ right) maps 0.5↔0.75 and 0.25↔0.0.
    static func mirroredAlongStack(
        _ quadrant: ClosedRange<CGFloat>, isVertical: Bool
    ) -> ClosedRange<CGFloat> {
        // Both reflections are `constant - lower`, taken mod 1: 0.75 for the
        // vertical flip, 1.25 for the horizontal one.
        let constant: CGFloat = isVertical ? 0.75 : 1.25
        let lower = (constant - quadrant.lowerBound).truncatingRemainder(dividingBy: 1)
        return lower...(lower + 0.25)
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

    /// How far the button dips under a click — the settings orb's depth, so the
    /// two controls on the same notch press the same amount.
    private static let squeezeScale: CGFloat = 0.84

    /// The dashes on the armed disc. Long enough to read as a dashed ring at
    /// 46pt rather than as a dotted blur.
    private static let armedDash: [CGFloat] = [Design.px(14), Design.px(12)]

    @ViewBuilder
    private var restingArc: some View {
        if glassy {
            if #available(macOS 26.0, *) {
                // The glass is the band itself, so it has a rim — see
                // `SettingsOrb.restingArc`.
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

    /// The dashed ring that says the notch is in hand. Drawn over the disc
    /// rather than instead of it, so arming reads as the same button changing
    /// state rather than as a different button.
    private var armedRing: some View {
        Circle()
            .strokeBorder(
                Palette.textPrimary.opacity(0.9),
                style: StrokeStyle(lineWidth: NotchLayout.orbStroke / 2,
                                   lineCap: .round,
                                   dash: Self.armedDash)
            )
            .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
    }

    var body: some View {
        if inline {
            InlineHandle(glyph: "arrow.clockwise", isHovered: isHovered, isArmed: isArmed,
                         armedGlyph: "arrow.clockwise.circle.fill", spins: spins, turn: 90)
        } else {
            handle
        }
    }

    private var handle: some View {
        ZStack {
            restingArc
                .rotationEffect(.degrees(restingRotation))
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(isHovered ? 0.86 : 1)
                .offset(arcOffset)

            hoverDisc
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 1.1)

            armedRing
                .opacity(isArmed ? 1 : 0)
                .scaleEffect(isArmed ? 1 : 0.8)

            // A clockwise arrow: a click sends the notch on to the next side
            // round the screen, and the glyph turns a quarter with each one.
            Image(systemName: isArmed ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                // Two rotations on one glyph, as the gear has: the wake-up
                // from the hover state, and a turn per arm. Summed so arming
                // mid-hover does not fight the -60 the hand is arriving from.
                // A quarter turn, not a full one — the hand is being offered,
                // and a whole revolution reads as a spinner.
                .rotationEffect(.degrees((isHovered ? 0 : -60) + Double(spins) * 90))
                .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.55,
                                                                      dampingFraction: 0.72),
                                                              reduceMotion),
                           value: spins)
        }
        .frame(width: arcRadius * 2 + NotchLayout.orbStroke,
               height: arcRadius * 2 + NotchLayout.orbStroke)
        .animation(
            NotchMotion.respectingReduceMotion(
                .spring(response: 0.36, dampingFraction: 0.7), reduceMotion
            ),
            value: isHovered
        )
        .animation(
            NotchMotion.respectingReduceMotion(
                .spring(response: 0.4, dampingFraction: 0.68), reduceMotion
            ),
            value: isArmed
        )
        .keyframeAnimator(initialValue: CGFloat(1), trigger: spins) { handle, scale in
            handle.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(reduceMotion ? 1 : Self.squeezeScale,
                           duration: 0.09, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
        }
    }
}
