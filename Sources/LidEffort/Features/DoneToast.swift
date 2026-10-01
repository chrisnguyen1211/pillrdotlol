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
    let status: String
    let glyph: ProviderGlyph
    let isBlocked: Bool
    let pid: pid_t?

    init(event: SessionCompletionWatcher.Event, glyph: ProviderGlyph) {
        let session = event.session
        isBlocked = event.reason == .blocked
        let line = DoneCheer.line(for: session, blocked: isBlocked)
        title = line.title
        subtitle = session.detail.isEmpty ? session.name : "\(session.name) · \(session.detail)"
        // The question itself beats any line about there being one.
        if isBlocked, let question = session.waitingFor, !question.isEmpty {
            status = L10n.t("Asking: \(question)")
        } else {
            status = line.status
        }
        self.glyph = glyph
        pid = session.processID
    }

    static func == (lhs: DoneToast, rhs: DoneToast) -> Bool { lhs.id == rhs.id }
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

    var body: some View {
        NotchCardChrome(height: Self.cardHeight, direction: direction, tailOffset: tailOffset) {
            VStack(alignment: .leading, spacing: 0) {
                NotchCardHeader(glyph: toast.glyph, title: toast.title, subtitle: toast.subtitle)
                NotchCardStatus(tone: tone, text: toast.status, trailing: L10n.t("Click to open"))
                    .padding(.top, NotchLayout.headerToBlock)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(toast.title), \(toast.subtitle), \(toast.status)")
    }
}
