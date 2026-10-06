import AppKit
import SwiftUI

/// The reply field: one piece of Liquid Glass, a capsule to write in that
/// becomes a card saying where the message went, the words arriving one by
/// one. Sending is quick and does no thinking — the send button spins for
/// as long as it takes, nothing more. Colour is kept to one small dot on
/// the card: green for sent, amber for not. A failure says why and hands
/// the capsule back with the text still in it.
struct OrbReplyView: View {
    let session: AgentSession
    let reach: SessionCommander.Reach
    var demoText: String? = nil
    var onStepAside: () -> Void = {}
    var onReturn: (Bool) -> Void = { _ in }
    let onClose: () -> Void

    enum Phase: Equatable { case idle, card }

    @State private var phase: Phase = .idle
    @State private var text = ""
    @State private var sending = false
    @State private var outcomeGood = true
    @State private var cardTitle = ""
    @State private var cardBody = ""
    @State private var wordsShown = 0
    @State private var shake = 0.0
    @FocusState private var focused: Bool

    private let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    static let stage = CGSize(width: 520, height: 150)
    /// The capsule written in, in the middle of the stage.
    static let fieldSize = CGSize(width: 480, height: 60)
    private let pill = OrbReplyView.fieldSize
    private let card = CGSize(width: 340, height: 118)

    private var shapeSize: CGSize {
        switch phase {
        case .idle: return pill
        case .card: return card
        }
    }
    private var corner: CGFloat { phase == .card ? 20 : shapeSize.height / 2 }
    private var ready: Bool { SessionCommander.oneLine(text) != nil }
    private var placeholder: String {
        let agent = ProviderGlyph.forSession(session)?.agentName ?? ""
        return agent.isEmpty ? L10n.t("Reply to \(session.name)…") : L10n.t("Reply to \(agent) · \(session.name)…")
    }

    var body: some View {
        ZStack {
            ZStack {
                GlassShape(corner: corner)
                if phase == .idle { field.transition(.opacity) }
                if phase == .card { resultCard.transition(.opacity) }
            }
            .frame(width: shapeSize.width, height: shapeSize.height)
            .offset(x: shake)
        }
        .frame(width: Self.stage.width, height: Self.stage.height)
        .onAppear {
            focused = true
            if let demoText { Task { await demo(demoText) } }
        }
        .onExitCommand(perform: onClose)
    }

    // MARK: The pill

    private var field: some View {
        HStack(spacing: 12) {
            // Whose session this is — its agent's mark, not a generic one.
            Group {
                if let glyph = ProviderGlyph.forSession(session) {
                    ProviderGlyphView(glyph: glyph, size: 20)
                } else {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 15))
                }
            }
            .foregroundStyle(.primary.opacity(0.8))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .focused($focused)
                .disabled(reach == .none || demoText != nil || sending)
                .onSubmit(send)
            Button(action: send) {
                ZStack {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ready ? AnyShapeStyle(.background) : AnyShapeStyle(.tertiary))
                    }
                }
                .frame(width: 38, height: 38)
                .background(Circle().fill(ready && !sending ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)))
            }
            .buttonStyle(.plain)
            .help(L10n.t("Send"))
            .animation(.easeOut(duration: 0.2), value: ready)
        }
        .padding(.leading, 20)
        .padding(.trailing, 11)
    }

    // MARK: The card

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(outcomeGood ? Palette.ample : Palette.watch).frame(width: 7, height: 7)
                if let glyph = ProviderGlyph.forSession(session) {
                    ProviderGlyphView(glyph: glyph, size: 14).foregroundStyle(.secondary)
                }
                Text(cardTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            WordsIn(text: cardBody, shown: wordsShown)
                .font(.system(size: 13.5))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Sending

    private func send() {
        guard demoText == nil, phase == .idle, !sending else { return }
        guard ready else { wobble(); return }
        let message = text
        Task { @MainActor in await play(message: message, deliver: {
            var steppedAside = false
            let outcome = await SessionCommander.reply(message, to: session, stepAside: {
                steppedAside = true
                onStepAside()
            })
            if steppedAside {
                switch outcome {
                case .sent, .pasted: onReturn(false)
                default: onReturn(true)
                }
            }
            return outcome
        }) }
    }

    /// Send, then the capsule becomes the card that says how it went:
    /// sent, and it closes; not, and it says why and comes back.
    private func play(message: String, deliver: () async -> SessionCommander.ReplyOutcome) async {
        sending = true
        let outcome = await deliver()
        sending = false

        let good: Bool
        let title: String
        switch outcome {
        case .sent: good = true; title = L10n.t("Sent to \(session.name)")
        case .pasted(let app): good = true; title = L10n.t("Pasted into \(app) — press Return there")
        case .copied(let app): good = true; title = L10n.t("Copied — paste it into the session's tab in \(app)")
        case .busy: good = false; title = L10n.t("\(session.name) is busy or has a draft")
        case .otherSession: good = false; title = L10n.t("Open \(session.name) in the Claude app first")
        case .failed: good = false; title = L10n.t("Not sent to \(session.name)")
        }
        outcomeGood = good
        cardTitle = title
        if case .failed(let reason) = outcome {
            cardBody = L10n.t("\(reason). Your message is kept.")
        } else {
            cardBody = good ? message : L10n.t("Nothing was sent. Your message is kept — try again in a moment.")
        }

        wordsShown = 0
        withAnimation(reduced ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { phase = .card }
        let words = cardBody.split(separator: " ").count
        for index in 0...words {
            withAnimation(.easeOut(duration: 0.22)) { wordsShown = index }
            try? await Task.sleep(for: .milliseconds(reduced ? 0 : min(40, 260 / max(1, words))))
        }

        if good {
            try? await Task.sleep(for: .milliseconds(1300))
            onClose()
        } else {
            try? await Task.sleep(for: .milliseconds(2400))
            withAnimation(reduced ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { phase = .idle }
            focused = true
        }
    }

    private func wobble() {
        let steps: [CGFloat] = [-6, 6, -4, 4, 0]
        Task { @MainActor in
            for step in steps {
                withAnimation(.linear(duration: 0.05)) { shake = step }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The demo: the message typed out, the whole morph played, nothing sent.
    private func demo(_ message: String) async {
        for character in message {
            text.append(character)
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(450))
        await play(message: message, deliver: {
            try? await Task.sleep(for: .milliseconds(400))
            return .sent
        })
    }
}

// MARK: - Pieces

/// One piece of Liquid Glass in the shape of the moment — capsule, drop,
/// sphere, card. Before macOS 26, the thin material in its place.
struct GlassShape: View {
    let corner: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

/// The message, word by word.
private struct WordsIn: View {
    let text: String
    let shown: Int
    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        words.enumerated().reduce(Text("")) { line, item in
            line + Text(item.element + " ").foregroundColor(.primary.opacity(item.offset < shown ? 1 : 0))
        }
    }
}
