import AppKit
import Combine
import Foundation
import ServiceManagement
import os

/// What the user has chosen, kept in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    static let showUsagePaceKey = "showUsagePace"

    /// Disabled model IDs hide cells without stopping their shared runtime.
    @Published var disconnectedProviders: Set<String> {
        didSet { defaults.set(Array(disconnectedProviders), forKey: Keys.disconnected) }
    }

    /// Everything but Claude Code, Codex and Grok (and their profiles, whose
    /// ids carry a suffix and are never in this set).
    static let disconnectedByDefault: Set<String> = [
        "cursor", "gemini", "antigravity", "glm", "devin", "opencode", "commandcode",
        "copilot", "kimi", "deepseek", "perplexity", "ollama", "ollama-local", "lmstudio",
        "kiro", "amp", "apify", "kilo", "minimax", "qianwenai",
    ]

    /// Providers added after people already had a saved list. Off for them until switched on; see `init`.
    static let introducedLater: Set<String> = ["kiro", "amp", "apify", "kilo", "minimax", "qianwenai"]

    /// A fresh install's rings: the coding agents found on this Mac — their
    /// folder, app or binary — so nobody is shown "Not signed in" for an
    /// agent they never installed. Found nothing: the three the lid drives,
    /// as before, rather than an empty pill. Local runtimes keep their own
    /// introduction and stay off here.
    static func freshDisconnected(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath) },
                                  appInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        -> Set<String> {
        let signs: [String: Bool] = [
            "claude": exists("~/.claude"),
            "codex": exists("~/.codex") || appInstalled("com.openai.codex"),
            "grok": exists("~/.grok"),
            "cursor": appInstalled("com.todesktop.230313mzl4w4u92") || exists("~/.cursor/cli-config.json"),
            "gemini": appInstalled("com.google.antigravity"),
            "gemini-api": exists("~/.gemini/tmp") || exists("~/.gemini/projects.json"),
            "kimi": exists("~/.kimi-code"),
            "opencode": exists("~/.local/share/opencode"),
            "copilot": exists("~/.copilot"),
            "amp": exists("~/.local/share/amp/secrets.json"),
            "apify": exists("~/.apify/auth.json"),
            "kilo": exists("~/.local/share/kilo/auth.json"),
            "kiro": exists("~/Library/Application Support/kiro-cli/data.sqlite3"),
        ]
        let found = Set(signs.filter(\.value).keys)
        guard !found.isEmpty else { return disconnectedByDefault }
        return disconnectedByDefault.union(["claude", "codex", "grok", "gemini-api"]).subtracting(found)
    }

    @Published var ollamaMetricsEnabled: Bool {
        didSet { defaults.set(ollamaMetricsEnabled, forKey: Keys.ollamaMetricsEnabled) }
    }

    @Published var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Keys.ollamaEndpoint) }
    }

    /// Where LM Studio's server answers. Defaults to the port LM Studio's own
    /// settings name, so a server moved off 1234 is found without typing.
    @Published var lmstudioEndpoint: String {
        didSet { defaults.set(lmstudioEndpoint, forKey: Keys.lmstudioEndpoint) }
    }

    /// Providers whose threshold alerts are muted. Stored as the muted set so
    /// a provider added later alerts by default — the same reasoning as
    /// `disconnectedProviders`.
    @Published var mutedAlertProviders: Set<String> {
        didSet { defaults.set(Array(mutedAlertProviders), forKey: Keys.mutedAlerts) }
    }

    /// The 80% / 100% system notifications as a whole. On by default, as
    /// they always were; each provider's bell in Accounts still mutes one.
    @Published var thresholdAlertsEnabled: Bool {
        didSet { defaults.set(thresholdAlertsEnabled, forKey: Keys.thresholdAlerts) }
    }

    /// The order the user has dragged the rings into, as provider ids.
    ///
    /// Stored as the ids actually placed rather than as every id known at the
    /// time: providers are discovered at launch — Claude Code contributes one
    /// per `~/.claude-<slug>` — so an exhaustive list written today is wrong
    /// the moment a profile appears. `ProviderOrder` reconciles the two,
    /// forgivingly in both directions.
    ///
    /// Empty means never chosen, which is not the same as having chosen the
    /// order the app ships with: keeping them distinct is what lets a later
    /// version change the built-in order for everyone who never had an opinion.
    @Published var providerOrder: [String] {
        didSet { defaults.set(providerOrder, forKey: Keys.order) }
    }

    /// How much of itself the notch shows at rest.
    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Keys.visibility) }
    }

    /// Which screen edge the notch is welded to.
    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Keys.edge) }
    }

    /// How large the notch is drawn, as one of three named sizes.
    ///
    /// Ignored while `usesCustomNotchScale` is on — the two are kept apart
    /// rather than collapsed into one number so that switching back to the
    /// presets returns to the preset you last chose, instead of to whichever
    /// preset happens to sit nearest the slider.
    @Published var notchSize: NotchSize {
        didSet { defaults.set(notchSize.rawValue, forKey: Keys.size) }
    }

    /// Whether the slider decides the size rather than the three presets.
    @Published var usesCustomNotchScale: Bool {
        didSet { defaults.set(usesCustomNotchScale, forKey: Keys.usesCustomSize) }
    }

    /// The slider's own multiplier, honoured only when the slider is in
    /// charge. Clamped on the way in: a value typed straight into `defaults`
    /// could otherwise shrink the notch to nothing or blow it off the screen.
    @Published var customNotchScale: Double {
        didSet {
            let clamped = min(max(customNotchScale, Self.customScaleRange.lowerBound),
                              Self.customScaleRange.upperBound)
            if clamped != customNotchScale { customNotchScale = clamped; return }
            defaults.set(customNotchScale, forKey: Keys.customSize)
        }
    }

    /// Where the slider may go. Wider than the presets at both ends, but not
    /// unbounded: below about three quarters the percentage under each ring
    /// stops being readable, which is the one thing the notch exists for.
    static let customScaleRange: ClosedRange<Double> = 0.75...1.5

    /// What the notch is actually drawn at, whichever control is in charge.
    var notchScale: CGFloat {
        usesCustomNotchScale ? CGFloat(customNotchScale) : notchSize.scale
    }

    /// The cards' own size — tooltips, prompts, the done card — apart from
    /// the pill's. A bigger pill is not always a wish for bigger text, and
    /// the other way round.
    @Published var cardScale: Double {
        didSet { defaults.set(cardScale, forKey: Keys.cardScale) }
    }
    /// The same range and the same marks as the pill's own slider, so the
    /// two read alike side by side.
    static let cardScaleRange: ClosedRange<Double> = 0.75...1.5
    static var cardScaleMarks: [(title: String, value: Double)] {
        [(L10n.t("Small"), 0.8), (L10n.t("Default"), 1.0), (L10n.t("Large"), 1.25)]
    }

    /// The display the notch stays on, or the original focus-following behaviour.
    ///
    /// Only meaningful in `NotchScreenScope.main` — pinning a display and
    /// drawing on every display are two different questions, and this answers
    /// the first one. `all` ignores it entirely: there is no "the" display to
    /// pin when every one of them gets its own notch.
    @Published var displayPreference: DisplayPreference {
        didSet {
            switch displayPreference {
            case .followActiveWindow:
                defaults.removeObject(forKey: Keys.display)
            case .display(let id):
                defaults.set(id, forKey: Keys.display)
            }
        }
    }

    /// Which displays get a notch when more than one is connected.
    @Published var notchScope: NotchScreenScope {
        didSet { defaults.set(notchScope.rawValue, forKey: Keys.scope) }
    }

    /// The preferred limit window to show for Antigravity provider (automatic, 5h, or weekly).
    @Published var antigravityHeadlineLimit: AntigravityHeadlineLimit {
        didSet { defaults.set(antigravityHeadlineLimit.rawValue, forKey: Keys.antigravityHeadlineLimit) }
    }

    /// The preferred model group to show for Antigravity provider (Gemini or Claude and GPT models).
    @Published var antigravityHeadlineModel: AntigravityHeadlineModel {
        didSet { defaults.set(antigravityHeadlineModel.rawValue, forKey: Keys.antigravityHeadlineModel) }
    }

    /// Where along that edge the notch sits, nudged from the centred default
    /// by ⌥-dragging the pill. One value per edge — moving it on the right
    /// should not silently relocate it on the top too — so this is read and
    /// written through `offset(for:)`/`setOffset(_:for:)` rather than exposed
    /// as a single published value the way the other settings are.
    func offset(for edge: NotchEdge) -> CGFloat {
        CGFloat(defaults.double(forKey: Self.offsetKey(for: edge)))
    }

    func setOffset(_ offset: CGFloat, for edge: NotchEdge) {
        defaults.set(Double(offset), forKey: Self.offsetKey(for: edge))
    }

    private static func offsetKey(for edge: NotchEdge) -> String { "notchOffset.\(edge.rawValue)" }

    @Published var resetTimeFormat: ResetTimeFormat {
        didSet { defaults.set(resetTimeFormat.rawValue, forKey: Keys.resetTimeFormat) }
    }

    @Published var showUsagePace: Bool {
        didSet { defaults.set(showUsagePace, forKey: Self.showUsagePaceKey) }
    }

    /// Whether the weekly limit gets a ring of its own, and where it sits.
    @Published var weeklyRing: WeeklyRing {
        didSet { defaults.set(weeklyRing.rawValue, forKey: Keys.weeklyRing) }
    }

    /// Whether the move handle's arc is drawn above the notch.
    @Published var showsMoveHandle: Bool {
        didSet { defaults.set(showsMoveHandle, forKey: Keys.showsMoveHandle) }
    }

    /// The colour used for positive usage and active-work indicators.
    @Published var accentColor: AccentColorChoice {
        didSet { defaults.set(accentColor.rawValue, forKey: Keys.accentColor) }
    }

    /// The material the expanded notch, tooltip and settings orb are painted with.
    @Published var notchSurfaceStyle: NotchSurfaceStyle {
        didSet { defaults.set(notchSurfaceStyle.rawValue, forKey: Keys.notchSurfaceStyle) }
    }

    /// Light or dark glass for the notch, its cards and Settings.
    @Published var interfaceMode: InterfaceMode {
        didSet { defaults.set(interfaceMode.rawValue, forKey: Keys.interfaceMode) }
    }

    /// Whether the Liquid Glass intro plays its sound.
    @Published var tourSound: Bool {
        didSet { defaults.set(tourSound, forKey: Keys.tourSound) }
    }

    /// How much frost the pill, its buttons and the cards keep under their
    /// glass, 0 (clear) … 1 (the material at full strength). One setting
    /// for all of it, so the tooltip is the same glass as the pill it
    /// hangs off.
    @Published var pillFrost: Double {
        didSet { defaults.set(pillFrost, forKey: Keys.pillFrost) }
    }
    static let pillFrostRange: ClosedRange<Double> = 0.04...1
    static let defaultPillFrost = 0.35

    /// The language the app itself speaks.
    ///
    /// `.system` follows the Mac. Written through `L10n.apply` so the store
    /// and the change notification stay a single write.
    @Published var language: AppLanguage {
        didSet { L10n.apply(language) }
    }

    /// Where the app itself shows up: Dock, menu bar, or nowhere.
    @Published var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Keys.presence) }
    }

    /// Open the notch for a few seconds when an agent stops working.
    ///
    /// On by default: the app already knows the moment a session ends, and a
    /// user who installed a thing that watches sessions is unlikely to want
    /// that particular fact kept from them. It is a peek, not a notification —
    /// nothing to dismiss, and it takes no focus.
    @Published var announceSessionEnd: Bool {
        didSet { defaults.set(announceSessionEnd, forKey: Keys.announceSessionEnd) }
    }

    /// How long that peek lasts.
    @Published var peekDuration: PeekDuration {
        didSet { defaults.set(peekDuration.rawValue, forKey: Keys.peekDuration) }
    }

    /// How many sessions a tooltip lists at most, newest first after the
    /// ones that need you. Fewer if the screen has no room for them.
    @Published var tooltipSessionLimit: Int {
        didSet { defaults.set(tooltipSessionLimit, forKey: Keys.tooltipSessionLimit) }
    }
    static let tooltipSessionLimitRange: ClosedRange<Int> = 3...10
    static let defaultTooltipSessionLimit = 6

    /// Route Claude Code's permission prompts and questions to the notch, by
    /// a `PermissionRequest` hook in ~/.claude/settings.json. On by default —
    /// answering from the notch is what the app is for — and one switch in
    /// Settings takes the hook out again. A session in view still asks in
    /// its own dialog, and with the app not running the hook stays silent.
    @Published var answerPromptsFromNotch: Bool {
        didSet { defaults.set(answerPromptsFromNotch, forKey: Keys.answerPromptsFromNotch) }
    }

    /// Idle sessions older than this drop out of the tooltip; 0 keeps them.
    /// A terminal left open overnight is not a session anyone is working in.
    @Published var hideIdleSessionsAfterHours: Int {
        didSet { defaults.set(hideIdleSessionsAfterHours, forKey: Keys.hideIdleSessionsAfterHours) }
    }
    static let hideIdleSessionsChoices = [1, 6, 24, 0]
    static let defaultHideIdleSessionsAfterHours = 6

    /// Sound the system alert alongside the peek.
    ///
    /// Separate from the peek because they fail differently: the peek is no use
    /// on another Space or behind a full-screen window, and the sound is no use
    /// in a meeting. Kept switchable on its own so neither one forces the
    /// other.
    @Published var sessionEndSound: Bool {
        didSet { defaults.set(sessionEndSound, forKey: Keys.sessionEndSound) }
    }

    /// Which sound a finished turn makes.
    @Published var sessionEndSoundName: String {
        didSet { defaults.set(sessionEndSoundName, forKey: Keys.sessionEndSoundName) }
    }

    /// And which one a session blocked on you makes.
    ///
    /// A separate choice because the two say different things — one is "that's
    /// done", the other is "you are the hold-up" — and a single sound for both
    /// makes the second one easy to ignore.
    @Published var sessionBlockedSoundName: String {
        didSet { defaults.set(sessionBlockedSoundName, forKey: Keys.sessionBlockedSoundName) }
    }

    // MARK: When Claude asks

    /// A sound when Claude stops to ask — its own, apart from a session
    /// merely finishing: a prompt is the one thing that waits for you.
    @Published var promptSound: Bool {
        didSet { defaults.set(promptSound, forKey: Keys.promptSound) }
    }

    /// The sound for a permission request…
    @Published var approvalSoundName: String {
        didSet { defaults.set(approvalSoundName, forKey: Keys.approvalSoundName) }
    }

    /// …and a different one for a question, so the ear knows which it is.
    @Published var questionSoundName: String {
        didSet { defaults.set(questionSoundName, forKey: Keys.questionSoundName) }
    }

    /// Play it again every so many minutes while nobody answers; 0 is once.
    @Published var promptReminderMinutes: Int {
        didSet { defaults.set(promptReminderMinutes, forKey: Keys.promptReminderMinutes) }
    }
    static let promptReminderChoices = [0, 1, 2, 5]

    /// Also post a macOS notification — for when the notch is hidden, or on
    /// another display, or you are on another Space.
    @Published var promptSystemNotification: Bool {
        didSet { defaults.set(promptSystemNotification, forKey: Keys.promptSystemNotification) }
    }

    /// Whether the card comes up over a full-screen app. Off, a prompt in a
    /// game or a presentation is a sound only, and the card waits until you
    /// are back — no card appears under a pointer that is busy elsewhere.
    @Published var promptCardOverFullScreen: Bool {
        didSet { defaults.set(promptCardOverFullScreen, forKey: Keys.promptCardOverFullScreen) }
    }

    /// Show a notification modal from the notch when a provider's limit resets.
    @Published var announceUsageReset: Bool {
        didSet { defaults.set(announceUsageReset, forKey: Keys.announceUsageReset) }
    }

    /// Sound an alert alongside the usage reset notification modal.
    @Published var usageResetSound: Bool {
        didSet { defaults.set(usageResetSound, forKey: Keys.usageResetSound) }
    }

    /// Which sound a usage reset notification makes.
    @Published var usageResetSoundName: String {
        didSet { defaults.set(usageResetSoundName, forKey: Keys.usageResetSoundName) }
    }

    /// Show a notification modal from the notch when a provider's session limit is reached.
    @Published var announceSessionLimitReached: Bool {
        didSet { defaults.set(announceSessionLimitReached, forKey: Keys.announceSessionLimitReached) }
    }

    /// Show a notification modal from the notch when a provider's weekly limit is reached.
    @Published var announceWeeklyLimitReached: Bool {
        didSet { defaults.set(announceWeeklyLimitReached, forKey: Keys.announceWeeklyLimitReached) }
    }

    /// Sound an alert alongside the limit reached notification modal.
    @Published var limitReachedSound: Bool {
        didSet { defaults.set(limitReachedSound, forKey: Keys.limitReachedSound) }
    }

    /// Which sound a limit reached notification makes.
    @Published var limitReachedSoundName: String {
        didSet { defaults.set(limitReachedSoundName, forKey: Keys.limitReachedSoundName) }
    }

    /// The ceiling the Gemini API ring fills against, counted in tokens.
    ///
    /// In tokens rather than money because a bare `GEMINI_API_KEY` publishes no
    /// limit of any kind — there is nothing to read, so the ceiling has to come
    /// from the user — and because prices change under the app while a token
    /// stays a token. `nil` means no ceiling, which is the honest default: the
    /// key is billed per token with no cap.
    @Published var geminiAPIMonthlyTokenBudget: Int? {
        didSet {
            if let budget = geminiAPIMonthlyTokenBudget, budget > 0 {
                defaults.set(budget, forKey: Keys.geminiAPIMonthlyTokenBudget)
            } else {
                defaults.removeObject(forKey: Keys.geminiAPIMonthlyTokenBudget)
            }
        }
    }

    /// Which MiniMax console the Coding Plan is read from.
    ///
    /// International and China mainland are different hosts, and a key issued
    /// on one is refused by the other. Absent means never chosen, which is
    /// international.
    @Published var minimaxRegion: MiniMaxRegion {
        didSet { defaults.set(minimaxRegion.rawValue, forKey: Keys.minimaxRegion) }
    }

    /// User-configured custom endpoints — OpenAI-compatible, Anthropic
    /// Messages or Gemini. The key of each lives in the keychain, never here.
    @Published var customEndpoints: [CustomEndpoint] {
        didSet {
            if let data = try? JSONEncoder().encode(customEndpoints) {
                defaults.set(data, forKey: Keys.customEndpoints)
            }
        }
    }

    /// Extra API keys for GLM, MiniMax, Ollama and Apify, each its own ring.
    /// The descriptions only — every key itself lives in the login keychain
    /// (`ExtraKeySecrets`), never here.
    @Published var extraKeys: [ExtraKey] {
        didSet {
            if let data = try? JSONEncoder().encode(extraKeys) {
                defaults.set(data, forKey: Keys.extraKeys)
            }
        }
    }

    /// The version whose changes have already been shown.
    ///
    /// Written when the What's New dialogue is dismissed rather than when it
    /// opens, so a crash in between cannot swallow the one launch it was going
    /// to appear on.
    @Published var lastSeenVersion: String? {
        didSet { defaults.set(lastSeenVersion, forKey: Keys.lastSeenVersion) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != Self.isRegisteredForLogin else { return }
            applyLaunchAtLogin()
        }
    }

    /// Set when the login-item request was refused, so the UI can say so rather
    /// than quietly flipping the switch back.
    @Published private(set) var launchAtLoginProblem: String?

    private let defaults: UserDefaults
    private enum Keys {
        /// The old name. Kept so existing choices survive the rename.
        static let disconnected = "hiddenProviders"
        static let introducedProviders = "introducedProviders"
        static let ollamaEndpoint = "ollamaEndpoint"
        static let lmstudioEndpoint = "lmstudioEndpoint"
        static let introducedOllama = "introducedOllama"
        static let migratedOllamaID = "migratedOllamaLocalID"
        static let ollamaMetricsEnabled = "ollamaMetricsEnabled"
        static let mutedAlerts = "mutedAlertProviders"
        static let thresholdAlerts = "thresholdAlertsEnabled"
        static let hasLaunched = "hasLaunchedBefore"
        static let visibility = "notchVisibility"
        static let presence = "appPresence"
        static let edge = "notchEdge"
        // A new key, so there is nothing under the old app name to migrate.
        static let size = "notchSize"
        static let usesCustomSize = "usesCustomNotchScale"
        static let customSize = "customNotchScale"
        static let display = "notchDisplay"
        static let resetTimeFormat = "resetTimeFormat"
        static let scope = "notchScope"
        static let accentColor = "accentColor"
        // A new key, so there is nothing under the old app name to migrate.
        static let weeklyRing = "weeklyRing"
        static let showsMoveHandle = "showsMoveHandle"
        static let notchSurfaceStyle = "notchSurfaceStyle"
        static let interfaceMode = "interfaceMode"
        static let tourSound = "tourSound"
        static let pillFrost = "pillFrost"
        static let lastSeenVersion = "lastSeenVersion"
        static let order = "providerOrder"
        static let announceSessionEnd = "announceSessionEnd"
        static let sessionEndSound = "sessionEndSound"
        static let peekDuration = "peekDuration"
        static let tooltipSessionLimit = "tooltipSessionLimit"
        static let answerPromptsFromNotch = "answerPromptsFromNotch"
        static let hideIdleSessionsAfterHours = "hideIdleSessionsAfterHours"
        static let sessionEndSoundName = "sessionEndSoundName"
        static let sessionBlockedSoundName = "sessionBlockedSoundName"
        static let promptSound = "promptSound"
        static let cardScale = "cardScale"
        static let approvalSoundName = "approvalSoundName"
        static let questionSoundName = "questionSoundName"
        static let promptReminderMinutes = "promptReminderMinutes"
        static let promptSystemNotification = "promptSystemNotification"
        static let promptCardOverFullScreen = "promptCardOverFullScreen"
        static let announceUsageReset = "announceUsageReset"
        static let usageResetSound = "usageResetSound"
        static let usageResetSoundName = "usageResetSoundName"
        static let announceSessionLimitReached = "announceSessionLimitReached"
        static let announceWeeklyLimitReached = "announceWeeklyLimitReached"
        static let limitReachedSound = "limitReachedSound"
        static let limitReachedSoundName = "limitReachedSoundName"
        /// A new key, so there is nothing under the old app name to migrate.
        static let geminiAPIMonthlyTokenBudget = "geminiAPIMonthlyTokenBudget"
        static let minimaxRegion = "minimaxRegion"
        static let customEndpoints = "customEndpoints"
        static let extraKeys = "extraKeys"
        static let antigravityHeadlineLimit = "antigravityHeadlineLimit"
        static let antigravityHeadlineModel = "antigravityHeadlineModel"
    }

    /// The budget read straight from disk, off the main actor.
    ///
    /// The Gemini API provider is an actor and asks for this on every fetch, and
    /// `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so the provider reads the store, not the object.
    nonisolated static func storedGeminiAPIMonthlyTokenBudget(
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard let budget = defaults.object(forKey: Keys.geminiAPIMonthlyTokenBudget) as? Int,
              budget > 0
        else { return nil }
        return budget
    }
    
    /// The MiniMax region read straight from disk, off the main actor.
    ///
    /// The provider is an actor and asks for this on every fetch, and
    /// `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so the provider reads the store, not the object.
    nonisolated static func storedMinimaxRegion(
        defaults: UserDefaults = .standard
    ) -> MiniMaxRegion {
        guard let value = defaults.string(forKey: Keys.minimaxRegion),
              let region = MiniMaxRegion(rawValue: value)
        else { return .international }
        return region
    }

    /// Moves any key an earlier build left in the defaults plist into the
    /// keychain, once, and writes the list back without it.
    ///
    /// The rewrite is the point. `customEndpoints` is assigned during `init`,
    /// where `didSet` does not run, so without this the plaintext key stayed in
    /// the plist until the user happened to edit that endpoint. Returns the
    /// list with the carried keys cleared, so a later encode cannot put them
    /// back.
    nonisolated static func movingLegacyKeysToKeychain(
        _ list: [CustomEndpoint],
        defaults: UserDefaults
    ) -> [CustomEndpoint] {
        guard list.contains(where: { $0.legacyAPIKey != nil }) else { return list }
        var migrated = list
        for index in migrated.indices {
            guard let legacy = migrated[index].legacyAPIKey else { continue }
            // Only if the keychain has nothing: a key already moved is the newer one.
            if migrated[index].apiKey == nil {
                migrated[index].saveAPIKey(legacy)
            }
            migrated[index].legacyAPIKey = nil
        }
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: Keys.customEndpoints)
        }
        return migrated
    }

    /// Custom endpoints read straight from disk, off the main actor.
    ///
    /// Custom endpoint providers are actors and ask for this on every fetch,
    /// and `@Published` state is main-actor-isolated where `UserDefaults` is
    /// thread-safe — so providers read the store, not the object.
    nonisolated static func storedCustomEndpoints(
        defaults: UserDefaults = .standard
    ) -> [CustomEndpoint] {
        guard let data = defaults.data(forKey: Keys.customEndpoints),
              let endpoints = try? JSONDecoder().decode([CustomEndpoint].self, from: data)
        else { return [] }
        return endpoints
    }

    /// Writes one endpoint back — the provider's sampled readings.
    nonisolated static func updateStoredCustomEndpoint(
        _ endpoint: CustomEndpoint,
        defaults: UserDefaults = .standard
    ) {
        var endpoints = storedCustomEndpoints(defaults: defaults)
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = endpoint
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: Keys.customEndpoints)
        }
    }

    nonisolated static func storedAntigravityHeadlineLimit(
        defaults: UserDefaults = .standard
    ) -> AntigravityHeadlineLimit {
        guard let value = defaults.string(forKey: Keys.antigravityHeadlineLimit),
              let limit = AntigravityHeadlineLimit(rawValue: value)
        else { return .automatic }
        return limit
    }

    nonisolated static func storedAntigravityHeadlineModel(
        defaults: UserDefaults = .standard
    ) -> AntigravityHeadlineModel {
        guard let value = defaults.string(forKey: Keys.antigravityHeadlineModel),
              let model = AntigravityHeadlineModel(rawValue: value)
        else { return .gemini }
        return model
    }

    /// True the very first time this copy runs, and never again.
    ///
    /// Deliberately *not* inferred from "there are no readings yet" — that is
    /// also true of someone who switched every provider off, and re-introducing
    /// them to the app every launch would be worse than never introducing them
    /// at all.
    let isFirstLaunch: Bool

    /// The bundle identifier builds used before launch. A bundle id is the
    /// name of the defaults domain, so moving to `lol.spyx.app` left every
    /// setting behind in the old one — the edge, the accounts switched off,
    /// the size. Copied across once, before anything reads the new domain.
    nonisolated static let previousDomain = "dev.lideffort"

    static func migrateFromPreviousDomain(into defaults: UserDefaults = .standard,
                                          from domain: String = previousDomain) {
        // Only into a domain nothing has used yet: `hasLaunched` is set by
        // `init`, so its absence means this is the first launch under the
        // new name.
        guard defaults.object(forKey: Keys.hasLaunched) == nil,
              let old = UserDefaults.standard.persistentDomain(forName: domain), !old.isEmpty
        else { return }
        for (key, value) in old { defaults.set(value, forKey: key) }
        Log.usage.info("carried \(old.count) settings over from \(domain, privacy: .public)")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isFirstLaunch = !defaults.bool(forKey: Keys.hasLaunched)
        defaults.set(true, forKey: Keys.hasLaunched)
        // Only the earlier local integration used this sentinel. Keep unrelated
        // provider IDs untouched when upgrading from an earlier build.
        if defaults.bool(forKey: Keys.introducedOllama),
           !defaults.bool(forKey: Keys.migratedOllamaID) {
            for key in [Keys.disconnected, Keys.order, Keys.mutedAlerts] {
                var seen = Set<String>()
                let migrated = (defaults.stringArray(forKey: key) ?? []).map { id in
                    if id == "ollama" { return "ollama-local" }
                    if id.hasPrefix("ollama:model:") {
                        return "ollama-local:model:" + id.dropFirst("ollama:model:".count)
                    }
                    return id
                }.filter { seen.insert($0).inserted }
                defaults.set(migrated, forKey: key)
            }
            defaults.set(true, forKey: Keys.migratedOllamaID)
        }
        // A fresh install shows the three coding agents the lid drives and
        // nothing else; everything spyx can read stays one switch away
        // behind the notch's "+" (Settings → Accounts).
        var disconnected = defaults.stringArray(forKey: Keys.disconnected).map(Set.init)
            ?? Preferences.freshDisconnected()
        // Someone updating keeps the list they had — and a provider spyx
        // gained since joins it switched off, rather than appearing on its
        // own as "Not signed in". Each newcomer is introduced once.
        let introduced = Set(defaults.stringArray(forKey: Keys.introducedProviders) ?? [])
        let newcomers = Preferences.introducedLater.subtracting(introduced)
        if !newcomers.isEmpty {
            if defaults.stringArray(forKey: Keys.disconnected) != nil {
                disconnected.formUnion(newcomers)
                defaults.set(Array(disconnected), forKey: Keys.disconnected)
            }
            defaults.set(Array(introduced.union(Preferences.introducedLater)), forKey: Keys.introducedProviders)
        }
        self.disconnectedProviders = disconnected
        self.ollamaMetricsEnabled = defaults.object(forKey: Keys.ollamaMetricsEnabled) as? Bool
            ?? (defaults.bool(forKey: Keys.introducedOllama)
                && !disconnected.contains("ollama-local"))
        self.ollamaEndpoint = (try? OllamaEndpoint.parse(
            defaults.string(forKey: Keys.ollamaEndpoint) ?? OllamaEndpoint.defaultAddress
        ).absoluteString) ?? OllamaEndpoint.defaultAddress
        // A stored choice wins; otherwise LM Studio's own configuration file
        // says where it listens, and 1234 is what it ships with.
        self.lmstudioEndpoint = (try? LMStudioEndpoint.parse(
            defaults.string(forKey: Keys.lmstudioEndpoint)
                ?? LMStudioEndpoint.configuredAddress() ?? LMStudioEndpoint.defaultAddress
        ).absoluteString) ?? LMStudioEndpoint.defaultAddress
        self.mutedAlertProviders = Set(defaults.stringArray(forKey: Keys.mutedAlerts) ?? [])
        self.thresholdAlertsEnabled = defaults.object(forKey: Keys.thresholdAlerts) as? Bool ?? true
        // Absent means never chosen, which is the hover behaviour the app was
        // designed around — not hidden, which would make a fresh install look
        // like it failed to start.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // Absent means never chosen. The Dock is the default because it is the
        // findable one — a new user who cannot see the app anywhere has no way
        // to learn it is running.
        self.appPresence = defaults.string(forKey: Keys.presence)
            .flatMap(AppPresence.init(rawValue:)) ?? .dock
        // The right edge is where the notch has always been, and it is the one
        // side of a Mac that no system chrome claims by default.
        self.notchEdge = defaults.string(forKey: Keys.edge)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        // Medium is the design frame at 1:1, so an install that predates this
        // choice keeps exactly the notch it already had.
        self.notchSize = defaults.string(forKey: Keys.size)
            .flatMap(NotchSize.init(rawValue:)) ?? .medium
        // Absent means never chosen, and the presets are what every earlier
        // version had — so the slider is opt-in rather than the default.
        self.usesCustomNotchScale = defaults.bool(forKey: Keys.usesCustomSize)
        let stored = defaults.object(forKey: Keys.customSize) as? Double
        self.customNotchScale = stored.map {
            min(max($0, Self.customScaleRange.lowerBound), Self.customScaleRange.upperBound)
        } ?? 1
        self.displayPreference = defaults.string(forKey: Keys.display)
            .map(DisplayPreference.display) ?? .followActiveWindow
        self.resetTimeFormat = defaults.string(forKey: Keys.resetTimeFormat)
            .flatMap(ResetTimeFormat.init(rawValue:)) ?? .automatic
        self.showUsagePace = defaults.bool(forKey: Self.showUsagePaceKey)
        // Absent means never chosen. Main display only, because that is what a
        // single-panel setup always did — all-displays on a fresh install
        // would put notches where none were expected.
        self.notchScope = defaults.string(forKey: Keys.scope)
            .flatMap(NotchScreenScope.init(rawValue:)) ?? .mainDisplay
        self.antigravityHeadlineLimit = defaults.string(forKey: Keys.antigravityHeadlineLimit)
            .flatMap(AntigravityHeadlineLimit.init(rawValue:)) ?? .automatic
        self.antigravityHeadlineModel = defaults.string(forKey: Keys.antigravityHeadlineModel)
            .flatMap(AntigravityHeadlineModel.init(rawValue:)) ?? .gemini
        // Follow the Mac unless the user explicitly chooses a spyx colour.
        // Off by default: an extra arc in a 44pt circle is a change to how
        // every reading looks, and nobody asked for it on their behalf.
        self.weeklyRing = defaults.string(forKey: Keys.weeklyRing)
            .flatMap(WeeklyRing.init(rawValue:)) ?? .off
        // On unless turned off: it is how the notch is carried to another edge,
        // and a control that is missing by default is one nobody finds.
        self.showsMoveHandle = defaults.object(forKey: Keys.showsMoveHandle) as? Bool ?? true
        self.accentColor = defaults.string(forKey: Keys.accentColor)
            .flatMap(AccentColorChoice.init(rawValue:)) ?? .system
        self.notchSurfaceStyle = defaults.string(forKey: Keys.notchSurfaceStyle)
            .flatMap(NotchSurfaceStyle.init(rawValue:)) ?? .glass
        // Absent means never switched: start from whatever the Mac is set to.
        self.interfaceMode = defaults.string(forKey: Keys.interfaceMode)
            .flatMap(InterfaceMode.init(rawValue:)) ?? .system
        // The doodle look is gone: the tour is glass only, and its old
        // choice is not kept about.
        defaults.removeObject(forKey: "tourStyle")
        self.tourSound = defaults.object(forKey: Keys.tourSound) as? Bool ?? true
        let frost = defaults.object(forKey: Keys.pillFrost) as? Double ?? Preferences.defaultPillFrost
        self.pillFrost = min(Preferences.pillFrostRange.upperBound, max(Preferences.pillFrostRange.lowerBound, frost))
        // Absent means never chosen, which is follow-the-Mac.
        self.language = defaults.string(forKey: L10n.languageDefaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        // Absent means nothing has been shown yet, which is true of a fresh
        // install — so the current release reads as new to it.
        self.lastSeenVersion = defaults.string(forKey: Keys.lastSeenVersion)
        // Absent means never chosen, so the rings keep the order the app ships
        // with until someone drags one.
        self.providerOrder = defaults.stringArray(forKey: Keys.order) ?? []
        // Both default to on, so `bool(forKey:)` — which answers false for a
        // key that was never written — cannot stand in for the default.
        self.announceSessionEnd = defaults.object(forKey: Keys.announceSessionEnd) as? Bool ?? true
        self.sessionEndSound = defaults.object(forKey: Keys.sessionEndSound) as? Bool ?? true
        self.peekDuration = defaults.string(forKey: Keys.peekDuration)
            .flatMap(PeekDuration.init(rawValue:)) ?? .standard
        self.answerPromptsFromNotch = defaults.object(forKey: Keys.answerPromptsFromNotch) as? Bool ?? true
        let limit = defaults.object(forKey: Keys.tooltipSessionLimit) as? Int ?? Preferences.defaultTooltipSessionLimit
        self.tooltipSessionLimit = min(Preferences.tooltipSessionLimitRange.upperBound,
                                       max(Preferences.tooltipSessionLimitRange.lowerBound, limit))
        let hours = defaults.object(forKey: Keys.hideIdleSessionsAfterHours) as? Int ?? Preferences.defaultHideIdleSessionsAfterHours
        self.hideIdleSessionsAfterHours = Preferences.hideIdleSessionsChoices.contains(hours)
            ? hours : Preferences.defaultHideIdleSessionsAfterHours
        self.sessionEndSoundName = defaults.string(forKey: Keys.sessionEndSoundName)
            ?? SessionChime.defaultFinished
        self.sessionBlockedSoundName = defaults.string(forKey: Keys.sessionBlockedSoundName)
            ?? SessionChime.defaultBlocked
        let cardScale = defaults.object(forKey: Keys.cardScale) as? Double ?? 1
        self.cardScale = min(Preferences.cardScaleRange.upperBound, max(Preferences.cardScaleRange.lowerBound, cardScale))
        self.promptSound = defaults.object(forKey: Keys.promptSound) as? Bool ?? true
        self.approvalSoundName = defaults.string(forKey: Keys.approvalSoundName) ?? SessionChime.defaultBlocked
        self.questionSoundName = defaults.string(forKey: Keys.questionSoundName) ?? SessionChime.defaultQuestion
        let reminder = defaults.object(forKey: Keys.promptReminderMinutes) as? Int ?? 0
        self.promptReminderMinutes = Preferences.promptReminderChoices.contains(reminder) ? reminder : 0
        self.promptSystemNotification = defaults.bool(forKey: Keys.promptSystemNotification)
        self.promptCardOverFullScreen = defaults.object(forKey: Keys.promptCardOverFullScreen) as? Bool ?? true
        self.announceUsageReset = defaults.object(forKey: Keys.announceUsageReset) as? Bool ?? true
        self.usageResetSound = defaults.object(forKey: Keys.usageResetSound) as? Bool ?? true
        self.usageResetSoundName = defaults.string(forKey: Keys.usageResetSoundName)
            ?? SessionChime.defaultFinished
        self.announceSessionLimitReached = defaults.object(forKey: Keys.announceSessionLimitReached) as? Bool ?? true
        self.announceWeeklyLimitReached = defaults.object(forKey: Keys.announceWeeklyLimitReached) as? Bool ?? true
        self.limitReachedSound = defaults.object(forKey: Keys.limitReachedSound) as? Bool ?? true
        self.limitReachedSoundName = defaults.string(forKey: Keys.limitReachedSoundName)
            ?? SessionChime.defaultBlocked
        self.geminiAPIMonthlyTokenBudget = Self.storedGeminiAPIMonthlyTokenBudget(defaults: defaults)
        self.minimaxRegion = Self.storedMinimaxRegion(defaults: defaults)
        if let data = defaults.data(forKey: Keys.customEndpoints),
           let list = try? JSONDecoder().decode([CustomEndpoint].self, from: data) {
            self.customEndpoints = Self.movingLegacyKeysToKeychain(list, defaults: defaults)
        } else {
            self.customEndpoints = []
        }
        self.extraKeys = Self.storedExtraKeys(defaults: defaults)
        // Read from the system rather than from our own store: the user can turn
        // this off in System Settings, and a remembered `true` would then be a lie.
        self.launchAtLogin = Self.isRegisteredForLogin
        // Registered by a copy with another name or place — the app was
        // LidEffort.app before it was spyx.app — the login item still points
        // there. Registering again points it at this copy.
        if launchAtLogin, !Runtime.isUnderTest { try? SMAppService.mainApp.register() }
    }

    // MARK: Custom endpoints

    /// A new endpoint is something the user just asked for, so it starts on.
    func addCustomEndpoint(_ endpoint: CustomEndpoint) {
        customEndpoints.append(endpoint)
        if endpoint.isEnabled {
            setConnected(true, for: endpoint.providerID)
        }
    }

    func updateCustomEndpoint(_ endpoint: CustomEndpoint) {
        guard let idx = customEndpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        var merged = endpoint
        // The provider samples readings into the stored list in the background.
        // When the editor saves with the usage mapping unchanged and the
        // readings untouched, the newer sampled ones win over the ones the
        // editor loaded.
        let storedList = Self.storedCustomEndpoints(defaults: defaults)
        if let stored = storedList.first(where: { $0.id == endpoint.id }) {
            let mappingUnchanged = (stored.usageSource == endpoint.usageSource)
                && (stored.usagePreset == endpoint.usagePreset)
                && (stored.usageURL == endpoint.usageURL)
                && (stored.usageRecordsPath == endpoint.usageRecordsPath)
                && (stored.usageModelField == endpoint.usageModelField)
                && (stored.usageTokenField == endpoint.usageTokenField)
                && (stored.usageModelFilter == endpoint.usageModelFilter)
                && (stored.trackingUnit == endpoint.trackingUnit)
            if mappingUnchanged {
                if merged.currentTokensUsedM == customEndpoints[idx].currentTokensUsedM {
                    merged.currentTokensUsedM = stored.currentTokensUsedM
                }
                if merged.usageHistory == customEndpoints[idx].usageHistory {
                    merged.usageHistory = stored.usageHistory
                }
                if merged.currentSpendUSD == customEndpoints[idx].currentSpendUSD {
                    merged.currentSpendUSD = stored.currentSpendUSD
                }
            }
        }
        customEndpoints[idx] = merged
        setConnected(merged.isEnabled, for: merged.providerID)
    }

    func removeCustomEndpoint(id: String) {
        if let endpoint = customEndpoints.first(where: { $0.id == id }) {
            setConnected(false, for: endpoint.providerID)
            if let filename = endpoint.customIconFilename {
                CustomIconStore.deleteIcon(filename: filename)
            }
        }
        customEndpoints.removeAll { $0.id == id }
    }

    // MARK: Extra keys

    /// The saved list, read straight from disk. Entries that do not describe
    /// a key spyx can read are dropped rather than trusted.
    nonisolated static func storedExtraKeys(defaults: UserDefaults = .standard) -> [ExtraKey] {
        guard let data = defaults.data(forKey: Keys.extraKeys),
              let list = try? JSONDecoder().decode([ExtraKey].self, from: data)
        else { return [] }
        return list.filter { ExtraKey.base(fromProviderID: $0.id) == $0.base }
    }

    /// A key that has just been checked and kept: it starts on, like any
    /// account the person has just asked for.
    func addExtraKey(_ key: ExtraKey) {
        guard !extraKeys.contains(where: { $0.id == key.id }) else { return }
        extraKeys.append(key)
        setConnected(true, for: key.id)
    }

    /// False when the name is empty or already used by another key of the
    /// same provider.
    @discardableResult
    func renameExtraKey(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = extraKeys.firstIndex(where: { $0.id == id }),
              !ExtraKey.isNameTaken(trimmed, base: extraKeys[index].base, in: extraKeys, excluding: id)
        else { return false }
        extraKeys[index].name = trimmed
        return true
    }

    /// Forgets the description and every choice made about its ring. The
    /// keychain item is the caller's to delete — see `ExtraKeySecrets`.
    func removeExtraKey(id: String) {
        extraKeys.removeAll { $0.id == id }
        disconnectedProviders.remove(id)
        mutedAlertProviders.remove(id)
        if providerOrder.contains(id) { providerOrder.removeAll { $0 == id } }
    }

    // MARK: Threshold alerts

    func isMutedAlerts(for providerID: String) -> Bool {
        mutedAlertProviders.contains(providerID)
    }

    func setAlertsMuted(_ muted: Bool, for providerID: String) {
        if muted {
            mutedAlertProviders.insert(providerID)
        } else {
            mutedAlertProviders.remove(providerID)
        }
    }

    func isConnected(_ providerID: String) -> Bool {
        !disconnectedProviders.contains(providerID)
    }

    func setConnected(_ connected: Bool, for providerID: String) {
        if connected {
            disconnectedProviders.remove(providerID)
        } else {
            disconnectedProviders.insert(providerID)
        }
    }

    /// Record a new order, keeping the ids that are not on this Mac today.
    ///
    /// Settings can only show what was discovered at launch, so writing its
    /// list verbatim would quietly forget where a Claude profile sat the moment
    /// its directory was moved away — and put it back at the end when it
    /// returned, for something the user never did.
    func setProviderOrder(_ ids: [String]) {
        providerOrder = ProviderOrder.remember(ids, keeping: providerOrder)
    }

    /// Forget everything this app has stored and quit.
    ///
    /// Deleting an app on macOS leaves `~/Library` untouched, so reinstalling
    /// brings back the old readings, the old connection choices and the old
    /// first-launch flag — which is exactly what makes a reinstall look broken.
    /// Nothing but the app itself can clean that up, so the app has to offer it.
    ///
    /// Not tied to uninstalling: a reinstall is indistinguishable from an
    /// update, and wiping data on every Sparkle update would be catastrophic.
    /// It has to be something the user asks for.
    static func eraseAllData() {
        let bundleID = Bundle.main.bundleIdentifier ?? "lol.spyx.app"
        // The extra keys' items would be orphaned once the list naming them
        // is gone, so they go first, while it can still be read.
        for key in storedExtraKeys() { ExtraKeySecrets.delete(id: key.id) }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        for relative in ["Caches/\(bundleID)",
                         "WebKit/\(bundleID)",
                         "HTTPStorages/\(bundleID)",
                         "HTTPStorages/\(bundleID).binarycookies",
                         "Saved Application State/\(bundleID).savedState"] {
            if let url = library?.appendingPathComponent(relative) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Login item

    static var isRegisteredForLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
        } catch {
            // Commonly refused for an app running from a build directory rather
            // than /Applications, which is worth saying plainly.
            Log.usage.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginProblem = L10n.t("macOS refused this — try moving spyx to /Applications.")
            launchAtLogin = Self.isRegisteredForLogin
        }
    }
}
