import SwiftUI
import LidEffortCore

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
///
/// When that provider is doing something right now, a second, much thinner arc
/// appears *inside* the ring, in the gap between the glyph and the track. It is
/// deliberately a different radius, a different weight and a neutral colour, so
/// it reads as a separate fact rather than as the usage number moving.
struct ProviderRing: View {
    /// Nil when the provider reports what is left but never says out of what —
    /// there is no arc to draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var isStale: Bool = false
    /// Blocked right now. Shown as spent whatever the arc says, because that is
    /// what it means for you — a ring reading 16% while the account is paused
    /// is technically true and practically a lie.
    var isBlocked: Bool = false
    var activity: ActivitySummary?
    /// A fetch this cell asked for, in flight.
    var isRefreshing: Bool = false
    var localPerformance: LocalModelPerformance?
    /// A local model's arc: how full its context was on the last request. Nil
    /// draws the whole ring, which is what a runtime that does not say gets.
    var localContextFraction: Double?
    /// The weekly limit, when the provider has one. Nil is the ordinary case
    /// for a provider with a single window, and draws nothing.
    var weeklyFraction: Double?
    /// Where the user asked for it, if at all.
    var weeklyRing: WeeklyRing = .off
    /// How much of the circle the gauge leaves open at the bottom, in
    /// degrees — sized by the cell for the dots it has to seat there.
    var gaugeGapDegrees: Double = NotchLayout.defaultGaugeGapDegrees

    /// The arc as a fraction of the circle, and where it starts (degrees
    /// from 3 o'clock, clockwise) so the gap is centred on 6 o'clock.
    private var gaugeSweep: CGFloat { CGFloat(1 - gaugeGapDegrees / 360) }
    private var gaugeStart: Double { 90 + gaugeGapDegrees / 2 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchReduceTransparency) private var reduceTransparency
    @Environment(\.notchAccentColor) private var accentColor
    @State private var spin: Double = 0

    private var band: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: usedFraction ?? 0)
    }
    private var sweep: CGFloat { CGFloat(min(max(usedFraction ?? 0, 0), 1)) }
    private var localSweep: CGFloat { CGFloat(min(max(localContextFraction ?? 1, 0), 1)) }

    private var weeklyBand: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: weeklyFraction ?? 0)
    }
    private var weeklySweep: CGFloat { CGFloat(min(max(weeklyFraction ?? 0, 0), 1)) }

    /// Inside, the weekly ring and the working indicator want the same band —
    /// 1.03pt apart, one of them spinning. Rather than shave both until neither
    /// is legible, the transient one wins: while a provider is working that is
    /// the more urgent fact, and the week is still a hover away. Outside there
    /// is no contest, so nothing is given up there.
    private var isWorking: Bool {
        weeklyRing == .inside && activity != nil && activity?.state != .idle
    }

    var body: some View {
        ZStack {
            // Dimming applies to the usage reading only. Whether Claude is
            // working right now is known first-hand and stays at full strength
            // even when the percentage behind it has gone stale.
            ZStack {
                // A gauge, not a ring: the track stops short of the bottom, and
                // the effort dots sit in the gap it leaves under the glyph.
                Circle()
                    .inset(by: NotchLayout.trackStroke / 2)
                    .trim(from: 0, to: gaugeSweep)
                    .stroke(Palette.ringTrack, style: StrokeStyle(lineWidth: NotchLayout.trackStroke, lineCap: .round))
                    .rotationEffect(.degrees(gaugeStart))

                if localPerformance != nil || localContextFraction != nil {
                    // Two facts on one ring: the arc is the context filling up,
                    // the colour is the last response's speed. Inset by half the
                    // stroke so a full arc lands exactly where the solid
                    // `strokeBorder` ring used to, and a runtime with no context
                    // reading looks as it always did. Grey until a speed exists:
                    // the quota colours would say something a local model has
                    // no quota to mean.
                    Circle()
                        .inset(by: NotchLayout.progressStroke / 2)
                        .trim(from: 0, to: localSweep * gaugeSweep)
                        .stroke(
                            localPerformance?.band.color ?? Palette.textSecondary,
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        .rotationEffect(.degrees(gaugeStart))
                        .animation(NotchMotion.reading, value: localSweep)
                        .animation(NotchMotion.reading, value: localPerformance?.band)
                } else if usedFraction != nil {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep * gaugeSweep)
                        .stroke(
                            band.color(accent: accentColor),
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        // Refreshing spins the reading itself rather than
                        // overlaying a separate spinner: the thing being
                        // refetched is the thing that should move, and a second
                        // arc on the same track only competes with it.
                        .rotationEffect(.degrees(gaugeStart + spin))
                        // A ring that snaps to a new value reads as a glitch; one
                        // that sweeps reads as a measurement being taken.
                        .animation(NotchMotion.reading, value: sweep)
                        .animation(NotchMotion.reading, value: band)
                }

                // The weekly limit, when there is one and it has been asked
                // for. Same start and direction as the headline arc, so the
                // two are read the same way round; thinner and at its own
                // radius, so which is which never has to be worked out.
                //
                // It carries its own band colour rather than borrowing the
                // headline's: a session at 12% beside a week at 91% is exactly
                // the case this exists for, and painting them the same colour
                // would hide it. Held slightly back in opacity so the headline
                // stays the one the eye lands on first.
                if let radius = weeklyRing.radius, weeklyFraction != nil, !isWorking {
                    let inset = NotchLayout.ringDiameter / 2 - radius

                    // A track of its own, for the same reason the headline has
                    // one: a week nobody has spent yet draws an arc of zero
                    // length, and without something behind it that is
                    // indistinguishable from the feature being broken. Codex
                    // opened its week at 0% and read as missing.
                    Circle()
                        .inset(by: inset)
                        .stroke(Palette.ringTrack,
                                style: StrokeStyle(lineWidth: NotchLayout.weeklyRingStroke))
                        .opacity(reduceTransparency ? 1 : 0.7)

                    Circle()
                        .inset(by: inset)
                        .trim(from: 0, to: weeklySweep)
                        .stroke(
                            weeklyBand.color(accent: accentColor),
                            style: StrokeStyle(lineWidth: NotchLayout.weeklyRingStroke,
                                               lineCap: .round)
                        )
                        .opacity(reduceTransparency ? 1 : 0.8)
                        .rotationEffect(.degrees(-90))
                        .animation(NotchMotion.reading, value: weeklySweep)
                        .animation(NotchMotion.reading, value: weeklyBand)
                }

                ProviderBadge(glyph: glyph)
                    // Working: the agent's own mark breathes, dim to bright
                    // and back — the logo is what is busy, not a ring of dots.
                    .modifier(Breathing(active: activity?.state == .working))
                    // A spent limit dims its glyph so the ring reads as "waiting".
                    // Under reduce-transparency, boost opacity so it stays legible without low alpha.
                    .opacity(band == .exhausted ? (reduceTransparency ? 0.7 : 0.35) : 1)
            }
            .opacity(isStale ? (reduceTransparency ? 0.75 : 0.45) : 1)

            if let activity, activity.state != .idle {
                ActivityArc(summary: activity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, and released when the answer lands. The
        // ring is the button, so the ring is what should feel pressed.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, and it stops by itself.
            //
            // The obvious spelling is a `repeatForever` linear spin started on
            // the way in and cancelled on the way out — but `repeatForever` does
            // not stop when you set the value back, and if the value you set is
            // the one it is already animating toward, nothing changes and it
            // simply keeps going. The ring then spins for ever after a refresh
            // that finished half a second in.
            //
            // A single finite turn has no cancellation problem at all: 360° is
            // the same angle as 0°, so it lands exactly where the reading
            // belongs. It eases out, so it settles rather than stopping dead.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) {
                spin += 360
            }
        }
    }
}

/// The inner indicator: a short arc that spins while work is happening, and a
/// full pulsing ring when something is blocked waiting on you.
private struct ActivityArc: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchReduceTransparency) private var reduceTransparency
    @State private var pulsing = false


    private var inset: CGFloat {
        (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
    }

    var body: some View {
        Group {
            switch summary.state {
            case .working: spinner
            case .waiting, .success: pulse
            case .idle:    EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }

    /// Dots are a line of things: with requests queued behind the running one
    /// the arc becomes a ring of them, still turning, so a backed-up model is
    /// told apart from a busy one at a glance.
    private var queued: Bool { summary.queued > 0 }

    /// Nothing round the glyph while it works: the glyph itself breathes
    /// (see `Breathing`), which says it without a spinner.
    private var spinner: some View { EmptyView() }

    private var pulse: some View {
        Circle()
            .inset(by: inset)
            .stroke(summary.color, lineWidth: NotchLayout.activityStroke)
            .opacity(pulsing ? (reduceTransparency ? 0.65 : 0.3) : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
    }
}

struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false
    var weeklyRing: WeeklyRing = .off
    /// The lid-driven effort: the model's scale as dots in the gauge's gap,
    /// filled to the current value. Nil draws nothing — most providers have
    /// no such knob.
    var effortDots: EffortDotState? = nil
    /// Whether the slot under the ring is kept. Across a bar with no local
    /// model in it, nothing is ever written there, and the empty slot only
    /// pushed the ring off the bar's middle.
    var showsLabel = true

    /// The gauge opens just enough to seat this model's dots at one size and
    /// one spacing — a model with more levels gets a shorter arc, not
    /// smaller dots.
    private var gaugeGap: Double {
        NotchLayout.gaugeGapDegrees(dotCount: effortDots?.count ?? 0)
    }

    /// A dash, not "0%": nothing read is not the same as nothing used.
    private var readingText: String {
        snapshot.hasReading ? snapshot.headlineText : "—"
    }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: snapshot.localModel == nil && snapshot.hasReading ? snapshot.ringFraction : nil,
                glyph: snapshot.glyph,
                isStale: snapshot.status.isStale || !snapshot.hasReading,
                isBlocked: snapshot.block != nil,
                activity: activity,
                isRefreshing: isRefreshing,
                localPerformance: snapshot.localPerformance,
                localContextFraction: snapshot.localContextFraction,
                weeklyFraction: snapshot.hasReading ? snapshot.weeklyFraction : nil,
                weeklyRing: weeklyRing,
                gaugeGapDegrees: gaugeGap
            )
            // The dots complete the circle the gauge leaves open: one per
            // level the model has, filled to where it is. The number is a
            // hover away, and the bar to set it by is there too.
            .overlay {
                if let effortDots {
                    EffortArcDots(state: effortDots, gapDegrees: gaugeGap)
                        .animation(NotchMotion.reading, value: effortDots)
                }
            }
            if showsLabel {
            Group {
                if snapshot.localModel != nil {
                    // A local model's reading is the speed of its last answer —
                    // there is no lid level to show instead, so it keeps the label.
                    Text(readingText)
                        .font(Typography.percent)
                        .foregroundStyle(snapshot.showsLocalPerformance && snapshot.localPerformance == nil
                                         ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.percentLineHeight)
                        .contentTransition(.numericText())
                        .animation(NotchMotion.reading, value: readingText)
                } else {
                    Color.clear
                }
            }
            .frame(height: NotchLayout.percentLineHeight, alignment: .top)
            }
        }
        .frame(height: showsLabel ? NotchLayout.cellExtent : NotchLayout.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Everything the cell says, as one sentence for VoiceOver and the tests.
    var accessibilityText: String {
        snapshot.localModel.map {
            "\($0.brand.map { "\($0.displayName), " } ?? "")\($0.name), \(snapshot.displayName) local, \(snapshot.showsLocalPerformance ? (snapshot.localPerformance.map { "Last generation speed \($0.speedText), \($0.band.label)" } ?? "Speed not measured") : "Loaded"), \($0.detail)\(localActivityText)\(localLedgerText)"
        } ?? "\(snapshot.displayName), \(readingText)\(effortDots.map { ", effort \($0.filled) of \($0.count)" } ?? "")"
    }

    /// What the model is doing, the way the tooltip's header says it.
    private var localActivityText: String {
        guard let activity, activity.state == .working else { return "" }
        let phase = activity.sessions.first?.name ?? "Working"
        return activity.queued > 0 ? ", \(phase), \(activity.queued) queued" : ", \(phase)"
    }

    private var localLedgerText: String {
        guard let ledger = snapshot.localLedger else { return "" }
        let context = snapshot.localContextFraction.map { ", Context \(Percent.text(for: $0))% full" } ?? ""
        return "\(context), Tokens today \(ledger.tokensTodayText), \(ledger.requestsTodayText) requests"
    }
}

/// A mark that breathes while its agent works: full, down to a third, and
/// back, 1.3 s a breath. Drawn at 20 frames a second — a slow fade needs no
/// more — and held still under Reduce Motion.
struct Breathing: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let period: Double = 1.3
    static let low: Double = 0.3

    static func opacity(at t: TimeInterval) -> Double {
        let phase = t.truncatingRemainder(dividingBy: period) / period
        // Starts full, dims to `low` half a breath in, and comes back.
        return low + (1 - low) * (0.5 + 0.5 * cos(2 * .pi * phase))
    }

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
                content.opacity(Self.opacity(at: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            content
        }
    }
}
