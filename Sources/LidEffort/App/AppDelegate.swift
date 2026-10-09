import AppKit
import LidEffortCore
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchFleet: NotchFleet?
    private var store: UsageStore?
    private var monitors: [String: any AgentActivityMonitor] = [:]
    /// The lid as an effort control — see `EffortController`.
    private var effort: EffortController?
    /// When to sound again for a prompt nobody has answered.
    private var promptReminder = PromptReminder(minutes: 0)
    /// Whether someone was at the Mac on the last prompt watch — to notice
    /// them coming back to questions that arrived while they were away.
    private var wasPresent = true
    /// How long a question waits in the notch, with the person there and in
    /// the session's app, before it is left to the session's own dialog.
    static let presentPatience: TimeInterval = 540
    private var ollamaRelay: OllamaActivityRelay?
    private var lmstudioMetrics: LMStudioMetrics?
    private var preferences: Preferences?
    private var settings: SettingsWindowController?
    private var whatsNew: WhatsNewWindowController?
    private var setup: SetupAssistantController?
    private var tour: IntroTour?
    /// Held for the life of the app: releasing it stops the scheduled checks.
    private var updater: Updater?
    private var thresholdNotifier: ThresholdNotifier?
    private var resetWatcher: UsageResetWatcher?
    private var limitWatcher: UsageLimitWatcher?
    private var statusItem: StatusItemController?
    /// Keeps the Claude keychain token from ageing out on a Mac where the CLI
    /// is never run by hand. See `ClaudeTokenRefresher`.
    private var tokenRefresher: ClaudeTokenRefresher?
    private var cancellables = Set<AnyCancellable>()
    /// Claude Code's prompts, handed over by the PermissionRequest hook.
    private var promptBroker: PromptBroker?
    /// Turns the monitors' running commentary into the one event worth
    /// interrupting for: an agent that has just stopped working.
    private var completions = SessionCompletionWatcher()
    /// Finishes held back until the session has stayed finished a while,
    /// by session id. A session woken again inside the window — a
    /// background command reporting back, the next step of a Grok turn —
    /// was not done, and its card is never shown.
    private var settling: [String: DispatchWorkItem] = [:]
    static let finishSettle: TimeInterval = 20
    /// Finishes said the moment Claude Code's Stop hook ran, by session id:
    /// the status file's own finish, a beat later, is the same one.
    private var saidByHook: [String: Date] = [:]
    /// The same, by agent: Codex's and Cursor's sessions in the notch are
    /// not named the way their hooks name them.
    private var saidByHookProvider: [String: Date] = [:]

    /// The unit bundle is hosted by this app, so `xcodebuild test` launches it
    /// for real. Without this guard every test run put a live request on the
    /// usage endpoint — which is both wrong on its own terms and, on an endpoint
    /// that rate-limits, actively harmful.
    private var isRunningTests: Bool { Runtime.isUnderTest }

    /// Quit any copy of pillr that was already running.
    ///
    /// Every notch is a window on the screen edge, so a second copy is not a
    /// harmless duplicate the way a second text editor is: it draws a second
    /// notch over the first, and a developer with a build in `DerivedData`, a
    /// staged release and `/Applications` could end up with the screen ringed
    /// by them. They are separate bundles at separate paths, so the system
    /// launches each as its own process rather than activating the one that is
    /// already up.
    ///
    /// The newcomer wins, deliberately. Quitting the *new* copy instead would
    /// be the wrong way round while developing: the whole point of launching a
    /// fresh build is to replace the one already running.
    ///
    /// Only strictly older instances are asked to go, which is what keeps two
    /// simultaneous launches from each terminating the other and leaving none.
    private static func retireOlderInstances() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let launched = NSRunningApplication.current.launchDate ?? Date()
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        where other.processIdentifier != mine && (other.launchDate ?? .distantPast) < launched {
            Log.usage.info("retiring an older instance (pid \(other.processIdentifier, privacy: .public))")
            if !other.terminate() { other.forceTerminate() }
        }
    }

    /// Every Claude Code configuration directory on this Mac — `~/.claude` and
    /// any `~/.claude-<slug>` — found once at launch. Each gets a usage
    /// provider and a session monitor of its own, keyed by the same id, so a
    /// work login's sessions spin the work ring and nobody else's.
    private let claudeProfiles = ClaudeProfile.discover()
    private let codexProfiles = CodexProfile.discover()
    /// Held as concrete providers, not just handed to the store: the token
    /// refresher needs to ask one of them how long its token has left, and the
    /// protocol has no business carrying that.
    private var claudeProviders: [ClaudeOAuthProvider] = []
    /// MiniMax Platform sign-in sheet. Not a UsageProvider — that is MiniMaxProvider.
    private var miniMaxWeb: WebSessionProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set here, not in the Info.plist: this call is applied at launch and
        // overrides `LSUIElement` either way. Removing the plist key alone left
        // the app registered as a UIElement with no Dock tile, which looked
        // exactly like the icon having failed to install. The user's choice
        // replaces this a moment later, once preferences exist.
        NSApp.setActivationPolicy(.regular)
        guard !isRunningTests else { return }
        Self.retireOlderInstances()

        // Before Preferences reads anything: the settings from before the
        // bundle id changed.
        Preferences.migrateFromPreviousDomain()
        let preferences = Preferences()
        self.preferences = preferences

        // One notch per display: the fleet owns a controller for each screen
        // the scope asks for and fans every reading out to all of them. The
        // stored edge goes in up front, before any panel is ever put up — the
        // sink below delivers on the next run loop turn, by which time the
        // notch would already have flashed on the default edge.
        let fleet = NotchFleet(scope: preferences.notchScope, edge: preferences.notchEdge)
        self.notchFleet = fleet

        // `PILLR_DEMO=1` puts the design frame's three providers on screen
        // with its numbers, for screenshots and for eyeballing the layout.
        if ProcessInfo.processInfo.environment["PILLR_DEMO"] == "1" {
            fleet.setSnapshots(Fixtures.snapshots())
        } else {
            // DeepSeek's Platform usage page is a browser-session provider:
            // login is explicit, stays in pillr's own WKWebView store, and
            // the page-local requests are refreshed only after that login.
            let deepSeek = WebSessionProvider(site: Sites.deepSeek)
            // QianwenAI's Token Plan is the same kind of provider: no usage API
            // to call, only a console, readable after the user signs in inside
            // this app's own WKWebView. Unlike MiniMax's sheet below, its ring
            // *is* this adapter, so it belongs in `webProviders` — exactly once.
            let qianwen = WebSessionProvider(site: Sites.qianwen)
            // MiniMax's ring is MiniMaxProvider. The sheet is the same kind of
            // WebView DeepSeek uses, but it must not join `webProviders`: two
            // adapters with id `minimax` would both poll, both draw a row, and
            // fight over the same archive key. Region is applied here and again
            // when Settings changes it, because the fetch URLs live on the site.
            let miniMaxWeb = WebSessionProvider(site: Sites.minimax(region: preferences.minimaxRegion))
            self.miniMaxWeb = miniMaxWeb
            let webProviders: [WebSessionProvider] = [deepSeek, qianwen]
            fleet.signInItems = ([deepSeek, miniMaxWeb, qianwen] as [WebSessionProvider]).map { provider in
                (title: L10n.t("Sign in to \(provider.displayName)…"),
                 action: { [weak provider] in provider?.presentSignIn() })
            }
            let customProviders: [UsageProvider] = preferences.customEndpoints
                .filter(\.isEnabled)
                .map { CustomEndpointProvider(endpoint: $0) }
            // A second (third…) key for GLM, MiniMax, Ollama or Apify, and any
            // catalog key — each read on its own, all drawn in the API keys
            // cell beside the providers' own rings. See `ExtraKey`.
            let extraKeyProviders = ExtraKeyProviders.makeAll(preferences.extraKeys)

            // Cursor reads the editor's session, or cursor-agent's if the
            // editor is missing — never a browser one: signing into
            // cursor.com separately created a second, empty account.
            //
            // Built *after* preferences and told what is switched off, so the
            // very first list it draws already excludes them. Constructed first,
            // it drew every provider from the archive and only dropped the
            // switched-off ones once the binding below delivered.
            Log.usage.info("claude profiles: \(self.claudeProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")
            Log.usage.info("codex profiles: \(self.codexProfiles.map(\.displayPath).joined(separator: ", "), privacy: .public)")
            let claudeProviders = claudeProfiles.map { ClaudeOAuthProvider(profile: $0) }
            self.claudeProviders = claudeProviders
            let store = UsageStore(
                providers: claudeProviders
                    + [CursorLocalProvider()]
                    + codexProfiles.map { CodexLocalProvider(profile: $0) }
                    + [AntigravityProvider(),
                       GLMProvider(), MiniMaxProvider(web: miniMaxWeb), GrokLocalProvider(), DevinLocalProvider(), OpenCodeProvider(),
                       CommandCodeProvider(), GitHubCopilotProvider(), KimiProvider(),
                       KiroProvider(), AmpProvider(), ApifyProvider(), KiloProvider(),
                       OllamaLocalProvider(endpoint: URL(string: preferences.ollamaEndpoint)!),
                       LMStudioLocalProvider(endpoint: URL(string: preferences.lmstudioEndpoint)!),
                       OllamaProvider(),
                       // A closure, not the value: the provider is an actor and
                       // re-reads the budget on every fetch, so a ceiling typed
                       // into Settings applies without a restart.
                       GeminiAPIProvider(budget: {
                           Preferences.storedGeminiAPIMonthlyTokenBudget()
                       })]
                    + extraKeyProviders
                    + webProviders
                    + customProviders,
                disconnected: preferences.disconnectedProviders,
                // Passed at construction, not left to the sink below, for the
                // same reason `disconnected` is: the sink delivers a run loop
                // turn later, so without this every launch draws the built-in
                // order for a frame and then visibly shuffles.
                order: preferences.providerOrder
            )
            deepSeek.onAuthenticated = { [weak store] in
                store?.refresh(providerID: "deepseek")
            }
            qianwen.onAuthenticated = { [weak store] in
                store?.refresh(providerID: "qianwenai")
            }
            miniMaxWeb.onAuthenticated = { [weak store] in
                store?.refresh(providerID: "minimax")
            }
            // Custom endpoints come and go while the app runs. Everything that
            // decides what an endpoint's provider reads goes into the key, so a
            // save that changes nothing it reads does not rebuild the rings.
            // The first value is the list the store was just built with.
            preferences.$customEndpoints
                .map { endpoints in
                    endpoints.filter(\.isEnabled).map {
                        "\($0.id):\($0.name):\($0.baseURL):\($0.apiType.rawValue):\($0.trackingUnit.rawValue):\($0.monthlyBudgetUSD ?? -1):\($0.currentSpendUSD ?? -1):\($0.monthlyBudgetTokensM ?? -1):\($0.currentTokensUsedM ?? -1):\($0.displayRemaining):\($0.showCurrency):\($0.iconPreset ?? ""):\($0.customIconFilename ?? ""):\($0.accentColorHex):\($0.selectedModel):\($0.usageSource.rawValue):\($0.usagePreset?.rawValue ?? ""):\($0.usageURL ?? ""):\($0.usageRecordsPath ?? ""):\($0.usageModelField ?? ""):\($0.usageTokenField ?? ""):\($0.usageModelFilter ?? ""):\($0.usageAuthentication.rawValue)"
                    }
                }
                .removeDuplicates()
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak store] _ in
                    let active = Preferences.storedCustomEndpoints().filter(\.isEnabled)
                    store?.registerCustomProviders(active.map { CustomEndpointProvider(endpoint: $0) })
                }
                .store(in: &cancellables)
            // Extra keys are added, renamed and removed from Settings while
            // the app runs. The first value is the list the store was just
            // built with.
            preferences.$extraKeys
                .removeDuplicates()
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak store] keys in
                    store?.registerExtraKeyProviders(ExtraKeyProviders.makeAll(keys))
                }
                .store(in: &cancellables)
            preferences.$minimaxRegion
                .dropFirst()
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak miniMaxWeb, weak store] region in
                    miniMaxWeb?.apply(site: Sites.minimax(region: region))
                    store?.refresh(providerID: "minimax")
                }
                .store(in: &cancellables)

            let updater = Updater()
            self.updater = updater
            updater.start()
            Diagnostics.shared.start()

            let relay = OllamaActivityRelay()
            self.ollamaRelay = relay
            // A single publisher chain exceeds Swift's type-checking time limit.
            let relayPreferences = Publishers.CombineLatest3(
                preferences.$disconnectedProviders,
                preferences.$ollamaEndpoint,
                preferences.$ollamaMetricsEnabled)
            let relayConfiguration = relayPreferences.map { values in
                (enabled: !values.0.contains("ollama-local") && values.2, endpoint: values.1)
            }.eraseToAnyPublisher()
            relayConfiguration
                .removeDuplicates { $0.enabled == $1.enabled && $0.endpoint == $1.endpoint }
                .receive(on: RunLoop.main)
                .sink { [weak relay, weak fleet] configuration in
                    fleet?.setLocalMetricsEnabled(configuration.enabled)
                    relay?.configure(enabled: configuration.enabled, endpoint: configuration.endpoint)
                }
                .store(in: &cancellables)
            relay.$thinkingModels
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] models in
                    let previous = fleet?.thinkingModels ?? [:]
                    fleet?.setThinkingModels(models)
                    if models.keys.contains(where: { previous[$0] == nil }) { store?.refresh(providerID: "ollama-local") }
                }
                .store(in: &cancellables)

            relay.$performances
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] measurements in
                    fleet?.setPerformances(measurements)
                    if !measurements.isEmpty { store?.refresh(providerID: "ollama-local") }
                }
                .store(in: &cancellables)

            // LM Studio needs no relay: its own socket says what each model is
            // doing and its own log says what every request cost. Monitoring
            // follows the provider's switch, and the address follows Settings.
            let lmstudio = LMStudioMetrics()
            self.lmstudioMetrics = lmstudio
            // Split like the relay's chain above, and for the same reason.
            let lmstudioPreferences = Publishers.CombineLatest(
                preferences.$disconnectedProviders, preferences.$lmstudioEndpoint)
            let lmstudioConfiguration = lmstudioPreferences.map { values in
                (enabled: !values.0.contains(LMStudioMetrics.providerID), endpoint: values.1)
            }.eraseToAnyPublisher()
            lmstudioConfiguration
                .removeDuplicates { $0.enabled == $1.enabled && $0.endpoint == $1.endpoint }
                .receive(on: RunLoop.main)
                .sink { [weak lmstudio] configuration in
                    lmstudio?.configure(enabled: configuration.enabled, endpoint: configuration.endpoint)
                }
                .store(in: &cancellables)
            lmstudio.$activities
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.setLocalActivities($0) }
                .store(in: &cancellables)
            lmstudio.$performances
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] measurements in
                    fleet?.setPerformances(measurements, source: LMStudioMetrics.providerID)
                    if !measurements.isEmpty { store?.refresh(providerID: LMStudioMetrics.providerID) }
                }
                .store(in: &cancellables)
            lmstudio.$ledger
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.setLedger($0) }
                .store(in: &cancellables)

            let settings = SettingsWindowController(
                preferences: preferences,
                // A closure so the sheet re-reads accounts each time it comes
                // forward; a snapshot here is what made a switched account keep
                // showing the old address until the app restarted.
                providers: { [weak store] in store?.providerSummaries ?? [] },
                updater: updater,
                signOut: { [weak store] in store?.signOut(providerID: $0) },
                signIn: { [weak store] in store?.signIn(providerID: $0) ?? false },
                switchAccount: { [weak store] in
                    store?.openAccountSource(providerID: $0, switching: true) ?? false
                },
                retry: { [weak store] in store?.reauthorize(providerID: $0) },
                // Both halves, because the stored nudge and the live one are
                // kept apart on purpose — clearing only the preference would
                // leave the notch where it is until the next edge change, and
                // moving only the panel would put it back on relaunch.
                resetPosition: { [weak fleet, weak preferences] in
                    preferences?.setOffset(0, for: preferences?.notchEdge ?? .right)
                    fleet?.apply(alongOffset: 0)
                },
                quit: { NSApp.terminate(nil) },
                previewResetAlert: { [weak self] in
                    self?.previewUsageResetAlert()
                },
                previewSessionLimitAlert: { [weak self] in
                    self?.previewSessionLimitAlert()
                },
                previewWeeklyLimitAlert: { [weak self] in
                    self?.previewWeeklyLimitAlert()
                },
                usageStore: store, ollamaRelay: relay, lmstudioMetrics: lmstudio
            )
            settings.effort = { [weak self] in self?.effort }
            // The gear toggles; everything else that opens settings opens it.
            fleet.onOpenSettings = { [weak settings] in settings?.toggle() }
            // A session row answers where it runs by taking you there.
            // The Connect button in a tooltip: open the app, run the sign-in
            // command, or ask macOS again — and Settings when none applies.
            fleet.onConnect = { [weak store, weak settings] id in
                if store?.connect(providerID: id) != true { settings?.show() }
            }
            fleet.onSessionAction = { [weak fleet] action in
                // The tooltip folds away; the field takes its place by the pill.
                if case .stop = action {} else { ReplyPanelController.shared.anchor = fleet?.foldForReply() }
                switch action {
                case .reply(let session):
                    ReplyPanelController.shared.open(for: session)
                case .stop(let session):
                    Task { @MainActor in _ = await SessionCommander.stop(session) }
                case .handoff(let session):
                    ReplyPanelController.shared.openHandoff(for: session)
                }
            }
            Handoff.warmUp()
            let recap = DailyRecapScheduler { [weak fleet] recap in
                let top = recap.agents.max { ($0.toolCalls, $0.sessions) < ($1.toolCalls, $1.sessions) }
                let glyph: ProviderGlyph = ["Claude Code": .claude, "Codex": .openai, "Grok": .grok][top?.name ?? ""] ?? .third
                var event = UsageAlertEvent(kind: .recap, providerID: "recap", providerName: "", windowLabel: "",
                                            glyph: glyph, previousFraction: 0, currentFraction: 0, resetsAt: nil)
                event.recap = recap
                fleet?.showResetAlert(event, duration: 12)
            }
            recap.start()
            self.recapScheduler = recap
            startCoach()
            fleet.onFocusSession = { [weak self] pid in
                // The tour's demo sessions have no window; it answers for them.
                if self?.tour?.handleSessionClick(pid) == true { return }
                Task { _ = await SessionFocus.focus(pid: pid) }
            }
            self.settings = settings

            // What changed, once per version — including on a fresh install,
            // where it is the introduction.
            let whatsNew = WhatsNewWindowController(
                preferences: preferences, version: updater.currentVersion
            )
            self.whatsNew = whatsNew

            // An agent app has no dock icon and no window: installed and
            // launched, it shows four empty rings on a screen edge and no
            // reason to look at them. Once, on the very first run, it opens the
            // one place that explains what to connect.
            //
            // Sequenced behind What's New rather than beside it: two windows
            // arriving together is one to dismiss before you can read either.
            // The setup assistant is the introduction now: it walks through
            // every permission the notch needs, once per Mac, and stays in
            // Settings and the menu bar for later. On a fresh install it
            // stands in for What's New, which would only repeat it; for
            // someone updating into it, What's New follows once it closes.
            let setup = SetupAssistantController(
                preferences: preferences,
                store: { [weak store] in store },
                effort: { [weak self] in self?.effort },
                openSettings: { [weak settings] in settings?.show() }
            )
            // Shown round first, then set up: the intro says what pillr is,
            // so the setup that follows — permissions, hooks — has a reason
            // behind every question. A tour skipped or finished leads into
            // setup; setup's Finish only tours someone who has not seen it.
            let tour = IntroTour(fleet: fleet, preferences: preferences, effort: { [weak self] in self?.effort })
            self.tour = tour
            setup.onFinish = { [weak tour] in
                guard !IntroGate.seen else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tour?.start() }
            }
            self.setup = setup
            settings.openSetup = { [weak setup] in setup?.show() }
            settings.openTour = { [weak tour, weak settings] in
                settings?.close()
                tour?.start()
            }
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "--tour-at"), arguments.indices.contains(flag + 1),
               let step = IntroTour.Step.allCases.first(where: { String(describing: $0) == arguments[flag + 1] }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak tour] in tour?.start(at: step) }
            } else if arguments.contains("--tour") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak tour] in tour?.start() }
            } else if arguments.contains("--demo"), let fleet = notchFleet {
                let demo = FeatureDemo(fleet: fleet)
                self.featureDemo = demo
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { demo.start() }
            }
            let seen = UserDefaults.standard.bool(forKey: SetupGate.seenKey)
            if SetupGate.shouldShow(seen: seen, forced: SetupGate.forcedByArguments) {
                if preferences.isFirstLaunch {
                    preferences.lastSeenVersion = updater.currentVersion
                } else {
                    setup.onClose = { [weak whatsNew, weak setup] in
                        setup?.onClose = nil
                        whatsNew?.showIfNeeded()
                    }
                }
                // Intro first, unless pillr must first be moved into
                // Applications: that page comes before anything, and the
                // copy that reopens from there plays the intro.
                if !IntroGate.seen, !AppLocation.current.needsMove {
                    tour.leadsIntoSetup = true
                    tour.onEnd = { [weak tour, weak setup] in
                        IntroGate.markSeen()
                        tour?.leadsIntoSetup = false
                        tour?.onEnd = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { setup?.show() }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak tour] in tour?.start() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak setup] in setup?.show() }
                }
            } else {
                whatsNew.showIfNeeded()
            }

            let statusItem = StatusItemController { [weak settings] in settings?.show() }
            statusItem.onOpenSetup = { [weak setup] in setup?.show() }
            statusItem.onTakeTour = { [weak tour] in tour?.start() }
            statusItem.onCheckForUpdates = { [weak self] in self?.updater?.checkNow() }
            statusItem.onRestartToUpdate = { [weak self] in self?.updater?.restartToUpdate() }
            statusItem.readyUpdate = { [weak self] in
                if case .ready(let version) = self?.updater?.outcome { return version }
                return nil
            }
            self.statusItem = statusItem
            statusItem.onRefreshProvider = { [weak store] id in store?.refresh(providerID: id) }
            statusItem.onRefreshAll = { [weak store] in store?.refreshNow() }
            // Read when the menu opens, so a model's line is as current as its cell.
            statusItem.cells = { [weak fleet] in fleet?.menuModel.snapshots ?? [] }
            statusItem.activity = { [weak fleet] in fleet?.menuModel.activity(for: $0) }

            preferences.$appPresence
                .receive(on: RunLoop.main)
                .sink { presence in
                    NSApp.setActivationPolicy(presence.activationPolicy)
                    if presence.wantsStatusItem { statusItem.show() } else { statusItem.hide() }
                }
                .store(in: &cancellables)

            preferences.$notchVisibility
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply($0) }
                .store(in: &cancellables)

            preferences.$notchEdge
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak preferences] edge in
                    // Read before `apply(edge:)` moves the panel, so the new
                    // edge's own remembered nudge is what it lands at rather
                    // than the old edge's carried over onto it.
                    fleet?.apply(alongOffset: preferences?.offset(for: edge) ?? 0)
                    fleet?.apply(edge: edge)
                }
                .store(in: &cancellables)

            // Three inputs, one answer: which control is in charge, and the
            // value each of them holds. Any of them changing has to re-ask
            // `notchScale` rather than trust the value it was handed, since
            // the preset and the slider each keep their own.
            //
            // `dropFirst` on each, because `@Published` publishes the value it
            // is given at init — without it every launch would open the notch
            // three times over before anyone had touched anything.
            Publishers.MergeMany(
                preferences.$notchSize.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                preferences.$usesCustomNotchScale.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                preferences.$customNotchScale.dropFirst().map { _ in () }.eraseToAnyPublisher()
            )
            // `DispatchQueue.main`, not `RunLoop.main`, and this is the one
            // subscription where the difference is visible. Combine's RunLoop
            // scheduler delivers in `.default` mode, which AppKit starves for
            // as long as a drag is in progress — the loop is in
            // `NSEventTrackingRunLoopMode` the whole time a slider is held. So
            // the notch sat unchanged until the mouse came up, then jumped.
            // Every `Timer` here is registered `forMode: .common` against the
            // same hazard; the scheduler offers no way to say that, and the
            // dispatch queue is not bound to run loop modes at all.
            .receive(on: DispatchQueue.main)
            .sink { [weak fleet, weak preferences] in
                guard let preferences, let fleet else { return }
                fleet.apply(scale: preferences.notchScale)
                // Resizing something you cannot see is guesswork. On the
                // hover setting the notch is folded away for as long as the
                // pointer is in Settings, which is exactly when the size is
                // being chosen — so it is opened for a moment to show what
                // just changed. Dragging the slider keeps re-arming this, so
                // it simply stays open until the drag stops. `peek` still
                // declines outright when the notch is set to Hide.
                fleet.peek(for: 1.2, focusing: nil)
            }
            .store(in: &cancellables)

            preferences.$notchScope
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(scope: $0) }
                .store(in: &cancellables)

            preferences.$displayPreference
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(displayPreference: $0) }
                .store(in: &cancellables)

            fleet.onReposition = { [weak preferences] offset in
                preferences?.setOffset(offset, for: preferences?.notchEdge ?? .right)
            }
            
            fleet.onToggleKeepOpen = { [weak preferences] in
                guard let prefs = preferences else { return }
                prefs.notchVisibility = (prefs.notchVisibility == .alwaysShow) ? .onHover : .alwaysShow
            }

            // Writing the preference is the whole of it: `notchEdge` is
            // `@Published` and the fleet already follows it, so the notch
            // relocates by the same path the Settings picker uses.
            fleet.onMoveToEdge = { [weak preferences] edge in
                preferences?.notchEdge = edge
            }

            preferences.$resetTimeFormat
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(resetTimeFormat: $0) }
                .store(in: &cancellables)

            preferences.$accentColor
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(accentColor: $0) }
                .store(in: &cancellables)

            preferences.$weeklyRing
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(weeklyRing: $0) }
                .store(in: &cancellables)

            preferences.$showsMoveHandle
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(showsMoveHandle: $0) }
                .store(in: &cancellables)
                
            preferences.$notchSurfaceStyle
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(surfaceStyle: $0) }
                .store(in: &cancellables)

            preferences.$interfaceMode
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(interfaceMode: $0) }
                .store(in: &cancellables)

            Publishers.CombineLatest(preferences.$tooltipSessionLimit, preferences.$hideIdleSessionsAfterHours)
                .receive(on: RunLoop.main)
                .sink { [weak fleet] limit, hours in
                    fleet?.apply(sessionLimit: limit, staleIdleAfter: hours > 0 ? TimeInterval(hours) * 3600 : nil)
                }
                .store(in: &cancellables)

            preferences.$pillFrost
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(pillFrost: CGFloat($0)) }
                .store(in: &cancellables)

            preferences.$promptCardOverFullScreen
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(promptCardOverFullScreen: $0) }
                .store(in: &cancellables)

            preferences.$cardScale
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.apply(cardScale: CGFloat($0)) }
                .store(in: &cancellables)

            preferences.$disconnectedProviders
                .receive(on: RunLoop.main)
                .sink { [weak store] in store?.disconnected = $0 }
                .store(in: &cancellables)

            preferences.$ollamaEndpoint
                .receive(on: RunLoop.main)
                .sink { [weak store] address in
                    guard let endpoint = try? OllamaEndpoint.parse(address) else { return }
                    store?.updateOllamaEndpoint(endpoint)
                }
                .store(in: &cancellables)

            preferences.$lmstudioEndpoint
                .receive(on: RunLoop.main)
                .sink { [weak store] address in
                    guard let endpoint = try? LMStudioEndpoint.parse(address) else { return }
                    store?.updateLMStudioEndpoint(endpoint)
                }
                .store(in: &cancellables)

            preferences.$providerOrder
                .receive(on: RunLoop.main)
                .sink { [weak store] in store?.order = $0 }
                .store(in: &cancellables)

            // Redraw the Gemini API ring against the new ceiling.
            //
            // `dropFirst` because `@Published` publishes the value it is given
            // at init, and a refresh there would race the store's first poll.
            // `receive(on:)` because `@Published` emits in `willSet` — the hop
            // to the next run loop pass is what lets the `didSet` persist the
            // number before the provider's closure goes looking for it.
            preferences.$geminiAPIMonthlyTokenBudget
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak store] _ in store?.refresh(providerID: "gemini-api") }
                .store(in: &cancellables)

            // Limit crossings become notifications here rather than inside
            // the store: the store fetches, the notifier decides what is
            // worth interrupting someone for, and neither needs to know the
            // other.
            let notifier = ThresholdNotifier(
                isMuted: { [weak preferences] in
                    guard let preferences else { return false }
                    return !preferences.thresholdAlertsEnabled || preferences.isMutedAlerts(for: $0)
                },
                deliver: { ThresholdAlerts.deliver($0) }
            )
            self.thresholdNotifier = notifier

            let resetWatcher = UsageResetWatcher(
                isMuted: { [weak preferences] in
                    guard let preferences else { return false }
                    return !preferences.thresholdAlertsEnabled || preferences.isMutedAlerts(for: $0)
                },
                deliver: { [weak self] event in
                    MainActor.assumeIsolated {
                        self?.announceUsageReset(event: event)
                    }
                }
            )
            self.resetWatcher = resetWatcher

            let limitWatcher = UsageLimitWatcher(
                isMuted: { [weak preferences] in
                    guard let preferences else { return false }
                    return !preferences.thresholdAlertsEnabled || preferences.isMutedAlerts(for: $0)
                },
                deliver: { [weak self] event in
                    MainActor.assumeIsolated {
                        self?.announceUsageLimit(event: event)
                    }
                }
            )
            self.limitWatcher = limitWatcher

            store.$notchSnapshots
                .receive(on: RunLoop.main)
                .sink { [weak fleet] in fleet?.setSnapshots($0) }
                .store(in: &cancellables)

            // Which agents are not signed in, and what the Connect button in
            // their tooltip does — in place of an effort bar they cannot use.
            Publishers.CombineLatest(store.$connectedCells, store.$needsRenewal)
                .receive(on: RunLoop.main)
                .sink { [weak fleet, weak store] _, _ in
                    guard let store else { return }
                    fleet?.apply(connectNeeds: store.connectNeeds())
                }
                .store(in: &cancellables)

            store.$snapshots
                .receive(on: RunLoop.main)
                .sink { [weak statusItem, weak self] snapshots in
                    statusItem?.snapshots = snapshots
                    UsageForecaster.shared.observe(snapshots)
                    self?.considerAutoEco(snapshots)
                    notifier.observe(snapshots)
                    resetWatcher.observe(snapshots)
                    limitWatcher.observe(snapshots)
                }
                .store(in: &cancellables)
            store.start()
            fleet.onRefresh = { [weak store] in store?.refreshNow() }
            fleet.onRefreshProvider = { [weak store] id in
                await store?.refresh(providerID: id)?.value
            }
            // A ring's own right-click menu: its page, its alerts, its place.
            fleet.agentMenuActions = AgentMenuActions(
                manageURL: { [weak store] id in store?.manageURL(providerID: id) },
                alertsMuted: { [weak preferences] id in preferences?.isMutedAlerts(for: id) ?? false },
                setAlertsMuted: { [weak preferences] id, muted in preferences?.setAlertsMuted(muted, for: id) },
                hide: { [weak preferences] id in preferences?.setConnected(false, for: id) },
                reorder: { [weak preferences] ids in preferences?.setProviderOrder(ids) },
                account: { [weak store] id in store?.account(providerID: id) },
                signInRoute: { [weak store] id in store?.signInRoute(providerID: id) },
                openAccountSource: { [weak store] id, switching in
                    // Signed in somewhere else, and nothing says when: look again for a while.
                    if store?.openAccountSource(providerID: id, switching: switching) == true {
                        store?.followUp(providerID: id)
                    }
                },
                openAPIKeys: { [weak self] in self?.settings?.show(section: .api) }
            )
            store.$refreshing
                .receive(on: RunLoop.main)
                .sink { [weak fleet] ids in fleet?.setRefreshing(ids) }
                .store(in: &cancellables)

            // PILLR_DISCOVER=<url> loads that page in the signed-in WebView
            // and logs the API calls it makes — for finding an undocumented
            // endpoint by watching the site rather than guessing at path names.
            if let target = ProcessInfo.processInfo.environment["PILLR_DISCOVER"],
               let url = URL(string: target),
               let provider = webProviders.first(where: { url.host?.contains($0.id) == true })
                   ?? webProviders.first {
                Task {
                    let calls = await provider.recordCalls(on: url)
                    Log.usage.notice("discovered: \(calls.joined(separator: "  "), privacy: .public)")
                }
            }
            self.store = store
            // Per-project spend: samples each limit reading against the
            // turns the transcripts record — see `Costs`.
            Costs.attach(to: store)
        }

        // What each agent is doing right now, so the notch can say whether it is
        // still working without you switching to it.
        var monitors: [String: any AgentActivityMonitor] = [
            "cursor": CursorActivityMonitor(),
            "gemini": AntigravityActivityMonitor(),
            "grok": GrokActivityMonitor(),
            "gemini-api": GeminiAPIActivityMonitor(),
            "kimi": KimiActivityMonitor(),
        ]
        var claudeMonitors: [ClaudeSessionMonitor] = []
        for profile in claudeProfiles {
            let monitor = ClaudeSessionMonitor(
                directory: profile.sessionsDirectory,
                projects: profile.projectsDirectory
            )
            claudeMonitors.append(monitor)
            monitors[profile.id] = monitor
        }
        for profile in codexProfiles {
            monitors[profile.id] = CodexActivityMonitor(profile: profile)
        }

        // Renewing the token runs the Claude command, which registers a session
        // of its own for the second it lives. Every Claude monitor is told to
        // step over that pid, so it never reaches the notch and never counts as
        // work in progress.
        //
        // Only the default profile is renewed. The command writes whichever
        // directory `CLAUDE_CONFIG_DIR` names, so a second profile would need
        // that passed through — behaviour nobody has been able to try on a Mac
        // with two of them, and an unverified guess is worse here than a ring
        // that ages the way it already does.
        if let defaultProvider = claudeProviders.first(where: { $0.profile.slug == nil }) {
            let refresher = ClaudeTokenRefresher(
                expiry: { await defaultProvider.tokenExpiry },
                reload: { await defaultProvider.reloadTokenExpiry() }
            )
            for monitor in claudeMonitors {
                monitor.ignoredPIDs = { [weak refresher] in
                    guard let pid = refresher?.launchedPID else { return [] }
                    return [pid]
                }
            }
            // The one place the failure becomes visible. The store carries the
            // fact; nothing here retries, and the warning clears itself the
            // moment a reading comes back.
            refresher.$outcome
                .receive(on: RunLoop.main)
                .sink { [weak self] outcome in
                    guard case .failed = outcome else { return }
                    self?.store?.reportRenewalFailed(providerID: defaultProvider.id)
                }
                .store(in: &cancellables)

            // Off means `claude` is never launched; the switch applies live.
            preferences.$autoRefreshClaudeToken
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak refresher] enabled in
                    MainActor.assumeIsolated {
                        if enabled { refresher?.start() } else { refresher?.stop() }
                    }
                }
                .store(in: &cancellables)
            tokenRefresher = refresher
        }
        for (id, monitor) in monitors {
            monitor.sessionsPublisher
                .receive(on: RunLoop.main)
                .sink { [weak self, weak fleet] live in
                    guard let fleet else { return }
                    fleet.setSessions(providerID: id, sessions: live)
                    // The publisher delivers on the main run loop, but the
                    // closure itself is nonisolated — the same assertion the
                    // notch controller's timers make.
                    MainActor.assumeIsolated { self?.announceCompletions(sessions: fleet.sessions) }
                }
                .store(in: &cancellables)
            monitor.start()
        }
        // Poll usage hard only while something is actually running — an agent's
        // session, or a local model reading a prompt or generating.
        store?.isBusy = { [weak self] in
            monitors.values.contains { m in m.sessions.contains { $0.state == .busy } }
                || (self?.lmstudioMetrics?.isBusy ?? false)
        }
        self.monitors = monitors

        // The lid as an effort control: push it open a notch and every
        // agent's default effort steps up; the rings show the level. Its
        // Claude sessions are the fleet's own — the same monitors that drive
        // the activity arcs — so what the lid can reach is what the notch
        // already shows. Not under test: the poller reads a hardware sensor
        // and writes the user's real agent configs.
        if !isRunningTests {
            let effort = EffortController()
            effort.claudeSessions = { [weak fleet] in
                guard let fleet else { return [] }
                return fleet.sessions
                    .filter { $0.key.hasPrefix(ClaudeProfile.defaultID) }
                    .values.flatMap { $0 }
            }
            effort.$state
                .receive(on: RunLoop.main)
                .sink { [weak fleet] state in
                    MainActor.assumeIsolated { fleet?.setEffort(state) }
                }
                .store(in: &cancellables)
            effort.onChange = { [weak fleet] event in fleet?.showEffortAlert(event) }
            effort.onPreview = { [weak fleet] position, level, note in
                fleet?.setEffortPreview(position, level: level, note: note?.text, noteIsLive: note?.isLive ?? false,
                                        agent: note?.agent, aim: note?.aim)
            }
            // The bars are the lid by hand: same level, same targets.
            fleet.onSetEffort = { [weak effort] providerID, index in
                effort?.set(scaleIndex: index, forTargetID: EffortState.targetID(forProviderID: providerID))
            }
            fleet.onSetLidLevel = { [weak effort] index in
                let levels = EffortLevel.allCases
                effort?.set(level: levels[min(levels.count - 1, max(0, index))])
            }
            effort.start()
            self.effort = effort
        }

        // Applied last, right before the panel goes up: every one of these
        // calls a `NotchFleet.apply(...)` that can trigger `reconcile()` on
        // its own — `displayPreference` always does, being how the very
        // first controller gets created — and `reconcile()` copies the
        // fleet's callbacks (`onOpenSettings`, `onRefreshProvider`, ...) into
        // that controller at creation time, not through a live reference.
        // Calling any of these earlier, before those callbacks were set
        // above, silently built the one controller this app ever has with
        // every action wired to nothing: the panel still opened and rings
        // still drew, so there was nothing to notice except every click
        // doing exactly nothing. `fleet.show()`'s own reconcile only ever
        // repositions an existing controller — it does not re-copy them —
        // so this has to be the very last thing that can create one.
        fleet.apply(displayPreference: preferences.displayPreference)
        fleet.apply(alongOffset: preferences.offset(for: preferences.notchEdge))
        fleet.apply(scale: preferences.notchScale)
        fleet.apply(resetTimeFormat: preferences.resetTimeFormat)
        fleet.apply(accentColor: preferences.accentColor)
        fleet.apply(weeklyRing: preferences.weeklyRing)
        fleet.apply(showsMoveHandle: preferences.showsMoveHandle)
        fleet.apply(surfaceStyle: preferences.notchSurfaceStyle)
        fleet.apply(interfaceMode: preferences.interfaceMode)
        if !isRunningTests { startPromptBroker(fleet: fleet, preferences: preferences) }
        fleet.apply(pillFrost: CGFloat(preferences.pillFrost))
        fleet.show()
    }

    /// Answering Claude Code's prompts from the notch: the broker the hook
    /// talks to, and the hook itself, installed or removed with the setting.
    @MainActor
    private func startPromptBroker(fleet: NotchFleet, preferences: Preferences) {
        let broker = PromptBroker()
        broker.onPrompt = { [weak self, weak fleet] incoming in
            // During the intro tour the pill is showing its own demo prompts;
            // a real one is left to Claude's own dialog rather than stacked
            // on top of them.
            if fleet?.isTouring == true { return .passThrough }
            var prompt = incoming
            if let id = prompt.sessionID, let pid = ClaudeSessionLookup.pid(forSessionID: id) {
                prompt.pid = pid
                prompt.sessionName = fleet?.sessions.values.flatMap { $0 }
                    .first { $0.processID == pid }?.name
                // The person is looking at that session: its own dialog is
                // where they will answer, and holding the hook would hide it.
                // Only someone who is there is looking: a terminal left in
                // front by someone who walked away is no one's view, and the
                // question waits in the notch for them instead.
                if UserPresence.isPresent, Self.isInView(pid: pid, focus: EffortInjector.focus()) { return .passThrough }
            }
            // Which piece of work it is, for when several sessions run at
            // once: read now, once, from the end of that session's transcript.
            prompt.context = PromptContext.load(transcript: prompt.transcriptPath, cwd: prompt.cwd)
            fleet?.addPrompt(prompt)
            PromptAlerts.announce(prompt, preferences: preferences)
            self?.promptReminder.sounded(at: Date())
            return nil
        }
        broker.onGone = { [weak fleet] id in
            fleet?.removePrompt(id)
            PromptAlerts.withdraw(id)
        }
        fleet.onAnswerPrompt = { [weak broker, weak self] id, answer in
            // The tour's own demo prompts: answered here, sent nowhere.
            if self?.tour?.handleAnswer(id, with: answer) == true { return }
            broker?.answer(id, with: answer)
        }
        fleet.onOpenPrompt = { [weak broker, weak self] prompt in
            if self?.tour?.handleAnswer(prompt.id) == true { return }
            // Answer it there: let the hook go so Claude shows its dialog,
            // and take the person to the session.
            broker?.answer(prompt.id, with: .passThrough)
            if let pid = prompt.pid { Task { _ = await SessionFocus.focus(pid: pid) } }
        }
        // Held until answered — and handed back the moment the person goes
        // to that session, so its own dialog is there when they arrive
        // rather than waiting on a card they are no longer looking at.
        let watch = Timer(timeInterval: 1.5, repeats: true) { [weak self, weak fleet, weak broker] _ in
            MainActor.assumeIsolated {
                guard let fleet, let broker else { return }
                // Again, every few minutes, for as long as one waits.
                if let self {
                    self.promptReminder.minutes = preferences.promptReminderMinutes
                    if self.promptReminder.due(waiting: !fleet.prompts.isEmpty, now: Date()),
                       let oldest = fleet.prompts.first,
                       let sound = PromptAlerts.sound(for: oldest, preferences: preferences) {
                        SessionChime.play(sound)
                    }
                }
                // Away: questions wait in the notch, however long — nothing
                // is handed back to a session no one is looking at. Back:
                // the card is put in front again and sounds once, so a
                // question that arrived while they were gone is the first
                // thing they see.
                let present = UserPresence.isPresent
                if let self {
                    defer { self.wasPresent = present }
                    if present, !self.wasPresent, !fleet.prompts.isEmpty {
                        fleet.resurfacePrompts()
                        if let oldest = fleet.prompts.first,
                           let sound = PromptAlerts.sound(for: oldest, preferences: preferences) {
                            SessionChime.play(sound)
                            self.promptReminder.sounded(at: Date())
                        }
                    }
                }
                guard present, fleet.prompts.contains(where: { $0.pid != nil }) else { return }
                let focus = EffortInjector.focus()
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                for prompt in fleet.prompts {
                    guard let pid = prompt.pid else { continue }
                    if Self.isInView(pid: pid, focus: focus) {
                        broker.answer(prompt.id, with: .passThrough)
                    } else if Date().timeIntervalSince(prompt.receivedAt) > Self.presentPatience,
                              let host = SessionFocus.owningApp(of: pid)?.processIdentifier, host == front {
                        // Here, in the app the session runs in, and the card
                        // left a long while: a terminal pillr cannot see into
                        // (iTerm2, Ghostty, an IDE) may be the very tab they
                        // are in. Its own dialog, there, is the safer place.
                        broker.answer(prompt.id, with: .passThrough)
                    }
                }
            }
        }
        RunLoop.main.add(watch, forMode: .common)

        // Claude Code's Stop hook: the answer is finished. Done at once —
        // unless a command it started is still running in the background,
        // which will wake it again; then the next Stop is the one.
        broker.onStop = { [weak self] stop in
            // The hook's own shell is a child of the session until it exits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.agentStopped(stop) }
            }
        }
        do { try broker.start() } catch {
            Log.usage.error("prompt broker failed to start: \(error.localizedDescription, privacy: .public)")
        }
        promptBroker = broker

        // Every agent's turn-finished hook goes in with the done card, and
        // out with it — where the agent is installed, once the person has
        // seen what they are (`HookConsent`), from a copy that stays put.
        // Turning either switch on in Settings is consent too.
        HookConsent.migrate()
        let consent = NotificationCenter.default.publisher(for: HookConsent.changed).map { _ in () }.prepend(())
        preferences.$announceSessionEnd.removeDuplicates().dropFirst().filter { $0 }
            .merge(with: preferences.$answerPromptsFromNotch.removeDuplicates().dropFirst().filter { $0 })
            .sink { _ in HookConsent.grant() }
            .store(in: &cancellables)

        preferences.$announceSessionEnd
            .removeDuplicates()
            .combineLatest(consent)
            .receive(on: RunLoop.main)
            .sink { enabled, _ in
                guard enabled else { AgentHooks.removeAll(); return }
                guard HookConsent.mayInstall(), let executable = Bundle.main.executablePath else { return }
                AgentHooks.installAll(executable: executable)
            }
            .store(in: &cancellables)

        preferences.$answerPromptsFromNotch
            .removeDuplicates()
            .combineLatest(consent)
            .receive(on: RunLoop.main)
            .sink { enabled, _ in
                do {
                    if enabled {
                        // Claude Code's own folder: never made for someone without it.
                        guard HookConsent.mayInstall(), AgentHooks.claudePresent,
                              let executable = Bundle.main.executablePath else { return }
                        try ClaudeHookInstaller.install(executable: executable)
                    } else if ClaudeHookInstaller.isInstalled() {
                        try ClaudeHookInstaller.remove()
                    }
                } catch {
                    Log.usage.error("prompt hook \(enabled ? "install" : "removal", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            .store(in: &cancellables)
    }

    /// Whether a session is the one in front of the person: the selected
    /// Terminal tab it runs in, or the app hosting it when it has no tty.
    @MainActor
    static func isInView(pid: pid_t, focus: FocusContext) -> Bool {
        let tty = SessionFocus.tty(of: pid)
        if let tty { return tty == focus.focusedTTY }
        guard let app = SessionFocus.owningApp(of: pid), app.localizedName == focus.frontmostApp else { return false }
        // The Claude app holds many sessions in one window: only the one it
        // is showing is in view, not every session it hosts.
        if app.bundleIdentifier == ClaudeDesktopComposer.bundleID {
            guard let host = SessionModels.desktop(pid: pid)?.hostSessionID, !host.isEmpty else { return false }
            return ClaudeDesktopComposer.view() == .session(host)
        }
        return true
    }

    /// Open the notch, and make a noise, when something has just finished.
    ///
    /// The watcher is fed on every publication whether or not anything is
    /// switched on, because it is a difference engine: skipping a reading would
    /// leave it comparing against a state two changes old, and the *next*
    /// transition it reported would be one that never happened.
    ///
    /// Several sessions can land in the same reading — one turn ending often
    /// unblocks another — and that gets one peek and one chime rather than a
    /// chord. The newest is the one offered, since it is the one whose window
    /// you were most recently in.
    @MainActor
    private func announceCompletions(sessions: [String: [AgentSession]]) {
        let events = completions.absorb(sessions)
        // Working again: whatever finish it had pending was a pause.
        let all: [AgentSession] = sessions.values.flatMap { $0 }
        let working: Set<String> = Set(all.filter { $0.state == .busy || $0.state == .waiting }.map { $0.id })
        for id in working { settling.removeValue(forKey: id)?.cancel() }
        for event in events where event.reason == .finished {
            // Already said, in real time, by the Stop hook.
            if let said = saidByHook[event.session.id], Date().timeIntervalSince(said) < 60 { continue }
            if let said = saidByHookProvider[EffortState.targetID(forProviderID: event.providerID)],
               Date().timeIntervalSince(said) < 60 { continue }
            settling[event.session.id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.settling[event.session.id] = nil
                    self.announce(event)
                }
            }
            settling[event.session.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishSettle, execute: work)
        }
        // A session waiting on you is said at once.
        let waiting: Set<pid_t> = Set(all.filter { $0.state == .waiting }.compactMap { $0.processID })
        notchFleet?.resolveWaiting(waitingPIDs: waiting)
        if let blocked = events.first(where: { $0.reason == .blocked }) { announce(blocked) }
    }

    /// An agent's own hook said its turn finished. Claude Code and Grok
    /// name a process: when a command they started still runs in the
    /// background, this was not the end and the next stop is. Codex and
    /// Cursor name a thread: their session in the notch, or one made from
    /// the folder when the notch has none.
    @MainActor
    private func agentStopped(_ stop: AgentStop) {
        let lists = notchFleet?.sessions ?? [:]
        let all: [(provider: String, session: AgentSession)] = lists.flatMap { key, list in list.map { (key, $0) } }
        var found: (provider: String, session: AgentSession)?
        switch stop.agent {
        case "claude":
            guard let id = stop.sessionID, let pid = ClaudeSessionLookup.pid(forSessionID: id) else { return }
            guard BackgroundShells.count(under: pid) == 0 else {
                Log.usage.info("stop hook: claude pid \(pid, privacy: .public) still has background work")
                return
            }
            found = all.first { $0.session.processID == pid }
        case "grok":
            guard let id = stop.sessionID else { return }
            if let pid = GrokActivity.pid(forSessionID: id), BackgroundShells.count(under: pid) > 0 {
                Log.usage.info("stop hook: grok pid \(pid, privacy: .public) still has background work")
                return
            }
            found = all.first { $0.session.id == "grok.\(id)" }
        default:
            // Antigravity's ring is the one its provider has always used: `gemini`.
            // Antigravity's ring is the one its provider has always used,
            // `gemini`; Gemini CLI's is the API key's, `gemini-api`.
            let prefix = ["antigravity": "gemini", "gemini-cli": "gemini-api"][stop.agent] ?? stop.agent
            func ours(_ provider: String) -> Bool {
                provider == prefix || (provider.hasPrefix(prefix + "-") && !(prefix == "gemini" && provider.hasPrefix("gemini-api")))
            }
            found = all.first { ours($0.provider) && (stop.sessionID.map($0.session.id.contains) ?? false) }
                ?? all.first { ours($0.provider) }
        }
        let event: SessionCompletionWatcher.Event
        if let found {
            event = .init(session: found.session, reason: .finished, providerID: found.provider)
        } else {
            // No ring for it here: still say which agent finished, and where.
            let folder = stop.cwd.map { ($0 as NSString).lastPathComponent } ?? stop.agent.capitalized
            let session = AgentSession(id: "\(stop.agent).\(stop.sessionID ?? folder)", name: folder,
                                       detail: ProviderGlyph.forProvider(stop.agent)?.agentName ?? stop.agent.capitalized,
                                       state: .success, waitingFor: nil, since: Date())
            event = .init(session: session, reason: .finished, providerID: stop.agent)
        }
        settling.removeValue(forKey: event.session.id)?.cancel()
        if let said = saidByHook[event.session.id], Date().timeIntervalSince(said) < 3 { return }
        saidByHook[event.session.id] = Date()
        saidByHookProvider[EffortState.targetID(forProviderID: event.providerID)] = Date()
        announce(event)
    }

    /// Sounds and shows one finish or one wait.
    @MainActor
    private func announce(_ event: SessionCompletionWatcher.Event) {
        recordCompletion(event)
        guard let preferences, let fleet = notchFleet else { return }
        Log.usage.info("session \(event.session.name, privacy: .private) \(String(describing: event.reason), privacy: .public)")

        // A session blocked on a prompt the notch is holding has already
        // sounded, in the prompt's own voice — not twice.
        let promptSounded = event.reason == .blocked
            && fleet.prompts.contains { $0.pid != nil && $0.pid == event.session.processID }
        if preferences.sessionEndSound, !promptSounded {
            SessionChime.play(event.reason == .blocked
                              ? preferences.sessionBlockedSoundName
                              : preferences.sessionEndSoundName)
        }
        guard preferences.announceSessionEnd else { return }
        // The intro tour has the pill: a real note landing on its demo would
        // be two things talking at once.
        guard !fleet.isTouring else { return }
        // A line from the pill, not the whole notch: the announcement must
        // not get in the way of the work it is announcing.
        fleet.showDoneToast(event, duration: preferences.peekDuration.seconds)
    }

    /// A finish, for the dashboard, with the folder's uncommitted tree read
    /// off the main thread.
    @MainActor
    private func recordCompletion(_ event: SessionCompletionWatcher.Event) {
        guard let ledger = ActivityLedger.shared else { return }
        let session = event.session
        let folder = session.processID.flatMap(SessionFocus.currentDirectory(of:))
        let blocked = event.reason == .blocked
        Task.detached(priority: .utility) {
            let tree = blocked ? nil : folder.flatMap { GitChanges.stats(cwd: $0) }
            ledger.completed(agent: event.providerID, session: session.id, blocked: blocked, folder: folder, tree: tree)
        }
        // A finish may have broken a record: looked at once things settle.
        if !blocked {
            coachSoon?.cancel()
            coachSoon = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.coachCheck()
            }
        }
    }

    // MARK: The productivity coach

    static let coachEnabledKey = "coach.enabled"
    private var coachTimer: Timer?
    private var coachSoon: Task<Void, Never>?

    /// Every hour, and a minute after each finish: a record broken, or a
    /// nudge due, said on the notch at most once a day.
    @MainActor
    private func startCoach() {
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.coachCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        coachTimer = timer
    }

    @MainActor
    private func coachCheck() {
        guard UserDefaults.standard.object(forKey: Self.coachEnabledKey) as? Bool ?? true,
              let ledger = ActivityLedger.shared, let fleet = notchFleet, !fleet.isTouring else { return }
        let stores = CostModels.all.compactMap(\.store_)
        Task.detached(priority: .utility) { [weak fleet] in
            guard let finding = ProductivityCoach.check(ledger: ledger, stores: stores) else { return }
            await MainActor.run {
                var event = UsageAlertEvent(kind: .recap, providerID: "coach", providerName: "", windowLabel: "",
                                            glyph: .third, previousFraction: 0, currentFraction: 0, resetsAt: nil)
                event.note = ProductivityCoach.note(finding)
                fleet?.showResetAlert(event, duration: 10)
            }
        }
    }

    /// Steps effort down when an agent is about to run out, if switched on.
    @MainActor private let autoEco = AutoEco()
    private var recapScheduler: DailyRecapScheduler?
    private var featureDemo: FeatureDemo?

    /// An agent about to run out: effort down one step, said on the card.
    @MainActor
    private func considerAutoEco(_ snapshots: [ProviderSnapshot]) {
        guard let effort, let near = autoEco.trigger(snapshots, forecaster: .shared) else { return }
        // Only the agent that is running out steps down.
        effort.stepDown(agent: EffortState.targetID(forProviderID: near.providerID),
                        reason: L10n.t("Auto-eco · \(near.displayName) is near its limit"))
    }

    /// Open the notch and show a usage reset notification modal when a limit resets.
    @MainActor
    private func announceUsageReset(event: UsageResetEvent) {
        guard let preferences, let fleet = notchFleet else { return }
        Log.usage.info("usage reset for \(event.providerName, privacy: .public) (\(event.windowLabel, privacy: .public))")

        if preferences.usageResetSound {
            SessionChime.play(preferences.usageResetSoundName)
        }
        guard preferences.announceUsageReset, !fleet.isTouring else { return }
        fleet.showResetAlert(event, duration: 5.0)
    }

    @MainActor
    private func previewUsageResetAlert() {
        guard let preferences, let fleet = notchFleet else { return }
        let demo = UsageResetEvent(
            providerID: "claude",
            providerName: "Claude",
            windowLabel: "5-hour limit",
            glyph: .claude,
            previousFraction: 0.95,
            currentFraction: 0.00,
            resetsAt: Date().addingTimeInterval(5 * 3600)
        )
        if preferences.usageResetSound {
            SessionChime.play(preferences.usageResetSoundName)
        }
        fleet.showResetAlert(demo, duration: 5.0)
    }

    /// Open the notch and show a usage limit reached notification modal when a limit is exhausted.
    @MainActor
    private func announceUsageLimit(event: UsageAlertEvent) {
        guard let preferences, let fleet = notchFleet else { return }

        let isAnnounceEnabled: Bool
        switch event.kind {
        case .sessionLimitReached:
            isAnnounceEnabled = preferences.announceSessionLimitReached
        case .weeklyLimitReached:
            isAnnounceEnabled = preferences.announceWeeklyLimitReached
        case .reset:
            isAnnounceEnabled = preferences.announceUsageReset
        case .recap:
            isAnnounceEnabled = true
        }

        guard isAnnounceEnabled else { return }

        Log.usage.info("usage limit reached for \(event.providerName, privacy: .public) (\(event.windowLabel, privacy: .public))")

        if preferences.limitReachedSound {
            SessionChime.play(preferences.limitReachedSoundName)
        }
        guard !fleet.isTouring else { return }
        fleet.showResetAlert(event, duration: 6.0)
    }

    @MainActor
    private func previewSessionLimitAlert() {
        guard let preferences, let fleet = notchFleet else { return }
        let demo = UsageAlertEvent(
            kind: .sessionLimitReached,
            providerID: "claude",
            providerName: "Claude",
            windowLabel: "5-hour",
            glyph: .claude,
            previousFraction: 0.95,
            currentFraction: 1.00,
            resetsAt: Date().addingTimeInterval(45 * 60)
        )
        if preferences.limitReachedSound {
            SessionChime.play(preferences.limitReachedSoundName)
        }
        fleet.showResetAlert(demo, duration: 6.0)
    }

    @MainActor
    private func previewWeeklyLimitAlert() {
        guard let preferences, let fleet = notchFleet else { return }
        let demo = UsageAlertEvent(
            kind: .weeklyLimitReached,
            providerID: "claude",
            providerName: "Claude",
            windowLabel: "Weekly",
            glyph: .claude,
            previousFraction: 0.98,
            currentFraction: 1.00,
            resetsAt: Date().addingTimeInterval(3 * 86400)
        )
        if preferences.limitReachedSound {
            SessionChime.play(preferences.limitReachedSoundName)
        }
        fleet.showResetAlert(demo, duration: 6.0)
    }

    /// Closing the settings window must not take the app with it.
    ///
    /// The default for a Dock app is to quit once its last window closes, which
    /// here would kill the notch — the part that is actually the product —
    /// every time someone shut the settings they had just opened.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The way back in when the notch is hidden.
    ///
    /// With no dock icon, no menu bar item and no notch on screen, there is
    /// otherwise nothing left to click — choosing Hide would be a one-way door.
    /// Launching the app again while it is already running lands here, so
    /// opening it from Applications or Spotlight reopens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        // Mid-setup, the assistant is what they came back for — and
        // Settings opening over it hid the step they were on.
        if setup?.isVisible == true || !UserDefaults.standard.bool(forKey: SetupGate.seenKey) {
            setup?.show()
        } else {
            openSettings()
        }
        return true
    }

    @MainActor func openSettings() { settings?.show() }
    @MainActor func checkForUpdates() { updater?.checkNow() }

    func applicationWillTerminate(_ notification: Notification) {
        ollamaRelay?.configure(enabled: false, endpoint: OllamaEndpoint.defaultAddress)
        lmstudioMetrics?.stop()
        tokenRefresher?.stop()
        store?.stop()
        monitors.values.forEach { $0.stop() }
        notchFleet?.stop()
    }
}
