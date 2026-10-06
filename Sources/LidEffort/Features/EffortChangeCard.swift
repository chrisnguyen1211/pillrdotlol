import SwiftUI
import LidEffortCore

/// The card that appears beside the notch when the lid moves: the level it
/// is at, on a bar that follows the lid live while it is still moving and
/// settles on the level once it has rested — which is when the level
/// actually changes. Same construction as `UsageResetCard`, so it sits
/// where that card sits.
struct EffortChangeCard: View {
    let event: EffortChangeEvent
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    /// Where the lid is right now, in levels, while it is still moving; nil
    /// once it has rested and `event.level` is the fact.
    var livePosition: Double? = nil
    /// The bar let go on a level by hand.
    var onSet: ((Int) -> Void)? = nil

    @Environment(\.notchAccentColor) private var accentColor
    @Environment(\.notchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle

    /// Measured from what the card holds: the header, the bar, the
    /// agents' values and the note under them, each wrapped to the card's
    /// column. A fixed height clipped the note off the bottom whenever the
    /// values took their second line, which was exactly when there was the
    /// most to say.
    static func cardHeight(for event: EffortChangeEvent) -> CGFloat {
        var height = 2 * NotchLayout.cardPadding
            + max(NotchLayout.glyphSize, NotchLayout.cardTitleLineHeight + NotchLayout.cardBodyLineHeight)
            + NotchLayout.headerToBlock + NotchLayout.effortBarKnob
        if !event.values.isEmpty {
            height += valuesGap + min(NotchLayout.bodyTextHeight(valuesText(event)), 2 * NotchLayout.cardBodyLineHeight)
        }
        if let note = event.note {
            height += noteGap + min(NotchLayout.bodyTextHeight(note), CGFloat(noteLines) * NotchLayout.cardBodyLineHeight)
        }
        return height.rounded(.up)
    }

    private static let valuesGap = Design.px(12)
    private static let noteGap = Design.px(4)
    /// The note says why a change is waiting and what happens next — in
    /// French or Russian that is a third line, not an ellipsis.
    static let noteLines = 3

    static func valuesText(_ event: EffortChangeEvent) -> String {
        event.values.map { "\($0.name) \($0.value)" }.joined(separator: " · ")
    }

    private var cardHeight: CGFloat { Self.cardHeight(for: event) }

    private var glassy: Bool { surfaceStyle.effective == .glass && !reduceTransparency }
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    /// The level the title names. Live, it is the level the lid *would*
    /// settle on from here — by the same halfway rule `settle` applies —
    /// so the title never promises a step the rest will not take.
    private var shownLevel: EffortLevel {
        guard let livePosition else { return event.level }
        let delta = livePosition - Double(event.level.rawValue)
        let raw = event.level.rawValue + StepController.steps(for: delta)
        return EffortLevel(rawValue: min(EffortLevel.allCases.count - 1, max(0, raw))) ?? event.level
    }

    /// The title's word for it: the level, or — once the lid is still — a
    /// choice past the levels (`ultracode`) by its own name.
    private var shownName: String {
        if livePosition == nil, let choice = event.choice { return choice }
        return shownLevel.displayName
    }

    /// What this changes, named: the session and its model, or every
    /// agent's next sessions. The question "the effort of what?" answered
    /// before ⌘ is let go, while there is still time to look elsewhere.
    private var subtitle: String {
        if event.isHint { return L10n.t("Lid alone only changes the angle") }
        if let reason = event.reason { return reason }
        if let aim = event.aim { return aim.text }
        return L10n.t("New sessions · every agent")
    }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        // The blurred desktop under the glass, or the glass has
                        // nothing to bend — see `GlassBackdrop`.
                        CardGlass(shape: TooltipSilhouette(direction: direction, tailOffset: tailOffset))
                    }
                }
            }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NotchLayout.headerGap) {
                    // The agent whose session it changes; the lid when it is every agent's.
                    Group {
                        if let agent = event.aim?.agent, let glyph = ProviderGlyph.forProvider(agent) {
                            ProviderGlyphView(glyph: glyph, size: NotchLayout.glyphSize)
                        } else {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: Design.px(34), weight: .regular))
                        }
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: NotchLayout.glyphSize, height: NotchLayout.glyphSize)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.isHint
                             ? L10n.t("Hold ⌘ to change effort")
                             : L10n.t("Effort → \(shownName)"))
                            .font(Typography.cardTitle)
                            .foregroundStyle(event.isHint ? Palette.textPrimary : EffortColor.color(level: shownLevel))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .contentTransition(.numericText())
                        Text(subtitle)
                            .font(Typography.cardBody)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                EffortBar(count: EffortLevel.allCases.count,
                          position: livePosition ?? Double(event.level.rawValue),
                          tint: EffortColor.color(level: shownLevel),
                          onSet: onSet)
                    .padding(.top, NotchLayout.headerToBlock)

                if !event.values.isEmpty {
                    Text(Self.valuesText(event))
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Self.valuesGap)
                }
                // The session in view, when it could not simply be told:
                // amber for "next session", green for "typed in".
                if let note = event.note {
                    Text(note)
                        .font(Typography.cardBody)
                        .foregroundStyle(event.noteIsLive ? Palette.ample : Palette.watch)
                        .lineLimit(Self.noteLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Self.noteGap)
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: cardHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: shownLevel)
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? tailOffset : 0,
                    y: direction == .leading || direction == .trailing ? tailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}

extension NotchLayout {
    /// spyx's surface: a capsule, not a flared notch.
    static let pillShape = true
    /// The gauge with nothing to seat: three quarters of a circle, open at
    /// the bottom.
    static let defaultGaugeGapDegrees: Double = 90
    /// The effort dots: one size, and the same distance between them. The
    /// gauge's opening grows to fit however many a model has.
    static let effortDotSize = Design.px(8)
    /// Radius of the circle the dots and the track share.
    static var gaugeRadius: CGFloat { ringDiameter / 2 - trackStroke / 2 }
    /// Degrees per dot pitch along that circle: one dot plus one gap.
    static var effortDotPitchDegrees: Double { Double(2 * effortDotSize / gaugeRadius) * 180 / .pi }
    /// The opening a run of `dotCount` dots needs — their pitch, plus the
    /// arc's round caps and half a dot of air at either end — never less
    /// than the resting gauge's own.
    static func gaugeGapDegrees(dotCount: Int) -> Double {
        guard dotCount > 0 else { return defaultGaugeGapDegrees }
        let run = Double(dotCount - 1) * effortDotPitchDegrees
        let clearance = Double((trackStroke / 2 + effortDotSize) / gaugeRadius) * 180 / .pi
        return max(defaultGaugeGapDegrees, run + 2 * clearance)
    }

    /// The bar in the card and the tooltip: a track, a knob, a tick per
    /// level. The knob is the row's height; the track sits in its middle.
    static let effortBarTrack = Design.px(11)
    static let effortBarKnob = Design.px(21)
    static let effortBarTick = Design.px(4)
    /// The frost under a card that carries text: the pill's own, but never
    /// below a floor. Over a dark window a card as clear as the pill left
    /// its text unreadable; above the floor it still follows the slider, so
    /// the card and the pill read as one glass.
    static func cardFrost(_ pillFrost: CGFloat) -> CGFloat {
        0.45 + 0.55 * min(1, max(0, pillFrost))
    }
    /// Above and below the effort row inside its well.
    static let effortWellPadding = Design.px(14)

    /// How long the sheen runs after the pill folds, once.
    static let pillSheenDuration: TimeInterval = 2.4
}

/// The dots that finish the gauge's circle: one per level on the model's
/// scale, seated on the same circle as the track, one dot apart, filled left
/// to right up to the current value.
struct EffortArcDots: View {
    let state: EffortDotState
    let gapDegrees: Double

    var body: some View {
        let radius = NotchLayout.gaugeRadius
        let pitch = NotchLayout.effortDotPitchDegrees
        let run = Double(state.count - 1) * pitch
        ZStack {
            ForEach(0..<state.count, id: \.self) { index in
                // A value only a live session takes (Claude's max,
                // ultracode) is a hollow dot until the value reaches it: no
                // config can hold it, so it is never "set" the way the
                // others are.
                Group {
                    if state.liveOnly.contains(index), index >= state.filled {
                        Circle().strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.effortDotSize / 4)
                    } else {
                        Circle().fill(index < state.filled ? Palette.textPrimary : Palette.ringTrack)
                    }
                }
                .frame(width: NotchLayout.effortDotSize, height: NotchLayout.effortDotSize)
                .offset(y: -radius)
                // 0° is 12 o'clock and positive is clockwise, so the gap's
                // left end is past 180°; walk it right-to-left in angle so
                // the dots fill left to right, in reading order.
                .rotationEffect(.degrees(180 + run / 2 - Double(index) * pitch))
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }
}

/// A level on a scale, as a volume slider: one track, a tick per level, a
/// fill from the left up to a round knob. `position` is continuous, so the
/// knob can follow a lid that is still moving; press or drag the knob to
/// set a level by hand. At the top of the scale the fill runs with colour —
/// everything the model has, and the bar says so.
struct EffortBar: View {
    let count: Int
    /// 0 … count − 1, continuous.
    let position: Double
    /// The fill's colour; nil takes the accent.
    var tint: Color? = nil
    /// Let go on a level. Nil makes the bar read-only.
    var onSet: ((Int) -> Void)? = nil
    /// Levels only a live session takes, by index: their ticks are rings.
    var liveOnly: Set<Int> = []

    @Environment(\.notchAccentColor) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragIndex: Int?

    private var shown: Double { dragIndex.map(Double.init) ?? position }
    private var fraction: CGFloat {
        count > 1 ? CGFloat(min(1, max(0, shown / Double(count - 1)))) : 1
    }
    private var isMax: Bool { count > 1 && shown >= Double(count - 1) - 0.01 }
    private var colour: Color { tint ?? accent }

    var body: some View {
        GeometryReader { proxy in
            let knob = NotchLayout.effortBarKnob
            let track = NotchLayout.effortBarTrack
            let mid = proxy.size.height / 2
            // The knob's centre travels from half a knob in to half a knob
            // short of the end, so it never overhangs the row.
            let usable = max(0, proxy.size.width - knob)
            let x = knob / 2 + usable * fraction

            ZStack {
                Capsule()
                    .fill(Palette.barTrack)
                    .frame(width: proxy.size.width, height: track)
                    .position(x: proxy.size.width / 2, y: mid)

                // Light at the low end, full colour under the knob: the fill
                // says how far up the scale it is before the knob is found.
                Capsule()
                    .fill(LinearGradient(colors: [colour.opacity(0.25), colour],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(track, x), height: track)
                    .position(x: max(track, x) / 2, y: mid)

                if isMax, !reduceMotion {
                    MagicFlow.Stream(width: max(track, x), height: track)
                        .position(x: max(track, x) / 2, y: mid)
                }

                ForEach(0..<count, id: \.self) { index in
                    let at = count > 1 ? knob / 2 + usable * CGFloat(index) / CGFloat(count - 1) : x
                    let tone = Palette.textPrimary.opacity(Double(index) <= shown + 0.01 ? 0.7 : 0.35)
                    Group {
                        if liveOnly.contains(index) {
                            Circle().strokeBorder(tone, lineWidth: 1)
                                .frame(width: NotchLayout.effortBarTick + 2, height: NotchLayout.effortBarTick + 2)
                        } else {
                            Circle().fill(tone)
                                .frame(width: NotchLayout.effortBarTick, height: NotchLayout.effortBarTick)
                        }
                    }
                    .position(x: at, y: mid)
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragIndex != nil ? 1.15 : 1)
                    .position(x: x, y: mid)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard onSet != nil else { return }
                        dragIndex = index(at: value.location.x, knob: knob, usable: usable)
                    }
                    .onEnded { value in
                        guard let onSet else { return }
                        let index = index(at: value.location.x, knob: knob, usable: usable)
                        dragIndex = nil
                        onSet(index)
                    }
            )
        }
        .frame(height: NotchLayout.effortBarKnob)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: position)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: dragIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort \(Int(shown.rounded()) + 1) of \(count)")
    }

    private func index(at x: CGFloat, knob: CGFloat, usable: CGFloat) -> Int {
        guard count > 1, usable > 0 else { return 0 }
        let fraction = (x - knob / 2) / usable
        return min(count - 1, max(0, Int((Double(fraction) * Double(count - 1)).rounded())))
    }
}

/// The tooltip's effort line: what the lid set this provider's config to,
/// on that model's own scale, and a bar to set it by. Ringed ticks are
/// values only the session in view takes — for Claude Code, `max` and,
/// past it, `ultracode` — typed in when the bar is let go on them.
struct EffortRow: View {
    let value: String
    var dots: EffortDotState? = nil
    var onSet: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: Design.px(12)) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: Design.px(20), weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            Text(L10n.t("Effort"))
                .font(Typography.cardLabel)
                .foregroundStyle(Palette.textPrimary)
            if let dots, dots.count > 1 {
                EffortBar(count: dots.count, position: Double(max(0, dots.filled - 1)), onSet: onSet,
                          liveOnly: dots.liveOnly)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            Text(value)
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textPrimary)
            Text(L10n.t("· lid"))
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(height: NotchLayout.cardBodyLineHeight)
        // Its own layer: a well set into the card, so the one control in the
        // tooltip reads apart from the readings above it and the sessions
        // below — it is the thing you change, not a thing you read.
        .padding(.vertical, NotchLayout.effortWellPadding)
        .padding(.horizontal, Design.px(18))
        .background(
            RoundedRectangle(cornerRadius: Design.px(22), style: .continuous)
                .fill(Palette.textPrimary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.px(22), style: .continuous)
                .strokeBorder(Palette.textPrimary.opacity(0.1), lineWidth: 1)
        )
        .padding(.top, NotchLayout.headerToBlock)
    }
}

/// In place of the effort bar, for an agent that is not signed in: why, and
/// the one button that does something about it — the same well, the same
/// height, so the card does not change shape.
struct ConnectRow: View {
    let need: ConnectNeed
    let action: () -> Void

    private var help: String {
        if case .terminal(let command) = need.action { return L10n.t("Opens Terminal and runs \(command)") }
        return need.buttonTitle
    }

    var body: some View {
        HStack(spacing: Design.px(12)) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: Design.px(22), weight: .medium))
                .foregroundStyle(Palette.watch)
            Text(need.reason)
                .font(Typography.cardLabel)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Design.px(8))
            NotchButton(title: need.buttonTitle, role: .primary, action: action)
                .fixedSize()
                .help(help)
        }
        .frame(height: NotchLayout.cardBodyLineHeight)
        .padding(.vertical, NotchLayout.effortWellPadding)
        .padding(.horizontal, Design.px(18))
        .background(
            RoundedRectangle(cornerRadius: Design.px(22), style: .continuous)
                .fill(Palette.watch.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.px(22), style: .continuous)
                .strokeBorder(Palette.watch.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, NotchLayout.headerToBlock)
        .accessibilityElement(children: .combine)
    }
}
