import AppKit
import Combine
import SwiftUI

/// What the setup assistant shows, kept current while it is open.
///
/// Every status is read from macOS rather than remembered: a permission
/// granted in System Settings while the assistant waits turns its row green
/// within a second, and one revoked there turns it back.
@MainActor
final class SetupModel: ObservableObject {
    @Published var step: SetupStep = .welcome
    @Published private(set) var plan: SetupPlan
    @Published private(set) var location: AppLocation
    @Published private(set) var accessibility: Access = AccessibilityAccess.status
    @Published private(set) var automation: [String: Access] = [:]
    @Published private(set) var hookInstalled = ClaudeHookInstaller.isInstalled()
    @Published private(set) var agents: [ProviderSnapshot] = []
    @Published private(set) var needs: [String: ConnectNeed] = [:]
    /// Every cloud agent spyx can read, switched on or not.
    @Published private(set) var catalog: [ProviderSummary] = []
    @Published private(set) var effortState = EffortState()
    @Published var moveProblem: String?
    /// Steps someone has been through, for the sidebar's ticks.
    @Published private(set) var visited: Set<SetupStep> = [.welcome]

    let preferences: Preferences
    let terminals: [AutomationTarget]
    let claudeCodeInstalled: Bool
    private weak var store: UsageStore?
    private let effort: () -> EffortController?
    private var cancellables: Set<AnyCancellable> = []
    private var poll: Timer?
    private var asking: Set<String> = []

    init(preferences: Preferences, store: UsageStore?, effort: @escaping () -> EffortController?) {
        self.preferences = preferences
        self.store = store
        self.effort = effort
        let location = AppLocation.current
        self.location = location
        self.terminals = AutomationTarget.installed()
        self.claudeCodeInstalled = FileManager.default.fileExists(atPath: ClaudeHookInstaller.settingsURL.deletingLastPathComponent().path)
        self.plan = SetupPlan(
            needsMove: location.needsMove,
            claudeDesktopInstalled: AutomationTarget.isInstalled(ClaudeDesktopComposer.bundleID)
        )

        guard let store else { return }
        store.$notchSnapshots
            .combineLatest(store.$needsRenewal, preferences.$disconnectedProviders)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots, _, _ in
                guard let self, let store = self.store else { return }
                self.agents = snapshots.filter { $0.localModel == nil && $0.localRuntime == nil }
                self.needs = store.connectNeeds()
                self.catalog = store.providerSummaries.filter {
                    $0.kind == .usage && $0.localModel == nil && !ClaudeProfile.isClaude(providerID: $0.id)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Lifetime

    func start() {
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        if let effort = effort() {
            effortState = effort.state
            effort.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.effortState = $0 }
                .store(in: &cancellables)
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
    }

    func refresh() {
        accessibility = AccessibilityAccess.status
        hookInstalled = ClaudeHookInstaller.isInstalled()
        let targets = terminals.filter { $0.needsPermission && !asking.contains($0.id) }
        Task.detached {
            let answers = targets.map { ($0.id, AutomationAccess.status(of: $0, ask: false)) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, access) in answers where !self.asking.contains(id) { self.automation[id] = access }
            }
        }
    }

    // MARK: Navigation

    func go(to step: SetupStep) {
        self.step = step
        visited.insert(step)
    }

    func advance() { plan.next(after: step).map(go(to:)) }
    func back() { plan.previous(before: step).map(go(to:)) }

    var isLast: Bool { plan.next(after: step) == nil }

    /// Done means nothing on that page is left to do — not merely visited.
    func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .welcome: return visited.contains(.welcome) && self.step != .welcome
        case .move: return !location.needsMove
        case .claude: return !claudeCodeInstalled || (hookInstalled && claudeNeeds.isEmpty)
        case .terminals:
            return terminals.filter(\.needsPermission).allSatisfy { automation[$0.id]?.isGranted == true }
        case .claudeDesktop:
            return !ClaudeDesktopComposer.isEnabled(.standard) || accessibility.isGranted
        case .agents: return !enabledAgents.isEmpty && enabledAgents.allSatisfy { needs[$0.id] == nil }
        case .ready: return false
        }
    }

    // MARK: Actions

    func moveToApplications() {
        moveProblem = nil
        do { try AppMover.moveToApplications() }
        catch { moveProblem = error.localizedDescription }
    }

    func requestAutomation(_ target: AutomationTarget) {
        if automation[target.id] == .denied {
            NSWorkspace.shared.open(AutomationAccess.settingsURL)
            return
        }
        asking.insert(target.id)
        Task {
            let access = await AutomationAccess.request(target)
            asking.remove(target.id)
            automation[target.id] = access
            // Launched only to be asked: put it back out of sight.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func isAsking(_ target: AutomationTarget) -> Bool { asking.contains(target.id) }

    func requestAccessibility() {
        UserDefaults.standard.set(true, forKey: ClaudeDesktopComposer.defaultsKey)
        AccessibilityAccess.request()
        objectWillChange.send()
    }

    var typesIntoClaudeDesktop: Bool {
        get { ClaudeDesktopComposer.isEnabled(.standard) }
        set {
            UserDefaults.standard.set(newValue, forKey: ClaudeDesktopComposer.defaultsKey)
            objectWillChange.send()
        }
    }

    func connect(_ providerID: String) {
        _ = store?.connect(providerID: providerID)
    }

    var claudeAgents: [ProviderSnapshot] { agents.filter { $0.id.hasPrefix("claude") } }
    var claudeNeeds: [String: ConnectNeed] { needs.filter { $0.key.hasPrefix("claude") } }

    var enabledAgents: [ProviderSummary] {
        catalog.filter { !preferences.disconnectedProviders.contains($0.id) }
    }

    /// Switched on first, then the ones whose app is on this Mac, then the rest.
    var sortedCatalog: [ProviderSummary] {
        func rank(_ agent: ProviderSummary) -> Int {
            if isEnabled(agent.id) { return 0 }
            return isFoundOnMac(agent) ? 1 : 2
        }
        return catalog.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    func isEnabled(_ id: String) -> Bool { !preferences.disconnectedProviders.contains(id) }

    /// Switching one on is what starts reading it — and, for one that needs
    /// signing in, what puts its Connect button here.
    func setEnabled(_ on: Bool, _ id: String) {
        if on { preferences.disconnectedProviders.remove(id) } else { preferences.disconnectedProviders.insert(id) }
    }

    func snapshot(for id: String) -> ProviderSnapshot? { agents.first { $0.id == id } }

    func isFoundOnMac(_ agent: ProviderSummary) -> Bool {
        if case .openApp(let bundleID, _) = agent.signIn { return AutomationTarget.isInstalled(bundleID) }
        return false
    }

    /// Supported terminals that aren't on this Mac, named once under the list.
    var otherTerminals: [String] {
        let here = Set(terminals.map(\.id))
        return AutomationTarget.all.filter { !here.contains($0.id) }.map(\.name)
    }
}

/// Puts the setup assistant on screen, and takes it down.
@MainActor
final class SetupAssistantController {
    /// Called once it is closed, however — Finish, or the red button.
    var onClose: (() -> Void)?
    /// Finish: the notch opens to show where it lives.
    var onFinish: (() -> Void)?

    private var window: NSWindow?
    private var model: SetupModel?
    private let preferences: Preferences
    private let store: () -> UsageStore?
    private let effort: () -> EffortController?
    private let openSettings: () -> Void

    init(preferences: Preferences, store: @escaping () -> UsageStore?,
         effort: @escaping () -> EffortController?, openSettings: @escaping () -> Void) {
        self.preferences = preferences
        self.store = store
        self.effort = effort
        self.openSettings = openSettings
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(at step: SetupStep? = nil) {
        if let window, let model {
            if let step { model.go(to: step) }
            surface(window)
            return
        }
        let model = SetupModel(preferences: preferences, store: store(), effort: effort)
        // Relaunched from Applications by the move: that page is behind them.
        if SetupGate.forcedByArguments, !model.location.needsMove, model.plan.steps.count > 1 {
            model.go(to: model.plan.steps[1])
        }
        if let step { model.go(to: step) }
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SetupAssistantView.width, height: SetupAssistantView.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("Set Up spyx")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: SetupAssistantView(
                model: model,
                finish: { [weak self] in self?.finish() },
                openSettings: { [weak self] in self?.openSettings() }
            )
            .tint(preferences.accentColor.color)
        )
        // Left to size the window, the hosting view makes its *content* rect
        // the page's size and adds the title bar on top.
        host.sizingOptions = []
        window.contentView = host
        // `fullSizeContentView` runs the content under the title bar, so the
        // frame *is* the content: without this it grew by the bar's height
        // and the page floated in a band of blank.
        window.setFrame(NSRect(x: 0, y: 0, width: SetupAssistantView.width, height: SetupAssistantView.height), display: false)
        window.center()
        window.delegate = closeWatcher
        self.window = window
        model.start()
        surface(window)
    }

    private func surface(_ window: NSWindow) {
        // An app with no Dock tile is not always allowed forward; without
        // this the assistant opens behind whatever the person was doing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func finish() {
        markSeen()
        window?.close()
        onFinish?()
    }

    /// Finish, or the red button — someone choosing to be done with it.
    /// Not the app quitting: that closes every window too, and a setup cut
    /// short by a quit or a relaunch should be there again next time.
    private func markSeen() {
        UserDefaults.standard.set(true, forKey: SetupGate.seenKey)
    }

    private func closed() {
        model?.stop()
        model = nil
        window?.delegate = nil
        window = nil
        onClose?()
    }

    private lazy var closeWatcher = SetupCloseWatcher(
        onCloseButton: { [weak self] in self?.markSeen() },
        onClose: { [weak self] in self?.closed() }
    )
}

private final class SetupCloseWatcher: NSObject, NSWindowDelegate {
    private let onCloseButton: () -> Void
    private let onClose: () -> Void

    init(onCloseButton: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onCloseButton = onCloseButton
        self.onClose = onClose
    }

    /// Asked for the red button and ⌘W only — never for `close()` or quitting.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { onCloseButton() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
