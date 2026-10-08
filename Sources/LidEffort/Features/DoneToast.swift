import SwiftUI

/// What the card says when a session finishes, or stops to ask. Not a
/// status report: the agent just did a piece of work for you, and the
/// line should sound like someone on the team who noticed. One of several,
/// picked per session so the same card does not say the same thing all
/// afternoon; the pick is a function of the session, not the draw.
enum DoneCheer {
    struct Line: Equatable {
        let title: String
        let status: String
    }

    static var finished: [Line] {
        [
            Line(title: L10n.t("Shipped it!"),           status: L10n.t("Keep building.")),
            Line(title: L10n.t("Task done. Nice."),      status: L10n.t("Your move, builder.")),
            Line(title: L10n.t("Boom. Done."),           status: L10n.t("Fresh output. Go look.")),
            Line(title: L10n.t("One more brick laid"),   status: L10n.t("Ready for your prompt")),
            Line(title: L10n.t("Done and dusted"),       status: L10n.t("Take the win. Next.")),
            Line(title: L10n.t("Your agent delivered"),  status: L10n.t("Review it. Ship it.")),
            Line(title: L10n.t("That's a wrap"),         status: L10n.t("Ready when you are.")),
            Line(title: L10n.t("Green light, builder"),  status: L10n.t("Onward.")),
        ]
    }

    static var blocked: [Line] {
        [
            Line(title: L10n.t("Needs your answer"),         status: L10n.t("Pick a road.")),
            Line(title: L10n.t("Your agent has a question"), status: L10n.t("One answer, then go.")),
            Line(title: L10n.t("Waiting on you, boss"),      status: L10n.t("It needs a decision.")),
            Line(title: L10n.t("Quick check-in"),            status: L10n.t("Quick call needed.")),
        ]
    }

    static func line(for session: AgentSession, blocked: Bool) -> Line {
        let lines = blocked ? self.blocked : finished
        let name = session.name.utf8.reduce(Int64(0)) { $0 &* 31 &+ Int64($1) }
        let stamp = Int64(session.since.timeIntervalSince1970)
        return lines[ResetCheer.mix(stamp, name, count: lines.count)]
    }
}

/// A session just finished, or stopped to ask something. Said in a card
/// beside the folded pill rather than by opening the whole notch: the
/// notch opening was the announcement getting in the way of the work it
/// was announcing.
struct DoneToast: Equatable, Identifiable {
    let id = UUID()
    let title: String
    /// The session, and where it runs — "effort-lid · Terminal · Effort Lid".
    let subtitle: String
    /// What that means for you, on the status line.
    var status: String {
        guard let changes, !isBlocked else { return line }
        return "\(changes) · \(line)"
    }
    /// The cheer, or the question it is asking.
    private let line: String
    /// What is changed in its folder, once git has said — "3 files · +42 −7".
    var changes: String?
    let glyph: ProviderGlyph
    let isBlocked: Bool
    let pid: pid_t?
    /// The session itself, for ⌥-click → reply.
    let session: AgentSession

    /// - Parameter context: what you last asked the session and what it said
    ///   at the end, where its transcript can be read. Several sessions can
    ///   share one folder; the folder alone did not say which one to answer.
    init(event: SessionCompletionWatcher.Event, glyph: ProviderGlyph, context: PromptContext? = nil) {
        let session = event.session
        isBlocked = event.reason == .blocked
        let line = DoneCheer.line(for: session, blocked: isBlocked)
        // Which piece of work: the name you gave the session, or else what
        // you last asked it. The cheer only when neither is known.
        title = context?.title ?? context?.ask.map { "“\($0)”" } ?? line.title
        subtitle = session.detail.isEmpty ? session.name : "\(session.name) · \(session.detail)"
        // The question itself beats any line about there being one, and
        // what the agent said at the end beats a cheer.
        if isBlocked, let question = session.waitingFor, !question.isEmpty {
            self.line = L10n.t("Asking: \(question)")
        } else if !isBlocked, let lead = context?.lead {
            self.line = lead
        } else {
            self.line = line.status
        }
        self.glyph = glyph
        pid = session.processID
        self.session = session
    }

    static func == (lhs: DoneToast, rhs: DoneToast) -> Bool { lhs.id == rhs.id }

    /// What you asked a session and what it said last, from the tail of its
    /// transcript, for an agent whose transcript pillr can find: Claude Code.
    @MainActor static func context(for session: AgentSession) -> PromptContext? {
        guard let pid = session.processID, Handoff.source(of: session) == .claude,
              let cwd = SessionFocus.currentDirectory(of: pid),
              let transcript = Handoff.claudeTranscript(pid: pid, cwd: cwd) else { return nil }
        return PromptContext.load(transcript: transcript.path, cwd: nil)
    }
}

/// The card: glyph, title, the session and where it runs, and a status line
/// in the colour that says finished (green) or waiting (amber) — on the
/// chrome every notch card shares, its tail pointing at the pill.
struct DoneToastView: View {
    let toast: DoneToast
    var direction: NotchEdge.TooltipDirection = .trailing
    var tailOffset: CGFloat = 0

    static var cardHeight: CGFloat {
        2 * NotchLayout.cardPadding + NotchCardHeader.height
            + NotchLayout.headerToBlock + NotchLayout.cardBodyLineHeight
    }

    private var tone: Color { toast.isBlocked ? Palette.watch : Palette.ample }

    static func canReply(_ toast: DoneToast) -> Bool { SessionCommander.reach(toast.session) != .none }

    /// The round Reply button beside the card: its size and its gap from
    /// the card, before the card scale.
    static let replyBubble = Design.px(80)
    static let replyBubbleGap = Design.px(16)

    /// Where the bubble sits, as (along, across) centre offsets the root
    /// view and the controller share: just past the card's end along the
    /// edge, level with the card's body across it.
    static func replyBubbleCentre(edge: NotchEdge, scale: CGFloat, restingDepth: CGFloat,
                                  alongCentre: CGFloat) -> (along: CGFloat, across: CGFloat) {
        let cardAlong = (edge.isVertical ? cardHeight : NotchLayout.cardWidth) * scale
        let cardAcross = (edge.isVertical ? NotchLayout.cardWidth : cardHeight) * scale
        let along = alongCentre + cardAlong / 2 + (replyBubbleGap + replyBubble / 2) * scale
        let across = restingDepth + NotchLayout.tailGap + NotchLayout.tailLength * scale + cardAcross / 2
        return (along, across)
    }

    var body: some View {
        NotchCardChrome(height: Self.cardHeight, direction: direction, tailOffset: tailOffset) {
            VStack(alignment: .leading, spacing: 0) {
                NotchCardHeader(glyph: toast.glyph, title: toast.title, subtitle: toast.subtitle)
                // "Click to open" only where a click opens something, and
                // not over what the session changed, which matters more.
                NotchCardStatus(tone: tone, text: toast.status,
                                trailing: toast.pid != nil && toast.changes == nil ? L10n.t("Click to open") : nil)
                    .padding(.top, NotchLayout.headerToBlock)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(toast.title), \(toast.subtitle), \(toast.status)")
    }
}

/// The round Reply button that stands beside the done card — a separate
/// piece of glass, not part of the card, with the reply arrow on it.
struct ReplyBubble: View {
    @Environment(\.notchSurfaceStyle) private var surfaceStyle
    @Environment(\.notchReduceTransparency) private var reduceTransparency

    /// The card's own surface: glass beside a glass card, solid beside a solid one.
    private var glassy: Bool { surfaceStyle.effective == .glass && !reduceTransparency }

    var body: some View {
        ZStack {
            if glassy {
                GlassShape(corner: DoneToastView.replyBubble / 2)
            } else {
                Circle().fill(Palette.card)
                    .overlay(Circle().strokeBorder(Palette.ringTrack.opacity(reduceTransparency ? 1 : 0), lineWidth: 1))
            }
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: Design.px(28), weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(width: DoneToastView.replyBubble, height: DoneToastView.replyBubble)
        // A ring breathing out of it while the card is up: the session
        // is waiting for its next instruction, and this is where it goes.
        .background { ReplyPulse(size: DoneToastView.replyBubble) }
        .help(L10n.t("Reply"))
        .accessibilityLabel(L10n.t("Reply"))
    }
}

/// Two soft rings swelling out of the Reply button and fading, one after
/// the other — "this is the next thing to do". Still, with Reduce Motion:
/// one quiet ring instead.
private struct ReplyPulse: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().strokeBorder(Palette.ample.opacity(0.55), lineWidth: Design.px(3))
                .frame(width: size + Design.px(10), height: size + Design.px(10))
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<2) { ring in
                        let phase = (t / 1.6 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(Palette.ample.opacity(0.7 * (1 - phase)), lineWidth: Design.px(3))
                            .frame(width: size, height: size)
                            .scaleEffect(1 + 0.55 * phase)
                    }
                    Circle()
                        .fill(Palette.ample.opacity(0.18 + 0.1 * sin(t * 3.9)))
                        .frame(width: size, height: size)
                        .blur(radius: Design.px(8))
                }
            }
            .allowsHitTesting(false)
        }
    }
}
