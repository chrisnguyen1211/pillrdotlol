import AppKit
import SwiftUI

/// What the notch asks a session to do, from its row or its card.
enum SessionAction {
    case reply(AgentSession)
    case stop(AgentSession)
    case handoff(AgentSession)
}

/// A small field under the notch for writing to one session: Enter sends,
/// Esc closes. A panel of its own rather than a field inside the notch,
/// which takes the keyboard only while a prompt is up — this one takes it
/// like Spotlight does, without making spyx the active app.
@MainActor
final class ReplyPanelController {
    static let shared = ReplyPanelController()

    private var panel: ReplyWindow?
    private let width: CGFloat = 460

    /// The notch the panel was opened from — set by whoever opens it — so
    /// it sits beside that tooltip on the side away from the pill's edge.
    var anchor: (rect: CGRect, screen: NSScreen, edge: NotchEdge)?

    /// The orb's stage has a clear margin round the field; counted in the
    /// gap, it sits as close to the pill as a card does.
    static let orbGap: CGFloat = -8

    /// A reply is being written: the notch it hangs from stays put.
    var isOpen: Bool { panel?.isVisible ?? false }

    func open(for session: AgentSession, demoText: String? = nil) {
        present(AnyView(OrbReplyView(session: session,
                                     reach: demoText == nil ? SessionCommander.reach(session) : .terminal(tty: "ttys000"),
                                     demoText: demoText,
                                     onStepAside: { [weak self] in self?.stepAside() },
                                     onReturn: { [weak self] key in self?.comeBack(takingKeyboard: key) },
                                     onClose: { [weak self] in self?.close() })),
                size: OrbReplyView.stage, glass: false)
    }

    /// Out of the way while a message goes into another app: off screen and
    /// no longer holding the keyboard — a panel that kept it took the ⌘V
    /// meant for the Claude app, and the message never left.
    func stepAside() {
        guard let panel else { return }
        panel.onResign = nil
        panel.resignKey()
        panel.orderOut(nil)
    }

    /// Back, to say how it went; with the keyboard only when there is
    /// something to fix.
    func comeBack(takingKeyboard: Bool) {
        guard let panel else { return }
        if takingKeyboard {
            panel.makeKeyAndOrderFront(nil)
            panel.onResign = { [weak self] in self?.close() }
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// The hand-off brief, editable, and a button per agent that can take it.
    func openHandoff(for session: AgentSession, demoBrief: String? = nil) {
        present(AnyView(HandoffView(session: session, brief: demoBrief ?? Handoff.brief(for: session),
                                    targets: demoBrief == nil ? Handoff.targets(for: session) : [.codex, .grok],
                                    demo: demoBrief != nil,
                                    onClose: { [weak self] in self?.close() })),
                size: HandoffView.stage, glass: false)
    }

    private func present(_ content: AnyView, size: CGSize, glass: Bool) {
        close()
        let window = ReplyWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        // The orb reply draws its own shapes and shadows on a clear stage.
        window.hasShadow = glass
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onResign = { [weak self] in self?.close() }

        // The hand-off panel is drawn for dark glass; the orb reply is Liquid
        // Glass and follows light and dark like the notch.
        if glass { window.appearance = NSAppearance(named: .darkAqua) }
        let effect = NSVisualEffectView()
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: glass ? AnyView(content.environment(\.colorScheme, .dark)) : content)
        if glass {
            host.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                host.topAnchor.constraint(equalTo: effect.topAnchor),
                host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            window.contentView = effect
        } else {
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            window.contentView = host
        }

        window.setFrameOrigin(Self.origin(size: size, anchor: anchor, pointer: NSEvent.mouseLocation,
                                          gap: glass ? 12 : Self.orbGap))
        window.makeKeyAndOrderFront(nil)
        panel = window
    }

    /// Beside what it was opened from, on the side away from the pill's edge
    /// — left of a tooltip on the right edge, right of one on the left,
    /// under one at the top — level with the pointer, which is on the row
    /// it is about; kept on screen. Without an anchor, under the menu bar.
    static func origin(size: CGSize, anchor: (rect: CGRect, screen: NSScreen, edge: NotchEdge)?,
                       pointer: CGPoint, gap: CGFloat = 12) -> CGPoint {
        let screen = anchor?.screen ?? NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, frame.minX + 8), frame.maxX - size.width - 8) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, frame.minY + 8), frame.maxY - size.height - 8) }
        guard let anchor else {
            return CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 24)
        }
        let rect = anchor.rect
        // Level with the pointer when it is on the tooltip — on the row the
        // panel is about — else with the tooltip's middle.
        let along = rect.minY...rect.maxY ~= pointer.y ? pointer.y : rect.midY
        let across = rect.minX...rect.maxX ~= pointer.x ? pointer.x : rect.midX
        switch anchor.edge {
        case .right: return CGPoint(x: clampX(rect.minX - size.width - gap), y: clampY(along - size.height / 2))
        case .left: return CGPoint(x: clampX(rect.maxX + gap), y: clampY(along - size.height / 2))
        case .top: return CGPoint(x: clampX(across - size.width / 2), y: clampY(rect.minY - size.height - gap))
        case .bottom: return CGPoint(x: clampX(across - size.width / 2), y: clampY(rect.maxY + gap))
        }
    }

    func close() {
        panel?.onResign = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

final class ReplyWindow: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// A round button the size of a line of text, for a session row's actions.
struct RowActionButton: View {
    let symbol: String
    let label: String
    var tint: Color = Palette.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.px(6)) {
                Image(systemName: symbol).font(.system(size: Design.px(18), weight: .semibold))
                Text(label).font(Typography.cardBody)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Design.px(14))
            .frame(height: NotchLayout.cardBodyLineHeight)
            .background(Capsule().fill(Palette.textPrimary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

struct HandoffView: View {
    let session: AgentSession
    @State var brief: String
    let targets: [Handoff.Agent]
    var demo = false
    let onClose: () -> Void
    @State private var demoNote: String?

    static let stage = CGSize(width: 500, height: 262)

    init(session: AgentSession, brief: String, targets: [Handoff.Agent], demo: Bool = false, onClose: @escaping () -> Void) {
        self.session = session
        self._brief = State(initialValue: brief)
        self.targets = targets
        self.demo = demo
        self.onClose = onClose
    }

    /// The same glass as the reply: one card, neutral ink, the brief in a
    /// well of its own, and a glass capsule per agent that can take it.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let glyph = ProviderGlyph.forSession(session) {
                    ProviderGlyphView(glyph: glyph, size: 16).foregroundStyle(.primary.opacity(0.8))
                }
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                Text(L10n.t("Hand off \(session.name)"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            TextEditor(text: $brief)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.06)))
                .frame(height: 112)
            HStack(spacing: 8) {
                Text(demoNote ?? (targets.isEmpty ? L10n.t("No other agent found on this Mac") : L10n.t("Start in a new Terminal window:")))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                ForEach(targets) { agent in
                    Button {
                        if demo {
                            demoNote = L10n.t("Demo — would open \(agent.displayName) in a new Terminal window")
                        } else if Handoff.launch(agent, brief: brief, for: session) {
                            onClose()
                        }
                    } label: {
                        Text(agent.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background { GlassShape(corner: 15) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background { GlassShape(corner: 22) }
        .padding(10)
        .frame(width: Self.stage.width, height: Self.stage.height)
        .onExitCommand(perform: onClose)
    }
}
