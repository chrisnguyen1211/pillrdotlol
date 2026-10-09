import AppKit
import CoreTransferable
import SwiftUI
import Combine

/// A Liquid Glass background that falls back to a regular material on macOS
/// 15, where `glassEffect` does not exist. The visual difference is minor — the
/// sidebar gets a standard vibrancy material instead of the glass tint — and
/// the layout and interactions are unchanged.
extension View {
    @ViewBuilder
    func glassBackground(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            background {
                shape.fill(.regularMaterial)
            }
        }
    }
}

/// Real window vibrancy, which SwiftUI's own `Material` cannot give here.
///
/// A `Material` blends against what is *inside* the window; this blends
/// against what is behind it, which is the whole point — the desktop and
/// whatever is stacked under the panel show through it, and the sidebar and
/// the pane can take different materials so they read as two surfaces rather
/// than one flat fill.
/// The panel's glass. It covers the top bar too, which moves the window
/// only through its own empty stretch (see `SettingsHostingView`).
final class StillEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = StillEffectView()
        apply(to: view, context: context)
        // `.followsWindowActiveState` would drain the colour out of the panel
        // whenever focus went elsewhere, which for a settings window that is
        // read while another app is in front is most of the time.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: NSVisualEffectView, context: Context) {
        if context.environment.notchReduceTransparency {
            view.material = .windowBackground
            view.blendingMode = .withinWindow
        } else {
            view.material = material
            view.blendingMode = .behindWindow
        }
    }
}

/// The settings sheet, reached from the orb below the notch.
///
/// pillr's settings: the notch at the head of the window, drawn live, then a
/// row of tabs and the chosen pane under them — dark glass throughout, the
/// same material the notch is made of. What you change below, you see above.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let providers: () -> [ProviderSummary]
    /// Re-read whenever the sheet comes forward. Switching account happens in
    /// another app, so the user is always coming *back* here to see it — which
    /// makes returning focus the exact moment the old value is wrong.
    @State private var accounts: [ProviderSummary] = []
    @State private var displays: [DisplayOption] = []
    @State private var selection: SettingsSection = .lid
    /// What is typed in the sidebar's search field.
    @State private var query = ""
    /// The provider being dragged right now.
    ///
    /// Held here rather than read off the drop, because the rows have to move
    /// *during* the drag and `dropDestination` only hands over its payload once
    /// the pointer is released. See `DragState` for why it is a reference.
    @State private var drag = DragState()
    /// Bumped on every drop, purely to make the rows' cursor rects re-evaluate.
    ///
    /// A re-render per drop, which is a discrete action and cheap — unlike the
    /// per-drag state this replaced.
    @State private var cursorRefresh = 0
    /// What each provider on the notch needs before it can be read, from the
    /// store. Re-read on every notch publish: it looks only at snapshots, so it
    /// is cheap and never touches a credential.
    @State private var liveNeeds: [String: ConnectNeed] = [:]
    /// The providers the store has a notch cell for. Only for these is
    /// `liveNeeds` the whole truth — see `AccountRowState.need`.
    @State private var onNotch: Set<String> = []
    /// A provider the API tab should open its add form on — asked for by an
    /// Accounts row whose way in is a pasted key.
    @State private var apiAddRequest: String?
    @Namespace private var tabs
    /// Disconnecting has to reach the store's archive, not just the preference
    /// — see `UsageStore.signOut(providerID:)`.
    let signOut: (String) -> Void
    /// Reads a provider again after a key is saved, or takes the user to
    /// wherever that account is signed in. Returns false when there was
    /// nothing to open. Connect itself goes through the store's
    /// `beginConnect`, which may also run a sign-in command.
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    /// Re-reads a provider's credential. For a declined keychain prompt that is
    /// the whole remedy: asking again is what puts the prompt back on screen.
    let retry: (String) -> Void
    /// Put the notch back in the middle of its edge. A closure rather than a
    /// write to `preferences`, because the stored offset is not `@Published` —
    /// nothing would tell the notch to move, and the setting would only take
    /// effect the next time the edge changed.
    let resetPosition: () -> Void
    let quit: () -> Void
    @ObservedObject var updater: Updater
    var ollamaRelay: OllamaActivityRelay? = nil
    var lmstudioMetrics: LMStudioMetrics? = nil
    var usageStore: UsageStore? = nil
    var previewResetAlert: (() -> Void)? = nil
    var previewSessionLimitAlert: (() -> Void)? = nil
    var previewWeeklyLimitAlert: (() -> Void)? = nil
    /// The lid module, once it has started — it starts after this sheet is
    /// built, so it is asked for rather than handed over.
    var effort: () -> EffortController? = { nil }
    var openSetup: () -> Void = {}
    var openTour: () -> Void = {}
    /// The tab the window opens on; renders pick another.
    var startSection: SettingsSection = .lid
    @Environment(\.notchReduceTransparency) private var reduceTransparency
    /// How much of the dashboard shows at the head, kept between openings.
    /// Held as state, not `@AppStorage`, so a change made inside an
    /// animation slides rather than jumps: a defaults write comes back
    /// outside the animation's transaction.
    @State private var dashboardState = DashboardMode(rawValue: UserDefaults.standard.string(forKey: Self.dashboardModeKey) ?? "")
        ?? .folded
    static let dashboardModeKey = "dashboard.mode"
    private var dashboardMode: Binding<DashboardMode> {
        Binding(get: { dashboardState }, set: { new in
            dashboardState = new
            UserDefaults.standard.set(new.rawValue, forKey: Self.dashboardModeKey)
        })
    }
    private var dashboardExpanded: Bool { dashboardState == .expanded }

    var body: some View {
        VStack(spacing: 0) {
            // Kept above what follows, so nothing below can take its clicks.
            topBar
                .zIndex(1)
            DashboardPanel(preferences: preferences, mode: dashboardMode)
                .frame(height: dashboardExpanded ? nil
                       : (dashboardState == .hidden ? DashboardPanel.hiddenHeight : DashboardPanel.foldedHeight))
                .frame(maxHeight: dashboardExpanded ? .infinity : nil)
                .padding(.horizontal, 18)
                .padding(.bottom, dashboardExpanded ? 14 : 0)
            if !dashboardExpanded {
            VStack(spacing: 0) {
            tabBar
                .padding(.top, 8)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.top, 12)
            Group {
                if query.isEmpty {
                    paneContent(for: selection)
                } else {
                    searchResults
                }
            }
            // The pane sits straight on the window's glass; a `Form`'s own
            // backing would paint a second surface over it.
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Pushed down and out as the dashboard slides over, back up as
            // it folds.
            .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Typing a search is looking for a setting: the dashboard folds away.
        .onChange(of: query) { _, text in
            if !text.isEmpty, dashboardExpanded { withAnimation(DashboardPanel.motion) { dashboardMode.wrappedValue = .folded } }
        }
        // Rebuild the whole pane when the language changes.
        //
        // A segmented `Picker` draws its options through `ForEach`, which
        // identifies each row by its tag — the enum case. Switching language
        // changes only the title that row renders, not its identity, so the
        // rows compare equal, AppKit's segmented control is told nothing has
        // changed, and it keeps the segment labels it was first built with.
        // The result was a pane where every plain `Text` had switched back to
        // English and every picker was still in Chinese.
        //
        // Re-identifying here rather than on each picker: there are eleven of
        // them across four panes, and a twelfth added later would arrive with
        // the bug and no way to notice.
        .id(preferences.language)
        .tint(preferences.accentColor.color)
        .environment(\.notchAccentColor, preferences.accentColor.color)
        // Fills the window rather than claiming a fixed size. Under
        // `fullSizeContentView` the content view is the whole frame — title
        // bar included — so a view sized to `SettingsView.height` left the
        // title bar's worth of transparent window above it, with the traffic
        // lights floating in the hole.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // What actually draws the panel: the window itself is transparent
        // (see `SettingsWindowController.show()`), so this material is the
        // whole visible surface, and clipping it is what rounds all four
        // corners rather than only the two macOS rounds for a titled window.
        .background {
            if reduceTransparency {
                Color(white: preferences.interfaceMode == .dark ? 0.11 : 0.96)
            } else if preferences.interfaceMode == .dark {
                ZStack {
                    VisualEffect(material: .hudWindow)
                    LinearGradient(colors: [Color.black.opacity(0.25), Color.black.opacity(0.45)],
                                   startPoint: .top, endPoint: .bottom)
                }
            } else {
                ZStack {
                    VisualEffect(material: .underWindowBackground)
                    LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SettingsView.cornerRadius,
                                    style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsView.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(reduceTransparency ? 0.18 : 0.1), lineWidth: 1)
        }
        // Light or dark by the switch in the top bar, not by the Mac: the
        // window is the notch's material, and the two change together.
        .environment(\.colorScheme, preferences.interfaceMode.colorScheme)
        .background(WindowAppearance(appearance: preferences.interfaceMode.appearance))
        // Without this SwiftUI insets the content by the title bar's height
        // even though the window has none to speak of, and the panel's own
        // rounded top is pushed down leaving a transparent band with the
        // traffic lights stranded in it.
        .ignoresSafeArea()
        .onAppear {
            selection = startSection
            refreshVisibleState()
        }
        // Sent from outside the sheet — the API keys cell's menu.
        .onReceive(NotificationCenter.default.publisher(for: SettingsView.openSection)) { note in
            guard let raw = note.object as? String, let section = SettingsSection(rawValue: raw) else { return }
            query = ""
            selection = section
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in refreshVisibleState() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in displays = DisplayOption.connected }
        // An extra key added, renamed or removed: the store has rebuilt its
        // providers, and the rows were read from the old list.
        .onReceive((usageStore?.$providerListRevision.dropFirst().eraseToAnyPublisher()
                    ?? Empty<Int, Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { _ in refreshVisibleState() }
        .onReceive((usageStore?.$connectedCells.eraseToAnyPublisher()
                    ?? Empty<[ProviderSnapshot], Never>().eraseToAnyPublisher())
            .receive(on: RunLoop.main)) { _ in
                // The sheet stays open while models load and unload. Update
                // those rows without re-reading cloud credentials on each poll.
                guard let usageStore else { return }
                readNeeds(from: usageStore)
                let models = usageStore.localModelSummaries
                let updated = accounts.filter { $0.localModel == nil }.flatMap { account in
                    [account] + models.filter { $0.sourceProviderID == account.id }
                }
                accounts = ProviderOrder.arrange(updated, by: APIKeyGroup.groupedOrder(preferences.providerOrder),
                                                 id: \.id)
            }
    }

    /// The band the traffic lights sit in: the app's name after them, and
    /// search and quit at the far end.
    private var topBar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: SettingsView.trafficLightWidth, height: 1)
            Text(verbatim: "pillr")
                .font(.system(size: 13, weight: .semibold))
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ThemeChooser(choice: $preferences.appearanceChoice)
            SettingsSearchField(text: $query)
                .frame(width: 190)
            Button(action: quit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("Quit pillr"))
            .accessibilityLabel(L10n.t("Quit pillr"))
        }
        .padding(.horizontal, 14)
        .frame(height: SettingsView.headerHeight)
    }

    /// One word a pane, in a single capsule track; the chosen one's pill
    /// slides to it.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                let chosen = query.isEmpty && selection == section
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = section
                        query = ""
                    }
                } label: {
                    Text(section.tabTitle)
                        .font(.system(size: 12, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        // Nine tabs: ten points a side keeps Russian's
                        // longest labels on one line in the window's width.
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background {
                            if chosen {
                                Capsule()
                                    .fill(Color.primary.opacity(0.14))
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                                    .matchedGeometryEffect(id: "tab", in: tabs)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(section.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    /// Every setting whose name or meaning matches, with the pane it is in;
    /// choosing one opens that pane.
    private var searchResults: some View {
        let results = SettingsIndex.search(query)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if results.isEmpty {
                    Text(L10n.t("No results"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(results) { entry in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            selection = entry.section
                            query = ""
                        }
                    } label: {
                        HStack {
                            Text(entry.title)
                            Spacer(minLength: 12)
                            Text(entry.section.tabTitle)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    @ViewBuilder
    private func paneContent(for section: SettingsSection) -> some View {
        switch section {
        case .lid:           LidPane(effort: effort())
        case .notch:         NotchPane(preferences: preferences, displays: displays, resetPosition: resetPosition)
        case .sessions:      SessionsPane(preferences: preferences, showNotifications: { selection = .notifications })
        case .notifications:
            NotificationsPane(preferences: preferences,
                              previewResetAlert: previewResetAlert,
                              previewSessionLimitAlert: previewSessionLimitAlert,
                              previewWeeklyLimitAlert: previewWeeklyLimitAlert,
                              showAccounts: { selection = .accounts })
        case .accounts:      accountsPane
        case .api:
            APIKeysPane(preferences: preferences, usageStore: usageStore, addRequest: $apiAddRequest,
                        signOut: signOut, didAdd: { _ in keyAdded() })
        case .costs:         CostSettingsPane(preferences: preferences)
        case .localModels:
            LocalModelsPane(preferences: preferences, usageStore: usageStore,
                            ollamaRelay: ollamaRelay, lmstudioMetrics: lmstudioMetrics)
        case .general:       GeneralPane(preferences: preferences, updater: updater,
                                         openSetup: openSetup, openTour: openTour, quit: quit)
        }
    }

    private var accountsPane: some View {
        Form {
            Section { PaneHero(section: .accounts) }

            // Split in two, because ordering only means anything for the
            // first group: a provider switched off has no ring in the notch,
            // so dragging it was arranging something that is not on screen.
            Section(L10n.t("Connected")) {
                if needsSetup { setupNote }
                ForEach(connected) { account in
                    AccountRow(provider: account, preferences: preferences,
                               state: state(of: account),
                               signOut: signOut, signIn: signIn,
                               connect: beginConnect,
                               switchAccount: switchAccount, retry: retry,
                               refresh: { usageStore?.reevaluate(providerID: $0) },
                               isOrderable: true,
                               drag: drag,
                               cursorRefresh: cursorRefresh,
                               onDrop: { cursorRefresh += 1 },
                               takePlaceOf: { move($0, onto: account.id) },
                               didConnect: { connect(account.id) },
                               didChange: { accountsChanged() },
                               probe: { await usageStore?.probe(providerID: $0) ?? .ok },
                               openAPI: openAPI)
                }
                if connected.isEmpty {
                    Text(L10n.t("Nothing is connected, so the notch has no rings to draw."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !connected.isEmpty {
                    Text(L10n.t("The notch draws these in this order. Drag one by its handle to move it."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Beside the buttons it explains, not stranded at the end of
                // the page.
                Text(L10n.t("Most readings are borrowed from a tool that already holds the account. DeepSeek, MiniMax and QianwenAI are the exceptions: Connect opens a pillr window for that account, and Disconnect clears only that session and its saved reading."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Absent rather than empty when everything is on: a titled, empty
            // group reads as something having failed to load.
            if !notConnected.isEmpty {
                Section(L10n.t("Not connected")) {
                    ForEach(notConnected) { account in
                        AccountRow(provider: account, preferences: preferences,
                                   state: state(of: account),
                                   signOut: signOut, signIn: signIn,
                                   connect: beginConnect,
                                   switchAccount: switchAccount, retry: retry,
                                   refresh: { usageStore?.reevaluate(providerID: $0) },
                                   isOrderable: false,
                                   drag: drag,
                                   cursorRefresh: cursorRefresh,
                                   onDrop: {},
                                   takePlaceOf: { _ in false },
                                   didConnect: { connect(account.id) },
                               didChange: { accountsChanged() },
                               probe: { await usageStore?.probe(providerID: $0) ?? .ok },
                               openAPI: openAPI)
                    }
                    // Says what connecting one will do, which is the only
                    // question this group raises.
                    Text(L10n.t("These have no ring to place. Connect one and it joins the end of the list above."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(NotchFormStyle())
        // A row connected or disconnected jumps from one group to the other. Scoped to that
        // one value so nothing else on the page inherits an animation.
        .animation(.snappy(duration: 0.25), value: preferences.disconnectedProviders)
    }

    /// The API tab, with its add form open on this provider when there is
    /// one — where an Accounts row sends someone to paste a key.
    private func openAPI(_ providerID: String?) {
        withAnimation(.snappy(duration: 0.22)) {
            selection = .api
            query = ""
        }
        if let providerID { apiAddRequest = providerID }
    }

    private func refreshVisibleState() {
        accounts = Self.accountRows(providers(), order: preferences.providerOrder,
                                    isConnected: preferences.isConnected)
        displays = DisplayOption.connected
        if let usageStore { readNeeds(from: usageStore) }
    }

    private func readNeeds(from store: UsageStore) {
        liveNeeds = store.connectNeeds()
        onNotch = Set(store.connectedCells.map(\.id))
    }

    /// The Accounts list: every key folded into one API keys row, which
    /// takes its place in the order like any other.
    static func accountRows(_ summaries: [ProviderSummary], order: [String],
                            isConnected: (String) -> Bool = { _ in true }) -> [ProviderSummary] {
        ProviderOrder.arrange(APIKeyGroup.collapse(summaries: summaries, isConnected: isConnected, keepEmpty: true),
                              by: APIKeyGroup.groupedOrder(order), id: \.id)
    }

    /// A key was added under API. It joins the API keys row wherever that
    /// stands; the first key puts the row after the connected ones, and a
    /// row hidden from the notch comes back, since a key was just asked for.
    private func keyAdded() {
        let hasRow = accounts.contains { $0.id == APIKeyGroup.id }
        if !hasRow || !preferences.isConnected(APIKeyGroup.id) {
            preferences.setConnected(true, for: APIKeyGroup.id)
            if !hasRow { accounts.append(APIKeyGroup.summary()) }
            connect(APIKeyGroup.id)
        } else {
            accountsChanged()
        }
    }

    /// What this row's trailing control should offer.
    private func state(of account: ProviderSummary) -> AccountRowState {
        // Shown or hidden in the notch, like a local model: the keys are
        // switched on and off one by one under API.
        if account.id == APIKeyGroup.id { return .toggle }
        let isConnected = preferences.isConnected(account.id)
        let need = isConnected
            ? AccountRowState.need(live: liveNeeds[account.id], isOnNotch: onNotch.contains(account.id),
                                   summary: account,
                                   appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
            : nil
        return AccountRowState.resolve(isLocalModel: account.localModel != nil,
                                       isConnected: isConnected, need: need)
    }

    /// Connect, from a row's button: the store's own fix when the provider is
    /// already on the notch, otherwise whatever sign-in route it has. Without
    /// a store — a render — the plain sign-in closure stands in.
    private func beginConnect(_ providerID: String) -> Bool {
        guard let usageStore else { return signIn(providerID) }
        return usageStore.connect(providerID: providerID) || usageStore.beginConnect(providerID: providerID)
    }

    /// The slider's multiplier as a percentage, which is how people think
    /// about "a bit bigger" — 1.15 means nothing, 115% is immediate.
    static func scalePercent(_ scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    /// The band across the top of the panel that the traffic lights sit in.
    ///
    /// Everything at the top of the window is centred on it — the lights, the
    /// sidebar's toggle, and the pane's own title — so the three read as one
    /// row rather than as three things that happen to be near the top.
    /// `SettingsWindowController` positions the lights against this too.
    static let headerHeight: CGFloat = 52
    /// Asks an open sheet to show a tab; the object is its raw value.
    static let openSection = Notification.Name("lol.pillr.settings.openSection")

    /// How much room the three lights take across, for the one layout that
    /// has to start to the right of them: the collapsed pane's header.
    static let trafficLightWidth: CGFloat = 66

    /// The panel's corner rounding. All four corners, not the two macOS gives
    /// a titled window — the window is transparent and the content draws the
    /// shape.
    static let cornerRadius: CGFloat = 20

    /// The live notch at the head of the window.
    static let previewHeight: CGFloat = 180

    /// Wide enough for all seven tabs on one line and an account row's name,
    /// buttons and switch without crowding.
    static let width: CGFloat = 720
    /// The preview and the tabs, and under them a comfortable pane — each
    /// pane scrolls on its own.
    static let height: CGFloat = 740

    /// The rows the notch actually draws, in the order it draws them.
    ///
    /// Model switches control visibility; their shared runtime has its own
    /// connection row and must remain enabled for its models to appear.
    ///
    /// Every API key is in the one API keys row.
    private var ringAccounts: [ProviderSummary] {
        accounts.filter {
            ($0.kind == .usage && APICatalog.drawsRing(providerID: $0.id))
                || ($0.localModel != nil && preferences.isConnected($0.sourceProviderID ?? $0.id))
        }
    }

    private var connected: [ProviderSummary] {
        ringAccounts.filter { preferences.isConnected($0.id) }
    }

    private var notConnected: [ProviderSummary] {
        ringAccounts.filter { !preferences.isConnected($0.id) }
    }

    /// Nothing to read from anywhere. On a first launch that is the normal
    /// state, and it is the only moment the sheet has something to explain.
    private var needsSetup: Bool {
        guard !connected.contains(where: { $0.localModel != nil }) else { return false }
        let usageAccounts = accounts.filter { $0.kind == .usage }
        return !usageAccounts.isEmpty && usageAccounts.allSatisfy { $0.account == nil }
    }

    /// Names the tools rather than saying "tools already signed in on this
    /// Mac". Someone who uses Claude in a browser reads that sentence, installs
    /// this, sees four blank rings and concludes it is broken — and the
    /// distinction that catches them out is Claude *Code*, not the Claude app.
    static var setupCopy: String {
        L10n.t("pillr reads usage from tools already signed in on this Mac. It never asks for your password. Install and sign in to any of Claude Code (the terminal tool, not the Claude app), Cursor (the editor or cursor-agent), Codex, Antigravity, GLM, Grok, OpenCode, Command Code, GitHub Copilot, Kimi Code or a Gemini API key (via Gemini CLI, OpenCode or Hermes), and its ring appears in the notch.")
    }

    /// Said before it happens rather than after. A system dialogue asking to
    /// read a *credential*, from an app installed a minute ago, looks alarming
    /// unless it was expected — and choosing Allow instead of Always Allow makes
    /// it return on every read, which is what "it asks every time" turns out to
    /// be.
    static var keychainCopy: String {
        L10n.t("macOS will ask once for permission to read Claude Code's, Antigravity's and cursor-agent's saved logins. Choose Always Allow. Plain Allow makes it ask again every time.")
    }

    /// A provider has just been switched on: put it after the ones already
    /// connected.
    ///
    /// Done here rather than in `Preferences` because the full list of
    /// providers lives here — `providerOrder` is empty until someone drags
    /// something, and "the end of the connected ones" cannot be expressed
    /// against an order that does not exist yet.
    private func connect(_ providerID: String) {
        let ids = ProviderOrder.joiningConnected(providerID,
                                                 in: accounts.map(\.id),
                                                 isConnected: preferences.isConnected)
        accounts = ProviderOrder.arrange(accounts, by: ids, id: \.id)
        preferences.setProviderOrder(ids)
        accountsChanged()
    }

    /// One provider switched on or off, or given a key: its summary was built
    /// while it was in the other state (a disconnected one has no account),
    /// so the rows are read again once — on the click, not on every reading.
    private func accountsChanged() {
        DispatchQueue.main.async { refreshVisibleState() }
    }

    /// Put the dragged provider where the one under the pointer sits, while the
    /// drag is still in the air.
    ///
    /// Written through the preference on every crossing rather than batched
    /// until the drop: a drag released outside the window fires no drop at all,
    /// and a list left visibly reordered but unsaved would disagree with the
    /// notch until the window was next opened.
    ///
    /// Returns whether both ids are ours — anything dragged in from another app
    /// is a string too.
    @discardableResult
    private func move(_ movedID: String, onto targetID: String) -> Bool {
        guard let from = accounts.firstIndex(where: { $0.id == movedID }),
              let to = accounts.firstIndex(where: { $0.id == targetID })
        else { return false }
        guard from != to else { return true }

        var reordered = accounts
        reordered.insert(reordered.remove(at: from), at: to)
        accounts = reordered
        // Every row, connected or not — the order is a fact about the list, and
        // a provider switched off today still has a place to come back to.
        preferences.setProviderOrder(accounts.map(\.id))
        return true
    }

    private var setupNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("Connect an assistant to get started"))
                    .font(.callout.weight(.medium))
                Text(SettingsView.setupCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SettingsView.keychainCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            reduceTransparency ? .orange.opacity(0.18) : .orange.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
            }
        }
    }


}

/// A grab cursor AppKit can be forced to re-evaluate on the spot.
///
/// `.pointerStyle` rides the pointer-tracking system, which AppKit consults only
/// on a mouse move — so a drag ending with the pointer held still leaves an
/// arrow on the grip. `invalidateCursorRects(for:)` is the escape hatch the
/// pointer system lacks, and owning a cursor rect is what puts it within reach.
private struct GrabCursor: NSViewRepresentable {
    /// Bumped by the parent on each drop. Its only purpose is to make
    /// `updateNSView` run, which is where the rects are invalidated — the value
    /// itself is never read.
    let refreshToken: Int

    func makeNSView(context: Context) -> CursorRectView { CursorRectView() }

    func updateNSView(_ view: CursorRectView, context: Context) {
        // The pointer is sitting on a grip whose cursor AppKit reset to an arrow
        // when the drag ended, and it will not ask again on its own. This asks.
        view.window?.invalidateCursorRects(for: view)
    }

    /// A transparent view whose whole job is to declare "an open hand belongs
    /// here", so `resetCursorRects` — which AppKit calls on its own and on every
    /// `invalidateCursorRects` — has something to re-establish.
    final class CursorRectView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// What is being dragged, shared by every row without any of them observing it.
///
/// A class on purpose. As `@State`/`@Binding` this was SwiftUI state, so setting
/// it re-rendered every row twice per drag — once to start, once to finish — and
/// the second rebuild arrived after the drop and reset the pointer. A plain
/// reference is read the same way and changes nothing on screen.
@MainActor
final class DragState {
    var id: String?
}

/// A compact macOS-style colour choice. The outer ring makes pale colours and
/// the selected state visible against either appearance.
struct AccentColorSwatch: View {
    let choice: AccentColorChoice
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.notchReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: select) {
            ZStack {
                Circle()
                    .fill(choice.color)
                    .frame(width: 16, height: 16)
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(reduceTransparency ? 0.35 : 0.18), lineWidth: 1)
                    }

                Circle()
                    .strokeBorder(.primary, lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .opacity(isSelected ? 1 : 0)
            }
            // Exactly the selection ring, and no more. The frame was 24pt
            // around a 15pt dot, so every swatch carried 4.5pt of blank on
            // each side *before* the row's own spacing — which is what
            // spread eleven of them out across the pane.
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(choice.title)
        .accessibilityLabel(choice.title)
        .accessibilityValue(isSelected ? L10n.t("Selected") : L10n.t("Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One provider: whether pillr reads it, whose account that is, and where
/// to go if there is nothing to read.
/// One sound choice, with a preview button.
struct SoundRow: View {
    let label: String
    @Binding var name: String
    /// The preview stays live even with the sound switched off — it is how you
    /// find out what you are switching on, and a dead button teaches nothing.
    let pickerEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker(label, selection: $name) {
                // A sound that has been removed since it was chosen still has
                // to appear, or the picker would silently show a different one
                // and the setting would look like it had changed itself.
                if !SessionChime.available.contains(name) {
                    Text(L10n.t("\(name) (missing)")).tag(name)
                }
                ForEach(SessionChime.available, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityLabel(label)
            .disabled(!pickerEnabled)
            Button {
                Log.usage.info("preview \(name, privacy: .public)")
                SessionChime.play(name)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.t("Play \(name)"))
            .accessibilityLabel(L10n.t("Play \(name)"))
        }
    }
}

/// Where Settings' Connect has got to for one row.
private enum ConnectPhase: Equatable {
    case idle
    case checking
    case failed(String, ConnectNeed?)
}

private struct AccountRow: View {
    let provider: ProviderSummary
    @ObservedObject var preferences: Preferences
    /// Which control the row ends in — worked out by the list, which can see
    /// the store, from `AccountRowState`.
    let state: AccountRowState
    let signOut: (String) -> Void
    let signIn: (String) -> Bool
    /// Starts this provider's sign-in from a click: a Terminal command, its
    /// app, or pillr's own sign-in window. False when there was nothing to
    /// start, and the row's guidance or key field is the way in.
    let connect: (String) -> Bool
    let switchAccount: (String) -> Bool
    let retry: (String) -> Void
    let refresh: (String) -> Void
    /// Whether this row has a place in the notch to argue about. A provider
    /// switched off draws no ring, so there is nothing for a drag to arrange.
    let isOrderable: Bool
    /// The provider in flight, shared with every other row: this one has to
    /// know what is being dragged the moment the pointer arrives, not once it
    /// is released.
    let drag: DragState
    /// Changes on every drop; handed straight to `GrabCursor`, which uses the
    /// change itself rather than the value.
    let cursorRefresh: Int
    /// Tells the list a drop landed, so the cursor rects get re-evaluated while
    /// the pointer is still standing on the grip.
    let onDrop: () -> Void
    /// Move the dragged provider into this row's place. False when the id is
    /// not one of ours.
    let takePlaceOf: (String) -> Bool
    /// Called after this row is connected, so the list can decide where it
    /// now belongs. The row itself cannot: it can see only itself.
    let didConnect: () -> Void
    /// After a disconnect: the owner reads the rows again.
    var didChange: () -> Void = {}
    /// One real reading, now — what Connect waits for before calling the
    /// provider connected. See `UsageStore.probe`.
    var probe: (String) async -> ProviderStatus = { _ in .ok }
    /// Opens the API tab — on this provider's add form when given one. Keys
    /// are pasted there, not on the row.
    var openAPI: (String?) -> Void = { _ in }

    @Environment(\.notchReduceTransparency) private var reduceTransparency

    /// The extra key this row is, when it is one.
    private var extraKey: ExtraKey? {
        preferences.extraKeys.first { $0.id == provider.id }
    }

    /// The handle only appears under the pointer, so a row at rest stays as
    /// quiet as it was before there was anything to drag.
    @State private var isHovering = false
    /// Disconnecting a provider whose session pillr owns signs it out for real,
    /// so that one is asked first.
    @State private var confirmingDisconnect = false
    /// Where a Connect click has got to: checking the account for real, or
    /// why it could not be read.
    @State private var phase: ConnectPhase = .idle

    private var isConnected: Bool { preferences.isConnected(provider.id) }
    private var isMuted: Bool { preferences.isMutedAlerts(for: provider.id) }
    /// The one row every API key is folded into.
    private var isKeyGroup: Bool { provider.id == APIKeyGroup.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centred, not baseline-aligned. A glyph is a `Shape` and has no
            // text baseline, so `.firstTextBaseline` lines its *bottom edge* up
            // with the text's baseline and lifts every icon above its own name.
            // Everything on this row is a single line, so centring is what makes
            // the mark, the name, the button and the switch sit on one axis.
            HStack(alignment: .center, spacing: 10) {
                // Grip, mark and name are one grab area: a 12pt square is a
                // blank to hit, and none of the three do anything else. The
                // buttons and the switch stay out — a drag would compete.
                HStack(spacing: 10) {
                    if isOrderable { handle }

                    ProviderGlyphView(glyph: provider.glyph, customIconFilename: provider.customIconFilename, size: 16)
                        .foregroundStyle(isConnected ? .primary : .tertiary)

                    Text(provider.name)
                        .foregroundStyle(isConnected ? .primary : .secondary)
                }
                // Without this only the drawn pixels are grabbable, and the
                // gaps between the three of them are not.
                .contentShape(Rectangle())
                // `onDrag` rather than `draggable`, for its one advantage: it
                // runs a closure when the drag *starts*. Every other row needs
                // to know what is coming before it can make room for it, and
                // `dropDestination` does not hand over its payload until the
                // drop.
                .onDrag {
                    // A row with no ring has nothing to place. Handing back an
                    // empty provider is how `onDrag` declines a drag.
                    guard isOrderable else { return NSItemProvider() }
                    drag.id = provider.id
                    return NSItemProvider(object: provider.id as NSString)
                } preview: {
                    // The name alone, not the row: dragging the switch, the
                    // buttons and two lines of explanation across the window is
                    // a lot of translucent furniture to move a ring one place
                    // up.
                    HStack(spacing: 6) {
                        ProviderGlyphView(glyph: provider.glyph, customIconFilename: provider.customIconFilename, size: 12)
                        Text(provider.name)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .help(isOrderable
                      ? L10n.t("Drag to reorder. The notch draws the rings in this order.")
                      : provider.localModel != nil
                      ? L10n.t("Switch this on to give it a ring in the notch.")
                      : L10n.t("Connect this to give it a ring in the notch."))
                // Two mechanisms, neither of which covers both halves.
                // `pointerStyle` draws the hand on an ordinary hover but cannot
                // re-evaluate under a pointer that has not moved, which is the
                // state a finished drag leaves behind; the cursor rect exists
                // only so `invalidateCursorRects` can force that.
                //
                // It must sit *over* the content — behind it, SwiftUI's own
                // pointer regions win and the rect is never consulted at all —
                // and it must not take hits, or it swallows the drag.
                .pointerStyle(isOrderable ? .grabIdle : nil)
                .overlay {
                    if isOrderable {
                        GrabCursor(refreshToken: cursorRefresh)
                            .allowsHitTesting(false)
                    }
                }

                Spacer(minLength: 8)

                trailingControls
            }

            // 48 = the handle, the glyph and the two gaps before the name, so
            // the detail still starts under the first letter of the name.
            detail
                .font(.caption)
                .padding(.leading, 48)

            // A connected row whose new key was refused: said under the field,
            // since the row's own status still reads the old, working one.
            if isConnected, case .failed(let reason, _) = phase {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 48)
            } else if isConnected, phase == .checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("Checking the key…")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 48)
            }

            // Outside `detail` on purpose. That chain shows the account summary
            // whenever there is an account, and an aged-out token still has
            // one — the credential is there, it is simply too old to use. Put
            // inside, this warning would be swallowed by the very row that
            // makes everything look fine.
            if isConnected, provider.needsSignInRenewal {
                Text(provider.signInCommand.map { L10n.t("\(provider.name) usage needs its sign-in renewed. Run `\($0)` once in a terminal.") }
                     ?? L10n.t("\(provider.name) usage needs its sign-in renewed. Sign in to \(provider.name) again."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 48)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The whole row is the drop target, handle or not: a 12pt strip is a
        // hard thing to hit, and there is no ambiguity about which row the
        // pointer is over.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .confirmationDialog(L10n.t("Disconnect \(provider.name)?"), isPresented: $confirmingDisconnect) {
            Button(L10n.t("Disconnect"), role: .destructive) { disconnect() }
        } message: {
            Text(provider.signIn.signOutCaveat)
        }
        .dropDestination(for: String.self) { ids, _ in
            defer { drag.id = nil }
            guard isOrderable else { return false }
            // AppKit resets the cursor when a drag session ends and will not ask
            // what belongs here again until the mouse next moves — so releasing
            // the button and holding still left an arrow on a grip that was
            // perfectly grabbable. Setting a cursor by hand loses that race
            // whatever the timing, because the reset lands last; asking AppKit
            // to re-evaluate the rects does not race it at all.
            onDrop()
            // The list already settled on the way in. This only answers whether
            // what was released was ever ours.
            guard let moved = ids.first else { return false }
            return takePlaceOf(moved)
        } isTargeted: { entered in
            // The rearrangement happens here, not on the drop: the pointer
            // crossing into this row is the whole gesture, and the rows sliding
            // out of the way is what says where the ring will land.
            guard isOrderable, entered, let moved = drag.id, moved != provider.id
            else { return }
            withAnimation(.snappy(duration: 0.22)) { _ = takePlaceOf(moved) }
        }
    }

    /// The end of the row: one control for what the row can do next.
    ///
    /// It used to be a switch on every row, which read as "turn this on" when
    /// what most rows needed was "sign in" — and an agent switched on but not
    /// signed in looked exactly like one that worked. Now a row that is off
    /// offers Connect, one that is on says how it is doing and offers what
    /// would fix it, and Disconnect is a separate, deliberate button.
    @ViewBuilder
    private var trailingControls: some View {
        stateControls
    }

    @ViewBuilder
    private var stateControls: some View {
        switch state {
        case .toggle:
            Toggle(provider.name, isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(isKeyGroup
                      ? L10n.t("Show or hide the API keys cell in the notch. The keys are still read.")
                      : L10n.t("Show or hide this model in the notch. It stays loaded in \(provider.runtimeName ?? "Ollama")."))

        case .connect:
            switch phase {
            case .checking:
                ProgressView().controlSize(.small)
                Text(L10n.t("Checking…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason, let need):
                status(reason, color: .orange)
                // The way in, when the account is not signed in yet: then
                // Check again, once it is.
                if let need, need.offersButton {
                    Button(need.buttonTitle) { _ = connect(provider.id) }
                        .controlSize(.small)
                        .help(help(for: need))
                }
                if takesAPIKey {
                    Button(L10n.t("Add a key…")) { openAPI(provider.id) }
                        .controlSize(.small)
                }
                Button(L10n.t("Check again")) { verify() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .idle:
                Button(L10n.t("Connect")) { connectNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(L10n.t("Checks that \(provider.name) can be read, then gives it a ring."))
            }

        case .needs(let need):
            status(need.reason, color: .orange)
            alertsButton
            if need.offersButton {
                Button(need.buttonTitle) { fix(need) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(help(for: need))
            }
            // Not "Disconnect": it was never connected to anything.
            Button(L10n.t("Turn off")) { disconnect() }
                .controlSize(.small)
                .help(L10n.t("Stop trying to read \(provider.name). Connect it again any time."))

        case .reading:
            // Not "Connected": that is the section's own title, and in French
            // it is plural there.
            status(L10n.t("Signed in"), color: .green)
            alertsButton
            // Prefers the app that owns the account, and falls back to the
            // web page only when there is no app to open.
            //
            // The reading is borrowed from an app on this Mac, so that app
            // is where the account actually lives — and the website is a
            // different session entirely, which will bounce you to a login
            // if the browser is not signed in. Sending someone to a login
            // screen from a row that says "connected" is the wrong answer
            // whenever the real thing is one launch away.
            if let destination {
                Button(destination.title) { open(destination) }
                    .controlSize(.small)
                    .help(destination.help)
            }
            disconnectButton
        }
    }

    /// A dot and a word, so a row says whether it is being read without
    /// anyone having to work it out from the detail line.
    private func status(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// Per-provider threshold alerts, muted here rather than in a separate
    /// notifications pane — the thing being muted is this row's reading, so
    /// the control belongs on the row.
    @ViewBuilder
    private var alertsButton: some View {
        if provider.kind == .usage {
            Button {
                preferences.setAlertsMuted(!isMuted, for: provider.id)
            } label: {
                Image(systemName: isMuted ? "bell.slash" : "bell")
                    .font(.system(size: 11))
                    .foregroundStyle(isMuted ? .tertiary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isMuted
                  ? L10n.t("Alerts for \(provider.name) are muted. Click to unmute.")
                  : L10n.t("Alert when \(provider.name) crosses 80% and 100% of a limit."))
        }
    }

    /// Stops reading and forgets the readings — what switching off used to
    /// do. Asked first only where it also ends a session pillr owns; anywhere
    /// else the account is untouched and Connect brings it straight back.
    private var disconnectButton: some View {
        Button(L10n.t("Disconnect")) {
            if case .modal = provider.signIn {
                confirmingDisconnect = true
            } else {
                disconnect()
            }
        }
        .controlSize(.small)
        .help(L10n.t("Stop reading \(provider.name) and forget its readings. \(provider.signIn.signOutCaveat)"))
    }

    private func help(for need: ConnectNeed) -> String {
        switch need.action {
        case .terminal(let command):
            return L10n.t("Opens Terminal and runs `\(command)`.")
        case .allowAccess:
            // Not "it will stop asking": for Claude it will not. Claude Code
            // recreates its login when the token rotates, and a recreated
            // item forgets the grant.
            return L10n.t("Asks macOS for \(provider.name)'s saved login again. Always Allow means it is asked less often.")
        case .openApp, .settings:
            return provider.signIn.explanation
        }
    }

    /// The affordance only. The drag itself is on the whole group around it,
    /// because this is far too small a thing to have to hit.
    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            // Always drawn, only dimmer at rest. It used to be invisible until
            // hovered, and hover is exactly the state a drag leaves stale: the
            // reorder moves the row out from under a pointer that has not
            // itself moved, so no further hover event arrives and the grip
            // stayed gone until the pointer left the row and came back. Dimming
            // cannot fail that way — the worst a stale `isHovering` costs now
            // is a little emphasis.
            .opacity(isHovering ? 1 : (reduceTransparency ? 0.7 : 0.4))
            // Tall enough to be part of a real target rather than a 13pt strip
            // floating in the middle of the row.
            .frame(width: 12, height: 22)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            accountDetail
            
            // Antigravity limit dropdown
            if isConnected, provider.id == "gemini" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L10n.t("Notch reads"))
                            .foregroundStyle(.secondary)
                        Picker(L10n.t("Notch reads"), selection: $preferences.antigravityHeadlineLimit) {
                            ForEach(AntigravityHeadlineLimit.allCases) { limit in
                                Text(limit.title).tag(limit)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                    
                    HStack(spacing: 8) {
                        Text(L10n.t("Model data"))
                            .foregroundStyle(.secondary)
                        Picker(L10n.t("Model data"), selection: $preferences.antigravityHeadlineModel) {
                            ForEach(AntigravityHeadlineModel.allCases) { model in
                                Text(model.explanation).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
                .padding(.top, 2)
                .help(L10n.t("Choose which limit appears in the main notch for Antigravity."))
                .onChange(of: preferences.antigravityHeadlineLimit) { _ in
                    refresh(provider.id)
                }
                .onChange(of: preferences.antigravityHeadlineModel) { _ in
                    refresh(provider.id)
                }
            }

            // Google publishes no limit for a bare API key, so the ring has
            // nothing to fill against until the user names a ceiling itself.
            if isConnected, provider.id == "gemini-api" {
                // The field's own title would be drawn as a leading label
                // inside a `Form` row, which puts the caption hard against
                // the box and leaves the unit stranded past it. Hidden, so
                // the caption above can own the naming and the row can
                // breathe.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Monthly budget"))
                    HStack(spacing: 8) {
                        TextField(L10n.t("None"), value: $preferences.geminiAPIMonthlyTokenBudget,
                                  format: .number)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 130)
                        Text(L10n.t("tokens"))
                    }
                }
                .padding(.top, 2)
                .foregroundStyle(.secondary)
                .help(L10n.t("Fills the ring against a ceiling you choose; Google publishes none for an API key."))
            }
            // MiniMax is signed into in pillr. The region is which console
            // its session and keys belong to; a cookie header is optional.
            if provider.id == "minimax" {
                minimaxEntry
            }

            // A key pasted into pillr lives under API, with every other key.
            if takesAPIKey || extraKey != nil {
                apiKeyPointer
            }
        }
    }

    /// The API keys row: how many there are and how many are read, and the
    /// way to the tab where each is added, renamed or switched off.
    private var keyGroupDetail: some View {
        let keys = APIKeyItem.all(preferences: preferences, alsoListed: preferences.isConnected).map(\.id)
        let off = keys.filter { !preferences.isConnected($0) }.count
        let count = APIKeyGroup.countText(keys.count)
        return HStack(spacing: 6) {
            Text(!isConnected
                 ? L10n.t("Hidden from the notch · \(count)")
                 : keys.isEmpty ? L10n.t("No keys yet, add one under API")
                 : off == 0 ? L10n.t("\(count), shown together in one cell")
                 : L10n.t("\(count), \(off) switched off"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.t("Open API")) { openAPI(nil) }
                .buttonStyle(.link)
        }
    }

    /// Where this row's key is managed: under API. Says which, so a key
    /// pasted before the API tab existed is still easy to find.
    private var apiKeyPointer: some View {
        // A pasted base key is already listed there; anything else is one
        // still to add, and the button opens the form on this provider.
        let listed = extraKey != nil || BaseKeySlot.isPresent(provider.id)
        return HStack(spacing: 6) {
            Text(extraKey != nil
                 ? L10n.t("Rename or remove this key under API.")
                 : listed
                 ? L10n.t("The key you pasted is listed under API.")
                 : L10n.t("No tool on this Mac holds a key? Paste one under API."))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button(listed ? L10n.t("Open API") : L10n.t("Add a key…")) {
                openAPI(listed ? nil : provider.id)
            }
            .buttonStyle(.link)
        }
        .padding(.top, 2)
    }

    /// Region and Coding Plan key for MiniMax.
    ///
    /// Laid out like the Ollama key below, and for the same reason: a
    /// field's own title becomes a leading label in a `Form` row. Captions
    /// sit on their own line. Changing the region only stores the choice —
    /// opening Sign in here would throw a sheet over a preference picker.
    @State private var minimaxCookie = ""
    @State private var minimaxCookieSaved = false

    private var minimaxEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Region"))
                    .foregroundStyle(.secondary)
                Picker(selection: $preferences.minimaxRegion) {
                    Text(L10n.t("International")).tag(MiniMaxRegion.international)
                    Text(L10n.t("China mainland")).tag(MiniMaxRegion.china)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            minimaxCookieEntry

            Text(L10n.t("Sign in to MiniMax in pillr, or add a Coding Plan key under API. A Cookie header is optional. pillr never reads a browser's cookies."))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var minimaxCookieEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Cookie header (optional)"))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField(L10n.t("Cookie: …"), text: $minimaxCookie)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                Button(keyButtonTitle) {
                    guard !minimaxCookie.isEmpty else { return }
                    let cookie = minimaxCookie
                    minimaxCookie = ""
                    connectWithKey(store: { MiniMaxCredentials.storeCookieHeader(cookie) },
                                   remove: { MiniMaxCredentials.deleteCookieHeader() })
                }
                .disabled(minimaxCookie.isEmpty || phase == .checking)
                if minimaxCookieSaved {
                    Text(L10n.t("Saved"))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var accountDetail: some View {
        if isKeyGroup {
            keyGroupDetail
        } else if let model = provider.localModel {
            Text(isConnected ? L10n.t("\(model.memoryText) \(model.memoryLabel) · via \(provider.runtimeName ?? "Ollama")")
                 : L10n.t("Hidden from the notch · Loaded in \(provider.runtimeName ?? "Ollama")"))
                .foregroundStyle(.secondary)
        } else if !isConnected {
            Text(L10n.t("Not connected. Nothing is read, and no readings are kept."))
                .foregroundStyle(.tertiary)
        } else if let account = provider.account {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if canOpenSignIn {
                        Button(L10n.t("Switch…")) { _ = switchAccount(provider.id) }
                            .buttonStyle(.link)
                            .help(provider.signIn.switchHint)
                    }
                }
                // Says where the account actually lives, which is the whole
                // answer to "how do I change it" — not here.
                Text(provider.signIn.switchHint)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if provider.wasRefusedAccess {
            // Not a sign-in problem, so do not send them off to sign in. The
            // credential is right there and macOS is the one saying no — the
            // remedy is the Allow access… button on this same row.
            Text(L10n.t("macOS is not letting pillr read \(provider.name)'s saved login. Choose Allow access… above, then Always Allow."))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // What to do, in words. The button that does it — when there is
            // one — is the row's own, up beside the name.
            Text(provider.signIn.explanation)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where this row's "Open" button goes.
    enum Destination {
        case app(URL, name: String)
        case website(URL, host: String)

        var title: String {
            switch self {
            case .app(_, let name):     return L10n.t("Open \(name)")
            case .website(_, let host): return L10n.t("Open \(host)")
            }
        }

        var help: String {
            switch self {
            case .app(_, let name):
                return L10n.t("Opens \(name), which is where this account is signed in.")
            case .website(_, let host):
                return L10n.t("Opens \(host) in your browser. That site has its own sign-in, separate from the credential read here.")
            }
        }
    }

    /// The owning app when it is installed, the vendor's page otherwise.
    private var destination: Destination? {
        if case .openApp(let bundleID, let name) = provider.signIn,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return .app(app, name: name)
        }
        // Claude Code is a command with no app to open, so its row is always a
        // link — and claude.ai is genuinely where its usage can be checked.
        if let url = provider.account?.manageURL, let host = url.host {
            return .website(url, host: host)
        }
        return nil
    }

    private func open(_ destination: Destination) {
        switch destination {
        case .app(let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .website(let url, _):
            NSWorkspace.shared.open(url)
        }
    }

    /// Offering to open an app that isn't installed gives a button that does
    /// nothing — worse than no button.
    private var canOpenSignIn: Bool {
        switch provider.signIn {
        case .modal:
            return true
        case .openApp(let bundleID, _):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .guidance:
            return false
        }
    }

    /// The switch, for the one kind of row that keeps it: a local model, where
    /// on and off only show or hide it in the notch.
    private var binding: Binding<Bool> {
        Binding(
            get: { preferences.isConnected(provider.id) },
            set: { wantsOn in
                preferences.setConnected(wantsOn, for: provider.id)
                // After the switch, not before: where it belongs depends on
                // which providers are connected, and this one has only just
                // become one of them.
                if wantsOn { didConnect() }
            }
        )
    }

    /// Switch on, then start whatever sign-in the provider has.
    ///
    /// Switching on alone is enough for an account already signed in
    /// elsewhere — the next reading finds it. For one that is not, this opens
    /// the place it signs in there and then, which is the point of managing
    /// it from one place. With nothing to open, a provider that takes a
    /// pasted key gets its field focused instead.
    private func connectNow() { verify() }

    /// Connected means read: one real reading first, and only when it comes
    /// back good is the provider switched on. Otherwise the row says why —
    /// not signed in, a key refused, macOS said no — and offers the way in
    /// and Check again, instead of a ring that would only say "Not signed in".
    private func verify() {
        phase = .checking
        Task { @MainActor in
            let status = await probe(provider.id)
            switch status {
            case .ok, .stale:
                phase = .idle
                preferences.setConnected(true, for: provider.id)
                didConnect()
            default:
                let need = ConnectNeed.need(status: status, expired: false, route: provider.signIn,
                                            command: provider.signInCommand,
                                            appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
                phase = .failed(Self.reason(for: status, need: need, takesKey: takesAPIKey), need)
            }
        }
    }

    /// What a failed check says, in the row's one line.
    nonisolated static func reason(for status: ProviderStatus, need: ConnectNeed?, takesKey: Bool) -> String {
        switch status {
        case .needsAuth where takesKey: return L10n.t("No working key, add one under API")
        case .error(let why): return L10n.t("Couldn't connect: \(why)")
        case .unsupported(let why): return why
        default: return need?.reason ?? L10n.t("Not signed in")
        }
    }

    /// A key pasted in: kept only if it works. Stored, checked with a real
    /// reading, and taken out again when the account refuses it — a key
    /// that does not work is not left behind to fail on every poll.
    private func connectWithKey(store: () -> Void, remove: @escaping () -> Void) {
        store()
        phase = .checking
        Task { @MainActor in
            let status = await probe(provider.id)
            switch status {
            case .ok, .stale:
                phase = .idle
                if !isConnected {
                    preferences.setConnected(true, for: provider.id)
                    didConnect()
                } else {
                    refresh(provider.id)
                }
            default:
                remove()
                phase = .failed(status == .needsAuth || status == .accessDenied
                                    ? L10n.t("That key was not accepted")
                                    : Self.reason(for: status, need: nil, takesKey: true), nil)
            }
        }
    }

    /// What a key field's button says: Connect until it is, then Update.
    private var keyButtonTitle: String { isConnected ? L10n.t("Update") : L10n.t("Connect") }

    /// What the button on a connected row that cannot be read yet does.
    private func fix(_ need: ConnectNeed) {
        switch need.action {
        case .allowAccess:
            retry(provider.id)
        default:
            if !connect(provider.id), takesAPIKey { openAPI(provider.id) }
        }
    }

    /// A real sign-out for the readings: it forgets them as well as stopping
    /// the next one. For a session pillr owns it ends that session too.
    private func disconnect() {
        if provider.localModel == nil { signOut(provider.id) }
        preferences.setConnected(false, for: provider.id)
        didChange()
    }

    /// The providers whose way in can be a pasted key — added under API.
    private var takesAPIKey: Bool {
        ExtraKey.bases.contains(provider.id)
    }


}
