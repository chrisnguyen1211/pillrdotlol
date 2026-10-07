import AppKit
import ApplicationServices
import LidEffortCore
import SwiftUI

// Each pane opens with its hero, then groups of rows in the System
// Settings manner: the setting's name on the left with at most one short
// line under it, the control on the right, and anything longer behind an
// ⓘ rather than printed under every switch.

// MARK: - Lid & Effort

struct LidPane: View {
    let effort: EffortController?

    var body: some View {
        if let effort {
            LidPaneContent(effort: effort)
        } else {
            Form {
                Section { PaneHero(section: .lid) }
                Section {
                    Text(L10n.t("The lid module is starting…"))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(NotchFormStyle())
        }
    }
}

private struct LidPaneContent: View {
    @ObservedObject var effort: EffortController
    @State private var targets: [EffortTarget] = []
    @State private var offers: [EffortOffer] = []
    @AppStorage(ClaudeDesktopComposer.defaultsKey) private var typesIntoClaudeDesktop = true
    @AppStorage(AutoEco.defaultsKey) private var autoEco = false
    @State private var accessibilityGranted = AXIsProcessTrusted()

    private var state: EffortState { effort.state }

    var body: some View {
        Form {
            Section {
                PaneHero(section: .lid, trailing: AnyView(sensorPill))
            }

            // No picker here: one level for "every agent" named no agent and
            // no model, and each of them takes something different for it.
            // The lid's place is read-only; the values themselves are in
            // the per-agent rows below, each with its model.
            Section(L10n.t("Lid")) {
                LabeledContent {
                    Text(L10n.t("The agent you're working with"))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: L10n.t("Lid changes"),
                                 subtitle: lastChangeLine,
                                 info: L10n.t("The session in view — a Terminal tab, the Claude app's session — or Codex in front; with none, the agent you changed last. Its own default changes, and its session in view gets it live. Every other agent keeps its level."))
                }

                LabeledContent {
                    HStack(spacing: 6) {
                        Keycap("⌘")
                        Text("+").foregroundStyle(.tertiary)
                        Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    }
                } label: {
                    SettingLabel(title: L10n.t("Lid gesture"),
                                 subtitle: L10n.t("Hold ⌘, move the lid, let go. One level per 7° — open is up."),
                                 info: L10n.t("Without ⌘ the lid is only ever the viewing angle: a stand, a sofa, glare — wherever it stops becomes the new neutral and nothing changes. Past halfway to the next level, it lands on that level when you let go; short of halfway, it falls back. Closing the laptop or sleeping is never read as a push."))
                }

                LabeledContent(L10n.t("Lid angle")) {
                    Text(state.angle.map { "\(Int($0.rounded()))°" } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $autoEco) {
                    SettingLabel(title: L10n.t("Auto-eco"),
                                 subtitle: L10n.t("When an agent is about to run out, step effort down one level."),
                                 info: L10n.t("Once an agent's limit is forecast to run out within 45 minutes, or is 90% used, the level goes down one step — once per reset of that limit, never below low. The effort card says why. The ring's tooltip shows the forecast either way."))
                }
            }

            Section {
                ForEach(targets, id: \.id) { target in
                    let offer = offers.first { $0.id == target.id }
                    Toggle(isOn: Binding(
                        get: { target.enabled },
                        set: { on in
                            EffortTargetWriter.setEnabled(on, for: target.id)
                            refresh()
                        }
                    )) {
                        if let offer, target.enabled {
                            EffortOfferRow(offer: offer, level: state.level)
                        } else {
                            SettingLabel(title: target.displayName, subtitle: detail(for: target))
                        }
                    }
                    .disabled(offer?.installed == false)
                }
            } header: {
                SectionHeader(title: L10n.t("Agents"),
                              info: L10n.t("Each agent's own default config is rewritten — the one line holding the value, nothing else — so it applies to its next session. Each model has its own levels: a level it lacks lands on the nearest one below. The session in view also gets /effort typed in live where its agent takes it — Claude Code and Grok in a terminal, Claude Desktop with Accessibility."))
            }

            Section {
                Toggle(isOn: $typesIntoClaudeDesktop) {
                    SettingLabel(title: L10n.t("Type /effort into Claude Desktop"),
                                 subtitle: L10n.t("Experimental. Only when Claude Desktop is in front, a session is idle and its message box is empty."),
                                 info: L10n.t("Claude Desktop has no terminal to type into, so its sessions otherwise pick the level up next session. With this on, pillr types /effort and Return into the focused, empty message box through Accessibility. Every check is a reason not to type."))
                }
                if typesIntoClaudeDesktop && !accessibilityGranted {
                    LabeledContent {
                        Button(L10n.t("Open Privacy Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    } label: {
                        StatusPill(text: L10n.t("Needs Accessibility access"), color: .orange)
                    }
                }
            } header: {
                Text(L10n.t("Desktop apps"))
            }
        }
        .formStyle(NotchFormStyle())
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    /// "Last: Claude Code → High".
    private var lastChangeLine: String {
        let id = UserDefaults.standard.string(forKey: "effort.lastAgent") ?? "claude"
        let name = targets.first { $0.id == id }?.displayName ?? id.capitalized
        return L10n.t("Last: \(name) → \(state.level.displayName)")
    }

    private var sensorPill: some View {
        state.sensorAvailable
            ? StatusPill(text: L10n.t("Lid sensor on"), color: .green)
            : StatusPill(text: L10n.t("No lid sensor"), color: .gray)
    }

    private func detail(for target: EffortTarget) -> String {
        guard target.enabled else { return L10n.t("Off — \(target.configPath) is left alone") }
        if let value = state.values[target.id] {
            if let model = state.models[target.id], !model.isEmpty { return L10n.t("\(value) for \(model)") }
            return value
        }
        return target.configPath
    }

    private func refresh() {
        targets = EffortTargetWriter.loadTargets()
        offers = EffortOffer.all(targets: targets)
        accessibilityGranted = AXIsProcessTrusted()
    }
}

/// A key as it is drawn on a keyboard.
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

/// A group's header with its ⓘ beside it.
struct SectionHeader: View {
    let title: String
    var info: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let info { InfoButton(text: info) }
        }
    }
}

// MARK: - Notch

/// A new GitHub issue with the version and macOS filled in — nothing else
/// about the Mac — and the crash reports on the clipboard to paste.
enum BugReport {
    static let issues = URL(string: "https://github.com/chrisnguyen1211/pillrdotlol/issues/new")!

    static func url(version: String, macOS: String = ProcessInfo.processInfo.operatingSystemVersionString) -> URL {
        var components = URLComponents(url: issues, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "body", value: "**What happened**\n\n\n**What you expected**\n\n\n---\npillr \(version) · macOS \(macOS)\n"),
        ]
        return components.url ?? issues
    }

    @MainActor
    static func open(version: String) {
        Diagnostics.copyToPasteboard()
        NSWorkspace.shared.open(url(version: version))
    }
}

struct NotchPane: View {
    @ObservedObject var preferences: Preferences
    let displays: [DisplayOption]
    let resetPosition: () -> Void

    /// Where the notch shows, as one choice over the scope and the display.
    enum ShowOn: Hashable { case active, display(String), all }

    private var showOn: Binding<ShowOn> {
        Binding(
            get: {
                if preferences.notchScope == .allDisplays { return .all }
                if case .display(let id) = preferences.displayPreference { return .display(id) }
                return .active
            },
            set: { choice in
                switch choice {
                case .all:
                    preferences.notchScope = .allDisplays
                case .active:
                    preferences.notchScope = .mainDisplay
                    preferences.displayPreference = .followActiveWindow
                case .display(let id):
                    preferences.notchScope = .mainDisplay
                    preferences.displayPreference = .display(id)
                }
            })
    }

    private var showOnExplanation: String {
        switch showOn.wrappedValue {
        case .all: return L10n.t("A notch on every display.")
        case .active: return L10n.t("Moves to the display with the window you are typing in.")
        case .display: return L10n.t("Stays on this display.")
        }
    }

    var body: some View {
        Form {
            Section { PaneHero(section: .notch) }

            Section(L10n.t("Position")) {
                VStack(alignment: .leading, spacing: 10) {
                    SettingLabel(title: L10n.t("Edge"), subtitle: preferences.notchEdge.explanation)
                    EdgePicker(selection: $preferences.notchEdge)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 2)

                // One question — where the notch shows — rather than two rows
                // ("Displays", then "Display") that only made sense together.
                Picker(selection: showOn) {
                    Text(L10n.t("The display you're working on")).tag(ShowOn.active)
                    ForEach(displays) { display in
                        Text(display.name).tag(ShowOn.display(display.id))
                    }
                    if case .display(let id) = preferences.displayPreference,
                       preferences.notchScope == .mainDisplay,
                       !displays.contains(where: { $0.id == id }) {
                        Text(L10n.t("Unavailable display")).tag(ShowOn.display(id))
                    }
                    Text(L10n.t("Every display")).tag(ShowOn.all)
                } label: {
                    SettingLabel(title: L10n.t("Show on"), subtitle: showOnExplanation)
                }

                // There is no slider here on purpose: the notch is moved by
                // ⌥-dragging it, and this row is the one place that gesture is
                // explained, plus the way back to the middle. Recentre only
                // resets the current edge; the others keep their own place.
                LabeledContent {
                    Button(L10n.t("Recentre"), action: resetPosition)
                } label: {
                    SettingLabel(title: L10n.t("Recentre the notch"),
                                 subtitle: L10n.t("Back to the middle of this edge, after ⌥-dragging it."))
                }

                Toggle(isOn: $preferences.showsMoveHandle) {
                    SettingLabel(title: L10n.t("Move handle"),
                                 subtitle: L10n.t("The arc above the open notch. Click it to send the notch round to the next edge."))
                }
            }

            Section(L10n.t("Look")) {
                Picker(selection: $preferences.notchVisibility) {
                    ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(title: L10n.t("Show"), subtitle: preferences.notchVisibility.explanation)
                }

                // Offered only where there is a glass to choose.
                if #available(macOS 26.0, *) {
                    Picker(selection: $preferences.notchSurfaceStyle) {
                        ForEach(NotchSurfaceStyle.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingLabel(title: L10n.t("Surface"), info: preferences.notchSurfaceStyle.explanation)
                    }
                    .pickerStyle(.segmented)

                    if preferences.notchSurfaceStyle == .glass {
                        LabeledContent {
                            HStack(spacing: 8) {
                                // Left is clear, right is frosted: "how much
                                // shows through", against the stored frost.
                                Slider(value: Binding(
                                    get: { 1 - preferences.pillFrost },
                                    set: { preferences.pillFrost = 1 - $0 }
                                ), in: (1 - Preferences.pillFrostRange.upperBound)...(1 - Preferences.pillFrostRange.lowerBound))
                                .frame(width: 180)
                                Text(SettingsView.scalePercent(1 - preferences.pillFrost))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        } label: {
                            SettingLabel(title: L10n.t("Transparency"),
                                         info: L10n.t("How much of the screen shows through the pill, its buttons and the cards. Fully right is nearly bare glass; text on the cards gets harder to read over busy windows."))
                        }
                    }
                }

                LabeledContent {
                    NotchSizeControl(preferences: preferences)
                } label: {
                    SettingLabel(title: L10n.t("Size"),
                                 subtitle: L10n.t("The pill and its rings. Stop on a mark for a preset."))
                }

                LabeledContent {
                    CardSizeControl(preferences: preferences)
                } label: {
                    SettingLabel(title: L10n.t("Tooltip size"),
                                 subtitle: L10n.t("Tooltips, questions and the done card — on their own, apart from the pill."))
                }

                LabeledContent(L10n.t("Accent color")) {
                    HStack(spacing: 2) {
                        ForEach(AccentColorChoice.allCases) { choice in
                            AccentColorSwatch(choice: choice, isSelected: preferences.accentColor == choice) {
                                preferences.accentColor = choice
                            }
                        }
                    }
                }
            }

            Section(L10n.t("Rings")) {
                Picker(selection: $preferences.resetTimeFormat) {
                    ForEach(ResetTimeFormat.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(title: L10n.t("Reset time"), subtitle: preferences.resetTimeFormat.explanation)
                }

                Picker(selection: $preferences.weeklyRing) {
                    ForEach(WeeklyRing.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(title: L10n.t("Weekly ring"), info: preferences.weeklyRing.explanation)
                }

                Toggle(isOn: $preferences.showUsagePace) {
                    SettingLabel(title: L10n.t("Usage pace"),
                                 subtitle: L10n.t("Whether you are ahead of or behind the time left until each limit resets."))
                }
            }
        }
        .formStyle(NotchFormStyle())
    }

}

// MARK: - Sessions & Approvals

struct SessionsPane: View {
    @ObservedObject var preferences: Preferences
    var showNotifications: (() -> Void)? = nil
    @State private var hookInstalled = ClaudeHookInstaller.isInstalled()

    var body: some View {
        Form {
            Section { PaneHero(section: .sessions) }

            Section(L10n.t("Sessions in the tooltip")) {
                LabeledContent {
                    Stepper(value: $preferences.tooltipSessionLimit, in: Preferences.tooltipSessionLimitRange) {
                        Text("\(preferences.tooltipSessionLimit)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    SettingLabel(title: L10n.t("Show at most"),
                                 subtitle: L10n.t("Waiting on you first, then running, then the newest. The rest are counted."))
                }

                Picker(selection: $preferences.hideIdleSessionsAfterHours) {
                    ForEach(Preferences.hideIdleSessionsChoices, id: \.self) { hours in
                        Text(hours == 0 ? L10n.t("Never") : (hours == 1 ? L10n.t("1 hour") : L10n.t("\(hours) hours")))
                            .tag(hours)
                    }
                } label: {
                    SettingLabel(title: L10n.t("Hide idle sessions after"),
                                 subtitle: L10n.t("A terminal left open is not a session anyone is in."))
                }
            }

            Section {
                Toggle(isOn: $preferences.answerPromptsFromNotch) {
                    SettingLabel(title: L10n.t("Answer Claude from the notch"),
                                 subtitle: preferences.answerPromptsFromNotch && !hookInstalled
                                    ? L10n.t("Setting up — the hook goes in once pillr is in Applications.")
                                    : L10n.t("Allow, deny and answer questions in the tooltip or beside the pill."),
                                 info: L10n.t("When a Claude Code session asks to run a tool or asks you a question, the prompt shows under that session in the Claude tooltip and beside the folded pill. It stays until you answer. If you are looking at that session, or switch to it, Claude asks in its own dialog instead. Turning this on adds one hook to ~/.claude/settings.json; turning it off removes it."))
                }
                if preferences.answerPromptsFromNotch {
                    Text(L10n.t("Sessions started before this was switched on pick it up when restarted."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let showNotifications {
                    LabeledContent {
                        Button(L10n.t("Notifications…"), action: showNotifications)
                    } label: {
                        SettingLabel(title: L10n.t("Sounds and alerts"),
                                     subtitle: L10n.t("How a waiting approval or question gets your attention."))
                    }
                }
            } header: {
                Text(L10n.t("Approvals and questions"))
            }
        }
        .formStyle(NotchFormStyle())
        .onAppear { hookInstalled = ClaudeHookInstaller.isInstalled() }
        // The hook is written a moment after the switch moves.
        .onChange(of: preferences.answerPromptsFromNotch) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                hookInstalled = ClaudeHookInstaller.isInstalled()
            }
        }
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @ObservedObject var preferences: Preferences
    var previewResetAlert: (() -> Void)?
    var previewSessionLimitAlert: (() -> Void)?
    var previewWeeklyLimitAlert: (() -> Void)?
    let showAccounts: () -> Void

    var body: some View {
        Form {
            Section { PaneHero(section: .notifications) }

            Section {
                Toggle(isOn: $preferences.promptSound) {
                    SettingLabel(title: L10n.t("Play a sound"),
                                 subtitle: L10n.t("One for a permission, another for a question."))
                }
                SoundRow(label: L10n.t("Approval"), name: $preferences.approvalSoundName,
                         pickerEnabled: preferences.promptSound)
                SoundRow(label: L10n.t("Question"), name: $preferences.questionSoundName,
                         pickerEnabled: preferences.promptSound)
                Picker(selection: $preferences.promptReminderMinutes) {
                    ForEach(Preferences.promptReminderChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? L10n.t("Never")
                             : minutes == 1 ? L10n.t("Every minute") : L10n.t("Every \(minutes) minutes"))
                            .tag(minutes)
                    }
                } label: {
                    SettingLabel(title: L10n.t("Remind me"),
                                 subtitle: L10n.t("The sound again while nobody has answered."))
                }
                .disabled(!preferences.promptSound)

                Toggle(isOn: $preferences.promptSystemNotification) {
                    SettingLabel(title: L10n.t("macOS notification"),
                                 subtitle: L10n.t("Also in Notification Center — for when the notch is hidden or on another display."))
                }

                Picker(selection: $preferences.promptCardOverFullScreen) {
                    Text(L10n.t("Show the card")).tag(true)
                    Text(L10n.t("Sound only")).tag(false)
                } label: {
                    SettingLabel(title: L10n.t("Over full-screen apps"),
                                 info: L10n.t("With Sound only, a prompt that arrives while a game, video or presentation is full screen waits as a sound, and its card comes up when you are back. No card appears under a pointer that is busy elsewhere, so a click meant for the game can never land on Allow."))
                }
            } header: {
                SectionHeader(title: L10n.t("When Claude asks"),
                              info: L10n.t("Approvals and questions answered from the notch — see Sessions & Approvals to switch them on. These say that one is waiting; the card itself stays until it is answered."))
            }

            Section {
                Toggle(isOn: $preferences.announceSessionEnd) {
                    SettingLabel(title: L10n.t("Show a card beside the pill"),
                                 subtitle: L10n.t("Finished, or waiting on you. Click it to jump to the session."),
                                 info: L10n.t("To know the moment a turn ends, pillr adds a small hook of its own to each agent's config. Turning this off takes those hooks out again."))
                }
                Picker(selection: $preferences.peekDuration) {
                    ForEach(PeekDuration.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(title: L10n.t("For"), info: preferences.peekDuration.explanation)
                }
                .disabled(!preferences.announceSessionEnd)

                Toggle(L10n.t("Play a sound"), isOn: $preferences.sessionEndSound)
                SoundRow(label: L10n.t("Finished"), name: $preferences.sessionEndSoundName,
                         pickerEnabled: preferences.sessionEndSound)
                SoundRow(label: L10n.t("Waiting on you"), name: $preferences.sessionBlockedSoundName,
                         pickerEnabled: preferences.sessionEndSound)
            } header: {
                SectionHeader(title: L10n.t("When a session ends"),
                              info: L10n.t("The sound plays on the ordinary output, not the interface sound-effects channel — so it is still heard with \u{201C}Play user interface sound effects\u{201D} switched off in System Settings → Sound."))
            }

            Section(L10n.t("When a limit is reached")) {
                Toggle(L10n.t("Session limit"), isOn: $preferences.announceSessionLimitReached)
                Toggle(L10n.t("Weekly limit"), isOn: $preferences.announceWeeklyLimitReached)
                Toggle(L10n.t("Play a sound"), isOn: $preferences.limitReachedSound)
                SoundRow(label: L10n.t("Alert sound"), name: $preferences.limitReachedSoundName,
                         pickerEnabled: preferences.limitReachedSound)
            }

            Section(L10n.t("When a limit resets")) {
                Toggle(isOn: $preferences.announceUsageReset) {
                    SettingLabel(title: L10n.t("Cheer from the notch"),
                                 subtitle: L10n.t("Not while that provider's weekly limit is still spent."))
                }
                Toggle(L10n.t("Play a sound"), isOn: $preferences.usageResetSound)
                SoundRow(label: L10n.t("Reset sound"), name: $preferences.usageResetSoundName,
                         pickerEnabled: preferences.usageResetSound)
            }

            Section(L10n.t("Threshold alerts")) {
                Toggle(isOn: $preferences.thresholdAlertsEnabled) {
                    SettingLabel(title: L10n.t("At 80% and 100%"),
                                 subtitle: L10n.t("A system notification once per crossing. Mute one provider with the bell on its row in Accounts."))
                }
            }

            Section(L10n.t("End of the day")) {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: DailyRecapScheduler.enabledKey) as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: DailyRecapScheduler.enabledKey) }
                )) {
                    SettingLabel(title: L10n.t("Daily recap"),
                                 subtitle: L10n.t("At 6 pm: sessions, tool calls, tokens and the busiest agent — on days you used them."))
                }
            }
        }
        .formStyle(NotchFormStyle())
    }
}

// MARK: - Local models

struct LocalModelsPane: View {
    @ObservedObject var preferences: Preferences
    let usageStore: UsageStore?
    let ollamaRelay: OllamaActivityRelay?
    let lmstudioMetrics: LMStudioMetrics?

    var body: some View {
        Form {
            Section { PaneHero(section: .localModels) }
            if let usageStore {
                Section("Ollama") {
                    OllamaSettingsRow(preferences: preferences, store: usageStore, relay: ollamaRelay)
                }
                Section("LM Studio") {
                    LMStudioSettingsRow(preferences: preferences, store: usageStore, metrics: lmstudioMetrics)
                }
            }
        }
        .formStyle(NotchFormStyle())
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updater: Updater
    var openSetup: () -> Void = {}
    var openTour: () -> Void = {}
    var quit: () -> Void = {}
    @State private var confirmingRemoval = false
    @State private var removed: [String]?
    var body: some View {
        Form {
            Section { PaneHero(section: .general) }

            Section {
                Toggle(L10n.t("Open pillr at login"), isOn: $preferences.launchAtLogin)
                if let problem = preferences.launchAtLoginProblem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker(selection: $preferences.appPresence) {
                    ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(title: L10n.t("App icon"), info: preferences.appPresence.explanation)
                }
                Picker(selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingLabel(title: L10n.t("Language"), info: preferences.language.explanation)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 })) {
                    SettingLabel(title: L10n.t("Install updates automatically"),
                                 subtitle: L10n.t("Downloaded in the background. pillr asks before it restarts to finish."))
                }
                LabeledContent {
                    if updater.isReadyToInstall {
                        Button(L10n.t("Restart to Update")) { updater.restartToUpdate() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(L10n.t("Check Now")) { updater.checkNow() }
                    }
                } label: {
                    SettingLabel(title: L10n.t("Version \(updater.currentVersion)"),
                                 subtitle: updater.outcome.message)
                }
            } header: {
                Text(L10n.t("Updates"))
            }


            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button(L10n.t("Run Setup Again…"), action: openSetup)
                        Button(L10n.t("Take the Tour"), action: openTour)
                    }
                } label: {
                    SettingLabel(title: L10n.t("Getting started"),
                                 subtitle: L10n.t("The setup assistant and the tour, whenever you want them."))
                }
                LabeledContent {
                    Button(L10n.t("Report a Bug…")) { BugReport.open(version: updater.currentVersion) }
                } label: {
                    SettingLabel(title: L10n.t("Something wrong?"),
                                 subtitle: L10n.t("Opens a new issue on GitHub. Your crash reports are copied, to paste in if you like."))
                }
            } header: {
                Text(L10n.t("Help"))
            }

            Section {
                LabeledContent {
                    Button(L10n.t("Remove…")) { confirmingRemoval = true }
                } label: {
                    SettingLabel(title: L10n.t("Remove pillr from my agents"),
                                 subtitle: removed.map { list in
                                     list.isEmpty ? L10n.t("Nothing was left in any agent. You can move pillr to the Trash.")
                                                  : L10n.t("Removed from \(list.joined(separator: ", ")). You can move pillr to the Trash.")
                                 } ?? L10n.t("Before you delete pillr: takes its hooks out of every agent's config and puts Codex's notify back as it was."))
                }
                if removed != nil {
                    Button(L10n.t("Quit pillr"), action: quit)
                }
            } header: {
                Text(L10n.t("Uninstall"))
            }
            .confirmationDialog(L10n.t("Remove pillr from your agents?"), isPresented: $confirmingRemoval) {
                Button(L10n.t("Remove"), role: .destructive) {
                    removed = AgentHooks.removeEverything()
                }
            } message: {
                Text(L10n.t("Done cards and approvals stop until you turn them on again in Settings."))
            }

            if let notices = Acknowledgements.url {
                Section {
                    Button(L10n.t("Acknowledgements")) { NSWorkspace.shared.open(notices) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
        .formStyle(NotchFormStyle())
    }
}
