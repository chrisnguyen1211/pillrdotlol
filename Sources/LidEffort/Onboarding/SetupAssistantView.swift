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
                Button(L10n.t("Finish")) { finish() }
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
                    Text("spyx").font(.system(size: 13, weight: .semibold))
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
            case .claude: ClaudeBody(model: model)
            case .terminals: TerminalsBody(model: model)
            case .claudeDesktop: ClaudeDesktopBody(model: model)
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
        case .welcome, .move, .claudeDesktop: return .blue
        case .claude: return .orange
        case .terminals: return Color(white: 0.25)
        case .agents: return .purple
        case .ready: return .green
        }
    }

    private var summary: String {
        switch model.step {
        case .welcome:
            return L10n.t("Your coding agents' limits live in the notch, and the lid sets how hard they think. A minute of setup lets it do all of that without asking again.")
        case .move:
            return L10n.t("spyx is running from \(model.location.phrase). macOS forgets permissions given to a copy there, and won't open it at login.")
        case .claude:
            return L10n.t("Answer Claude Code's questions and approvals from the notch, and see how much of your plan is left.")
        case .terminals:
            return L10n.t("spyx talks to the terminal a session runs in — to take you to it, and to set the effort level live. macOS asks you once for each app.")
        case .claudeDesktop:
            return L10n.t("Claude Desktop has no terminal to type into. With Accessibility, spyx types /effort into its message box — only when it's in front, idle and empty.")
        case .agents:
            return L10n.t("Switch on the agents you use. spyx reads each one's usage with the login it already has on this Mac, and sends nothing anywhere but that agent's own servers.")
        case .ready:
            return L10n.t("spyx lives in the notch now. Try the gesture before you go.")
        }
    }
}

private struct WelcomeBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Feature(icon: "circle.dashed", tint: .blue,
                    title: L10n.t("Usage in the notch"),
                    detail: L10n.t("A ring per agent — Claude, Codex, Cursor and more — with the time until it resets."))
            Feature(icon: "laptopcomputer", tint: .orange,
                    title: L10n.t("⌘ + lid sets the effort"),
                    detail: L10n.t("Hold ⌘ and tilt the lid: open for more thinking, close for less. Every agent follows."))
            Feature(icon: "bubble.left.and.text.bubble.right.fill", tint: .green,
                    title: L10n.t("Answer Claude from the notch"),
                    detail: L10n.t("Questions and approvals appear under the session asking, wherever you are."))
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
                         detail: L10n.t("spyx copies itself there and reopens. Any older copy goes to the Trash.")) {
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

private struct ClaudeBody: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        if !model.claudeCodeInstalled {
            Hint(L10n.t("Claude Code isn't on this Mac yet. When you install it, both of these start working on their own."))
        }
        SetupCard {
            SetupRow(icon: "bubble.left.and.text.bubble.right", title: L10n.t("Answer from the notch"),
                     detail: model.hookInstalled
                        ? L10n.t("Hook installed in ~/.claude/settings.json")
                        : L10n.t("Adds one hook to ~/.claude/settings.json. Remove it any time by switching this off.")) {
                Toggle("", isOn: Binding(
                    get: { model.preferences.answerPromptsFromNotch },
                    set: { model.preferences.answerPromptsFromNotch = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Divider().padding(.leading, 44)
            if model.claudeAgents.isEmpty {
                SetupRow(icon: "key", title: L10n.t("Read your Claude usage"),
                         detail: L10n.t("Looking for Claude's login…")) { ProgressView().controlSize(.small) }
            }
            ForEach(model.claudeAgents) { agent in
                AgentRow(agent: agent, need: model.needs[agent.id], connect: { model.connect(agent.id) },
                         detailWhenConnected: L10n.t("Reading usage with Claude Code's login"))
            }
        }
        Hint(L10n.t("Claude's login is in your keychain. If macOS asks for your password, choose Always Allow so it doesn't ask again."))
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

private struct ClaudeDesktopBody: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        SetupCard {
            SetupRow(appIcon: ClaudeDesktopComposer.bundleID, title: L10n.t("Type /effort into Claude Desktop"),
                     detail: L10n.t("Experimental. Without it, Claude Desktop picks the level up next session.")) {
                Toggle("", isOn: Binding(get: { model.typesIntoClaudeDesktop }, set: { model.typesIntoClaudeDesktop = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if model.typesIntoClaudeDesktop {
                Divider().padding(.leading, 44)
                SetupRow(icon: "accessibility", title: L10n.t("Accessibility"),
                         detail: model.accessibility.isGranted
                            ? L10n.t("Allowed")
                            : L10n.t("In the list that opens, switch on spyx.")) {
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
        HStack(spacing: 4) {
            Hint(L10n.t("Claude is on the Claude Code page. Reorder agents in"))
            Button(L10n.t("Settings → Accounts")) { openSettings() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }
}

/// One agent: its switch, and — once on — whether it reads, or the one
/// thing to do about it.
private struct CatalogRow: View {
    let agent: ProviderSummary
    @ObservedObject var model: SetupModel

    var body: some View {
        let on = model.isEnabled(agent.id)
        HStack(spacing: 12) {
            ProviderGlyphView(glyph: agent.glyph, size: 18)
                .foregroundStyle(on ? .primary : .secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 13, weight: .medium))
                Text(detail(on: on)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if on { state }
            Toggle("", isOn: Binding(get: { on }, set: { model.setEnabled($0, agent.id) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var state: some View {
        if let need = model.needs[agent.id] {
            Button(need.buttonTitle) { model.connect(agent.id) }
        } else if let snapshot = model.snapshot(for: agent.id) {
            switch snapshot.status {
            case .ok, .stale: StatusPill(text: L10n.t("Connected"), color: .green)
            default: StatusPill(text: L10n.t("Can't read"), color: .gray)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func detail(on: Bool) -> String {
        guard on else {
            return model.isFoundOnMac(agent) ? L10n.t("Found on this Mac — switch on to read it") : L10n.t("Off")
        }
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
        SetupCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Keycap("⌘")
                    Text("+").foregroundStyle(.tertiary)
                    Image(systemName: "laptopcomputer").font(.system(size: 16))
                    Text(state.sensorAvailable
                         ? (state.armed ? L10n.t("Now move the lid…") : L10n.t("Hold ⌘ and tilt the lid"))
                         : L10n.t("No lid sensor on this Mac — set the level from the notch instead"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(state.armed ? Color.accentColor : .primary)
                    Spacer()
                    if let angle = state.angle {
                        Text("\(Int(angle.rounded()))°")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                LevelMeter(level: state.level, preview: state.preview)
            }
            .padding(14)
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

/// The five levels, the current one filled, and the lid's pull toward the
/// next while it moves.
private struct LevelMeter: View {
    let level: EffortLevel
    let preview: Double?

    var body: some View {
        let shown = preview.map { Int($0.rounded()) } ?? level.rawValue
        HStack(spacing: 6) {
            ForEach(EffortLevel.allCases, id: \.self) { candidate in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(candidate.rawValue <= shown ? Color.accentColor : Color.primary.opacity(0.1))
                        .frame(height: 6)
                    Text(candidate.description)
                        .font(.system(size: 11, weight: candidate.rawValue == shown ? .semibold : .regular))
                        .foregroundStyle(candidate.rawValue == shown ? .primary : .secondary)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown)
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

private struct AgentRow: View {
    let agent: ProviderSnapshot
    let need: ConnectNeed?
    let connect: () -> Void
    let detailWhenConnected: String

    var body: some View {
        HStack(spacing: 12) {
            ProviderGlyphView(glyph: agent.glyph, size: 18)
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let need {
                Button(need.buttonTitle, action: connect)
            } else if isReading {
                AccessPill(access: .granted, grantedText: L10n.t("Connected"))
            } else {
                StatusPill(text: L10n.t("Waiting"), color: .gray)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var isReading: Bool {
        switch agent.status {
        case .ok, .stale: return true
        default: return false
        }
    }

    private var detail: String {
        if let need { return need.reason }
        switch agent.status {
        case .ok, .stale: return detailWhenConnected
        case .unsupported(let why), .error(let why): return why
        default: return L10n.t("Not connected")
        }
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
