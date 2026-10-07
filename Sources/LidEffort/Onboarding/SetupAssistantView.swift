import AppKit
import LidEffortCore
import SwiftUI

/// The setup assistant: the steps down the side, one page at a time on the
/// right, and a footer that always says what Continue will do.
struct SetupAssistantView: View {
    static let width: CGFloat = 780
    static let height: CGFloat = 560

    @ObservedObject var model: SetupModel
    let finish: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(model: model)
                .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    SetupPage(model: model, openSettings: openSettings)
                        .padding(.horizontal, 36)
                        .padding(.top, 44)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(model.step)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 18)),
                            removal: .opacity
                        ))
                }
                Divider()
                // Clear of the window's rounded corners: concentric with
                // them rather than tucked into them.
                footer
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.width, height: Self.height)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.step)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.plan.previous(before: model.step) != nil {
                Button(L10n.t("Back")) { model.back() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            Spacer()
            let position = model.plan.position(of: model.step)
            Text(L10n.t("Step \(position.current) of \(position.total)"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            if model.isLast {
                Button(IntroGate.seen ? L10n.t("Finish") : L10n.t("Show Me Around")) { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                let skipping = model.step.isOptional && !model.isDone(model.step)
                Button(continueTitle(skipping: skipping)) { model.advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(skipping ? .secondary : nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func continueTitle(skipping: Bool) -> String {
        switch model.step {
        case .welcome: return L10n.t("Get Started")
        case .move where model.location.needsMove: return L10n.t("Not Now")
        default: return skipping ? L10n.t("Skip for Now") : L10n.t("Continue")
        }
    }
}

// MARK: - Sidebar

private struct SetupSidebar: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("pillr").font(.system(size: 13, weight: .semibold))
                    Text(L10n.t("Setup")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 48)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.plan.steps.enumerated()), id: \.element) { index, step in
                    Button { model.go(to: step) } label: {
                        row(step, number: index + 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            Spacer()
            Text(L10n.t("Everything here can be changed later in Settings."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VisualEffect(material: .sidebar))
    }

    private func row(_ step: SetupStep, number: Int) -> some View {
        let current = model.step == step
        let done = model.isDone(step)
        return HStack(spacing: 10) {
            ZStack {
                if done && !current {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.green)
                } else {
                    Circle()
                        .fill(current ? Color.accentColor : Color.clear)
                        .overlay(Circle().strokeBorder(current ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1))
                    Text("\(number)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(current ? Color.white : Color.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(step.shortTitle)
                .font(.system(size: 13, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(current ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Pages

private struct SetupPage: View {
    @ObservedObject var model: SetupModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            switch model.step {
            case .welcome: WelcomeBody()
            case .move: MoveBody(model: model)
            case .hooks: HooksBody(model: model)
            case .terminals: TerminalsBody(model: model)
            case .desktopApps: DesktopAppsBody(model: model)
            case .agents: AgentsBody(model: model, openSettings: openSettings)
            case .ready: ReadyBody(model: model, openSettings: openSettings)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.step == .welcome {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
            } else {
                SettingsBadge(systemName: model.step.icon, tint: tint, size: 52)
            }
            Text(model.step.title)
                .font(.system(size: 24, weight: .bold))
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tint: Color {
        switch model.step {
        case .welcome, .move, .desktopApps: return .blue
        case .hooks: return .orange
        case .terminals: return Color(white: 0.25)
        case .agents: return .purple
        case .ready: return .green
        }
    }

    private var summary: String {
        switch model.step {
        case .welcome:
            return L10n.t("Your coding agents' limits sit at the edge of your screen, and the lid sets how hard they think. A minute here means macOS won't interrupt you later.")
        case .move:
            return L10n.t("pillr is running from \(model.location.phrase). macOS forgets permissions given to a copy there, and won't open it at login.")
        case .hooks:
            return L10n.t("Each agent tells pillr the moment its turn ends, so the done card is never a guess. Where an agent can ask for approval through a hook, you answer it from the notch.")
        case .terminals:
            return L10n.t("pillr talks to the terminal a session runs in — to take you to it, and to set the effort level live. macOS asks you once for each app.")
        case .desktopApps:
            return L10n.t("An agent's desktop app has no terminal to type into. With Accessibility, pillr can reach the ones listed here; the rest pick the lid's level up next session.")
        case .agents:
            return L10n.t("Every agent you use, on one list. pillr reads each one's usage with the login it already has on this Mac, and sends nothing anywhere but that agent's own servers.")
        case .ready:
            return IntroGate.seen
                ? L10n.t("Here is what the lid will set for each agent. Everything here can be changed later in Settings.")
                : L10n.t("Here is what the lid will set for each agent. Next, a short tour shows where everything lives — skip it any time.")
        }
    }
}

private struct WelcomeBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Feature(icon: "circle.dashed", tint: .blue,
                    title: L10n.t("Usage in the notch"),
                    detail: L10n.t("A ring per agent you use — Claude Code, Codex, Grok, Cursor and more — with the time until it resets."))
            Feature(icon: "laptopcomputer", tint: .orange,
                    title: L10n.t("⌘ + lid sets the effort"),
                    detail: L10n.t("Hold ⌘ and tilt the lid: open for more thinking, close for less — for the agent you're working with."))
            Feature(icon: "bell.badge.fill", tint: .green,
                    title: L10n.t("Know when any agent is done"),
                    detail: L10n.t("Claude Code, Codex, Grok, Cursor: a card the moment a turn ends, with Reply beside it."))
        }
    }
}

private struct Feature: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MoveBody: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        SetupCard {
            if model.location.needsMove {
                SetupRow(icon: "folder", title: L10n.t("Applications folder"),
                         detail: L10n.t("pillr copies itself there and reopens. Any older copy goes to the Trash.")) {
                    Button(L10n.t("Move to Applications")) { model.moveToApplications() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                SetupRow(icon: "folder", title: L10n.t("Applications folder"),
                         detail: Bundle.main.bundlePath) {
                    AccessPill(access: .granted, grantedText: L10n.t("Installed"))
                }
            }
        }
        if let problem = model.moveProblem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }
}

private struct HooksBody: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        SetupCard {
            SetupRow(icon: "bell.badge", title: L10n.t("Tell me when an agent is done"),
                     detail: L10n.t("Adds pillr's own hook to each agent below. Nothing else in their configs is touched, and switching this off takes it out.")) {
                Toggle("", isOn: Binding(get: { model.preferences.announceSessionEnd },
                                         set: { model.preferences.announceSessionEnd = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if model.hookLinks.contains(where: { $0.present && $0.approvalsHooked != nil }) {
            Divider().padding(.leading, 44)
            SetupRow(icon: "checkmark.bubble", title: L10n.t("Answer approvals from the notch"),
                     detail: L10n.t("Questions and permission requests, answered without switching windows — for every agent whose hooks can hold one open.")) {
                Toggle("", isOn: Binding(get: { model.preferences.answerPromptsFromNotch },
                                         set: { model.preferences.answerPromptsFromNotch = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            }
        }
        if !HookConsent.locationAllows() {
            Hint(L10n.t("Hooks go in once pillr is in Applications — they point at where pillr lives, and a copy on the disk image disappears."))
        }
        let here = model.hookLinks.filter(\.present)
        let elsewhere = model.hookLinks.filter { !$0.present }.map(\.name)
        if !here.isEmpty {
            SetupCard {
                ForEach(Array(here.enumerated()), id: \.element.id) { index, link in
                    if index > 0 { Divider().padding(.leading, 50) }
                    HookLinkRow(link: link, done: model.preferences.announceSessionEnd,
                                approvals: model.preferences.answerPromptsFromNotch,
                                retry: { model.relinkHooks() })
                }
            }
        }
        if !elsewhere.isEmpty {
            Hint(L10n.t("Also linked when installed: \(elsewhere.joined(separator: ", ")). An agent installed later is hooked on its own the next time pillr starts."))
        }
    }
}

/// One agent: what it can tell pillr, and whether it is set up to.
private struct HookLinkRow: View {
    let link: AgentHooks.Link
    let done: Bool
    let approvals: Bool
    var retry: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let glyph = ProviderGlyph.forProvider(link.id) { ProviderGlyphView(glyph: glyph, size: 18) }
            }
            .foregroundStyle(link.present ? .primary : .tertiary)
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            pill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detail: String {
        guard link.present else { return L10n.t("Not on this Mac") }
        return link.approvalsHooked == nil
            ? L10n.t("Done card · no approval hook in this agent yet")
            : L10n.t("Done card · approvals")
    }

    @ViewBuilder private var pill: some View {
        if !link.present {
            StatusPill(text: L10n.t("Not installed"), color: .gray)
        } else if (link.doneHooked || !done) && (link.approvalsHooked != false || !approvals) {
            StatusPill(text: done ? L10n.t("Linked") : L10n.t("Off"), color: done ? .green : .gray)
        } else if HookConsent.locationAllows() {
            Button(L10n.t("Retry")) { retry() }
        } else {
            StatusPill(text: L10n.t("After the move"), color: .gray)
        }
    }
}

private struct TerminalsBody: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        let asking = model.terminals.filter(\.needsPermission)
        let free = model.terminals.filter { !$0.needsPermission }
        SectionTitle(L10n.t("Needs your OK"))
        SetupCard {
            ForEach(Array(asking.enumerated()), id: \.element.id) { index, target in
                if index > 0 { Divider().padding(.leading, 50) }
                SetupRow(appIcon: target.bundleID, title: target.name, detail: target.purpose) {
                    if model.isAsking(target) {
                        ProgressView().controlSize(.small)
                    } else {
                        AccessButton(access: model.automation[target.id] ?? .notAsked,
                                     ask: L10n.t("Allow…"), fix: L10n.t("Open Settings…")) {
                            model.requestAutomation(target)
                        }
                    }
                }
            }
        }
        if !free.isEmpty {
            SectionTitle(L10n.t("Works as is"))
            SetupCard {
                ForEach(Array(free.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { Divider().padding(.leading, 50) }
                    SetupRow(appIcon: target.bundleID, title: target.name, detail: target.purpose) {
                        StatusPill(text: L10n.t("Nothing to allow"), color: .green)
                    }
                }
            }
        }
        if !model.otherTerminals.isEmpty {
            Hint(L10n.t("Also supported when installed: \(model.otherTerminals.joined(separator: ", ")). Any other app still comes to the front when you click its session."))
        }
    }
}

private struct DesktopAppsBody: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        SetupCard {
            ForEach(Array(model.desktopApps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Divider().padding(.leading, 50) }
                SetupRow(appIcon: app.bundleID, title: app.name,
                         detail: app.reach ?? L10n.t("Can't be reached from outside yet — its sessions pick the lid's level up when they start.")) {
                    if app.reach != nil {
                        Toggle("", isOn: Binding(get: { model.typesIntoClaudeDesktop }, set: { model.typesIntoClaudeDesktop = $0 }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    } else {
                        StatusPill(text: L10n.t("Next session"), color: .gray)
                    }
                }
            }
            if model.desktopApps.contains(where: { $0.reach != nil }) && model.typesIntoClaudeDesktop {
                Divider().padding(.leading, 44)
                SetupRow(icon: "accessibility", title: L10n.t("Accessibility"),
                         detail: model.accessibility.isGranted
                            ? L10n.t("Allowed")
                            : L10n.t("In the list that opens, switch on pillr.")) {
                    AccessButton(access: model.accessibility,
                                 ask: L10n.t("Open Settings…"), fix: L10n.t("Open Settings…")) {
                        model.requestAccessibility()
                    }
                }
            }
        }
    }
}

private struct AgentsBody: View {
    @ObservedObject var model: SetupModel
    let openSettings: () -> Void

    var body: some View {
        SetupCard {
            if model.catalog.isEmpty {
                SetupRow(icon: "magnifyingglass", title: L10n.t("Looking for agents…"), detail: "") {
                    ProgressView().controlSize(.small)
                }
            }
            ForEach(Array(model.sortedCatalog.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { Divider().padding(.leading, 50) }
                CatalogRow(agent: agent, model: model)
            }
        }
        Hint(L10n.t("Some agents keep their login in your keychain. If macOS asks for your password, choose Always Allow so it doesn't ask again."))
        HStack(spacing: 4) {
            Hint(L10n.t("Reorder agents in"))
            Button(L10n.t("Settings → Accounts")) { openSettings() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }
}

/// One agent, and one button: Connect. Connected means read — one real
/// reading first, and only when it comes back is the agent switched on. One
/// that is not signed in says so and opens where it signs in, then keeps
/// looking for a few minutes, so the row turns Connected by itself.
private struct CatalogRow: View {
    let agent: ProviderSummary
    @ObservedObject var model: SetupModel
    @State private var phase: Phase = .idle
    @State private var watch: Task<Void, Never>?
    /// The install guide is open under the row.
    @State private var showingInstall = false
    @State private var copied = false

    /// How to install it, when it is not on this Mac and there is a way.
    private var missing: AgentInstall? {
        guard let guide = AgentInstall.guide(for: agent.id), !guide.isInstalled() else { return nil }
        return guide
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// Signing in somewhere else; looked at again every few seconds.
        case signingIn(String)
        case failed(String)
    }

    var body: some View {
        let on = model.isEnabled(agent.id)
        VStack(alignment: .leading, spacing: 10) {
            row(on: on)
            if showingInstall, let guide = missing {
                installGuide(guide)
                    .padding(.leading, 38)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.22), value: showingInstall)
        .onDisappear { watch?.cancel() }
    }

    private func row(on: Bool) -> some View {
        HStack(spacing: 12) {
            ProviderGlyphView(glyph: agent.glyph, size: 18)
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 13, weight: .medium))
                Text(detail(on: on))
                    .font(.system(size: 11))
                    .foregroundStyle(isProblem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing(on: on)
        }
    }

    /// The vendor's way in: its command to copy, its page to open, and a
    /// check for when it is done.
    private func installGuide(_ guide: AgentInstall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = guide.command {
                Text(L10n.t("Install it from Terminal:"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    Button(copied ? L10n.t("Copied") : L10n.t("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
            } else {
                Text(L10n.t("Download \(agent.name) from its website and open it once."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Link(guide.kind == .app ? L10n.t("Download \(agent.name)") : L10n.t("Install guide"), destination: guide.page)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 0)
                Button(L10n.t("I've installed it")) { installedNow() }
                    .controlSize(.small)
            }
        }
    }

    /// Back from installing: here now, so connect; still not, so say so.
    private func installedNow() {
        if missing == nil {
            showingInstall = false
            connect()
        } else {
            phase = .failed(L10n.t("\(agent.name) isn't on this Mac yet"))
        }
    }

    private var isProblem: Bool {
        if case .failed = phase { return true }
        return false
    }

    @ViewBuilder private func trailing(on: Bool) -> some View {
        switch phase {
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("Checking…")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button(L10n.t("Check again")) { connect() }.controlSize(.small)
            }
        case .failed where missing != nil:
            Button(L10n.t("Install…")) { phase = .idle; showingInstall = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .failed:
            HStack(spacing: 8) {
                if let need = failedNeed, need.action != .settings {
                    Button(need.buttonTitle) { startSignIn() }.controlSize(.small)
                }
                Button(L10n.t("Check again")) { connect() }.controlSize(.small)
            }
        case .idle:
            if on {
                if missing != nil {
                    Button(L10n.t("Install…")) { showingInstall.toggle() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if let need = model.needs[agent.id] {
                    Button(need.buttonTitle) { model.connect(agent.id) }.controlSize(.small)
                } else {
                    HStack(spacing: 8) {
                        StatusPill(text: L10n.t("Connected"), color: .green)
                        Button(L10n.t("Disconnect")) { model.setEnabled(false, agent.id) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            } else if missing != nil {
                Button(L10n.t("Install…")) { showingInstall.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button(L10n.t("Connect")) { connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    @State private var failedNeed: ConnectNeed?

    /// Read it once; on if it reads, otherwise the way in.
    private func connect() {
        watch?.cancel()
        phase = .checking
        Task { @MainActor in
            let status = await model.probe(agent.id)
            switch status {
            case .ok, .stale:
                model.setEnabled(true, agent.id)
                phase = .idle
            default:
                let need = model.need(for: status, agent: agent)
                failedNeed = need
                if case .error(let why) = status {
                    phase = .failed(L10n.t("Couldn't connect — \(why)"))
                } else if case .unsupported(let why) = status {
                    phase = .failed(why)
                } else {
                    phase = .failed(need?.reason ?? L10n.t("Not signed in"))
                }
            }
        }
    }

    /// Opens where it signs in, then looks again every few seconds for as
    /// long as signing in plausibly takes.
    private func startSignIn() {
        guard model.beginSignIn(agent.id) else { return }
        phase = .signingIn(L10n.t("Sign in, then come back — pillr is watching for it"))
        watch?.cancel()
        watch = Task { @MainActor in
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                let status = await model.probe(agent.id)
                if status == .ok || status.isStale {
                    model.setEnabled(true, agent.id)
                    phase = .idle
                    return
                }
            }
        }
    }

    private func detail(on: Bool) -> String {
        switch phase {
        case .checking: return L10n.t("Reading it once to check…")
        case .signingIn(let line): return line
        case .failed(let why): return why
        case .idle: break
        }
        guard on else {
            if missing != nil { return L10n.t("Not installed on this Mac — install it first") }
            return model.isFoundOnMac(agent) ? L10n.t("Found on this Mac") : L10n.t("Not set up on this Mac")
        }
        if missing != nil { return L10n.t("Not installed on this Mac — install it first") }
        if let need = model.needs[agent.id] { return need.reason }
        guard let snapshot = model.snapshot(for: agent.id) else { return L10n.t("Checking…") }
        switch snapshot.status {
        case .ok, .stale: return L10n.t("Reading usage")
        case .unsupported(let why), .error(let why): return why
        default: return L10n.t("Not signed in")
        }
    }
}

private struct ReadyBody: View {
    @ObservedObject var model: SetupModel
    let openSettings: () -> Void

    var body: some View {
        let state = model.effortState
        let offers = model.offers.filter { $0.installed && $0.enabled }
        if !offers.isEmpty {
            SectionTitle(L10n.t("What the lid sets"))
            SetupCard {
                ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                    if index > 0 { Divider().padding(.leading, 48) }
                    EffortOfferRow(offer: offer, level: state.level)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
        SetupCard {
            SetupRow(icon: "power", title: L10n.t("Open at login"),
                     detail: model.preferences.launchAtLoginProblem ?? L10n.t("So the notch is there whenever the Mac is.")) {
                Toggle("", isOn: Binding(get: { model.preferences.launchAtLogin },
                                         set: { model.preferences.launchAtLogin = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Divider().padding(.leading, 44)
            SetupRow(icon: "rectangle.inset.topright.filled", title: L10n.t("Find the notch"),
                     detail: L10n.t("On the \(model.preferences.notchEdge.title.lowercased()) edge of the screen. Hover it for sessions; drag it to move it.")) {
                Button(L10n.t("Settings…")) { openSettings() }
            }
        }
    }
}

// MARK: - Pieces

private struct SetupCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

private struct SetupRow<Trailing: View>: View {
    var icon: String? = nil
    var appIcon: String? = nil
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    init(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    init(appIcon bundleID: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) {
        self.appIcon = bundleID
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let appIcon, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appIcon) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: icon ?? "app").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct AccessButton: View {
    let access: Access
    let ask: String
    let fix: String
    let action: () -> Void

    var body: some View {
        switch access {
        case .granted:
            AccessPill(access: .granted)
        case .denied:
            HStack(spacing: 8) {
                AccessPill(access: .denied)
                Button(fix, action: action)
            }
        case .notAsked:
            Button(ask, action: action).buttonStyle(.borderedProminent)
        case .unknown(let why):
            HStack(spacing: 8) {
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
                Button(ask, action: action)
            }
        }
    }
}

private struct AccessPill: View {
    let access: Access
    var grantedText: String = L10n.t("Allowed")

    var body: some View {
        switch access {
        case .granted: StatusPill(text: grantedText, color: .green)
        case .denied: StatusPill(text: L10n.t("Turned off"), color: .red)
        case .notAsked: StatusPill(text: L10n.t("Not asked"), color: .gray)
        case .unknown(let why): StatusPill(text: why, color: .gray)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, -14)
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
    }
}

extension AppLocation {
    /// "the disk image" — completes "running from …".
    var phrase: String {
        switch self {
        case .applications: return L10n.t("Applications")
        case .diskImage: return L10n.t("the disk image")
        case .translocated: return L10n.t("a temporary copy macOS made of your download")
        case .elsewhere: return Bundle.main.bundleURL.deletingLastPathComponent().path
        }
    }
}
