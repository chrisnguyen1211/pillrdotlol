import AppKit
import LidEffortCore
import Combine
import Foundation
import OSLog

/// The lid as a step control for reasoning effort. No settings: hold ⌘,
/// push the lid open more than 3.5° and let it rest = one level up (7° per
/// level), push it closed = one level down — or let go of ⌘ and it applies
/// where the lid is. Without ⌘ the lid is only ever the viewing angle;
/// closing the laptop and sleep keep the level too.
/// Every agent's config gets the level; running Claude sessions get it live
/// when they are in view and idle.
///
/// Owns the sensor poll and publishes `EffortState` for the notch. Sessions
/// come from the notch model (the same monitors that drive the activity
/// arcs), so what the lid reaches is exactly what the notch already shows.
@MainActor
final class EffortController: ObservableObject {
    @Published private(set) var state = EffortState()
    /// Fired once per level change, for the transient card.
    var onChange: ((EffortChangeEvent) -> Void)?
    /// Fired while the lid moves, with where it is in levels and the level
    /// it is measured from; nil once it rests. The card's bar follows this
    /// live; the level itself only moves when the lid has stopped.
    var onPreview: ((Double?, EffortLevel, EffortTargetNote?) -> Void)?

    /// What the card says about the session a change would reach.
    struct EffortTargetNote: Equatable {
        let text: String
        let isLive: Bool
        /// The agent whose session is in view — the ring the card comes from.
        var agent: String? = nil
        /// The session it would reach and its model; nil for new sessions only.
        var aim: EffortAim? = nil
    }
    /// Claude sessions the notch currently knows, any profile.
    var claudeSessions: () -> [AgentSession] = { [] }

    private let sensor = LidAngleSensor()
    private var motion = LidMotion(closedBelow: EffortController.closedBelow)
    private var step: StepController
    private var timer: Timer?
    private var suspended = false
    private var wasArmed = false
    private var wakeGraceUntil: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "lol.pillr.app", category: "effort")

    /// Nobody works with the screen under 60°; below it the lid is being shut.
    static let closedBelow: Double = 60
    static let wakeGrace: TimeInterval = 2
    private static let levelKey = "effort.level"
    private static let lastAgentKey = "effort.lastAgent"
    /// The agent this gesture is for, decided when ⌘ went down.
    private var gestureAgent: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Step mode has no absolute reference, so start from the level the
        // world is actually at: what we last applied, else what Claude's
        // settings.json says, else the middle.
        let stored = defaults.string(forKey: EffortController.levelKey)
            .flatMap { name in EffortLevel.allCases.first { $0.description == name } }
        let seeded = stored ?? EffortTargetWriter.claudeConfiguredLevel() ?? .medium
        step = StepController(level: seeded)
        state.level = seeded
        state.sensorAvailable = sensor.read() != nil
        // Show what the configs already say, before any gesture.
        for result in EffortTargetWriter.currentValues() {
            if let value = result.value { state.values[result.targetID] = value }
            if let model = result.model { state.models[result.targetID] = model }
            state.scales[result.targetID] = result.scale
            state.liveOnly[result.targetID] = result.liveOnly
        }
    }

    func start() {
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        // Claude Desktop's accessibility tree, asked for as it comes to the
        // front: Electron builds it a moment later, and a gesture that had
        // to wait for it found no message box the first time.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == ClaudeDesktopComposer.bundleID else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                guard let self, ClaudeDesktopComposer.isEnabled(self.defaults), AXIsProcessTrusted() else { return }
                ClaudeDesktopComposer.prepare(pid: pid)
            }
        })
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == ClaudeDesktopComposer.bundleID,
           ClaudeDesktopComposer.isEnabled(defaults), AXIsProcessTrusted() {
            ClaudeDesktopComposer.prepare(pid: front.processIdentifier)
        }
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        log.notice("effort control ready; \(self.sensor.diagnostic, privacy: .public); level=\(self.state.level.description, privacy: .public)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// The knob on a ring released on a value of that agent's scale.
    ///
    /// The lid's five levels are the only vocabulary every agent shares, so
    /// the value becomes the level whose band lands nearest it, and that
    /// level is applied everywhere exactly as a lid gesture would be — the
    /// knob then settles on what was actually written, which for a value no
    /// band reaches is the neighbour. Where the lid rests now becomes neutral
    /// again, so the next push steps from here rather than from wherever the
    /// last gesture left it.
    ///
    /// A value no lid level types — Claude Code's `ultracode`, past `max` —
    /// is not a level at all: it is typed into the session in view as it
    /// is, and nothing else changes — no config, not the lid's level.
    /// Claude app sessions pillr switched ultracode on in — the app keeps it
    /// on through every /effort level until `/effort ultracode off`.
    private var ultracodeOn: Set<pid_t> = []

    func set(scaleIndex: Int, forTargetID id: String) {
        guard let scale = state.scales[id], scale.indices.contains(scaleIndex) else { return }
        let target = EffortTargetWriter.loadTargets().first { $0.id == id }
        let value = scale[scaleIndex]
        if let target, Self.isLiveChoice(value, agent: id, model: state.models[id], target: target) {
            // In the Claude app ultracode is a switch, and pillr is the one
            // who turned it on: picked again, it is switched off.
            let inView = Self.desktopSessionInView(liveSessions())?.info.pid
            if value == "ultracode", let pid = inView, ultracodeOn.contains(pid) {
                apply(state.level, choice: "ultracode off", agent: id)
            } else {
                apply(state.level, choice: value, agent: id)
            }
            return
        }
        let level = target?.level(reaching: value, model: state.models[id])
            ?? EffortController.proportionalLevel(index: scaleIndex, count: scale.count)
        set(level: level, agent: id)
    }

    /// Whether `value` is one only a live session takes and no lid level
    /// types — `ultracode` — rather than `max`, which the lid's top types.
    static func isLiveChoice(_ value: String, agent: String, model: String?, target: EffortTarget) -> Bool {
        guard target.liveOnly(for: model).contains(value) else { return false }
        let typedByLid = EffortLevel.allCases.compactMap { command(agent: agent, model: model, level: $0, target: target) }
        return !typedByLid.contains("/effort \(value)")
    }

    /// A lid level chosen by hand — the bar on the card let go on it.
    /// A level for one agent — `agent`, or the one being worked with.
    func set(level: EffortLevel, reason: String? = nil, agent: String? = nil) {
        step.set(level: level)
        step.reanchor()
        motion.reset()
        clearPreview()
        apply(level, reason: reason, agent: agent)
    }

    /// One level below where `agent` is now — Auto-eco, for the agent that
    /// is running out, and for nobody else.
    func stepDown(agent: String, reason: String) {
        guard let current = currentLevel(of: agent),
              let lower = EffortLevel(rawValue: current.rawValue - 1) else { return }
        set(level: lower, reason: reason, agent: agent)
    }

    /// The agent the lid is for right now: the session in view (a Terminal
    /// tab, the Claude app's session), else Codex in front, else whichever
    /// app in front runs an agent, else the one the lid last changed.
    func focusAgent() -> String {
        let live = liveSessions()
        let focus = EffortInjector.focus()
        let inView = AutoScope.injectTTYs(sessions: live.map(\.ref), focus: focus)
        if let session = live.first(where: { $0.ref.tty.map(inView.contains) ?? false }) {
            return session.ref.agent
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID {
            return "claude"
        }
        if codexNote(focus: focus, value: nil) != nil { return "codex" }
        if let agent = Self.agentInView(live, focus: focus) { return agent }
        return defaults.string(forKey: EffortController.lastAgentKey) ?? "claude"
    }

    /// The lid level an agent's own config is at now, on its model's scale.
    private func currentLevel(of agent: String) -> EffortLevel? {
        guard let value = state.values[agent],
              let target = EffortTargetWriter.loadTargets().first(where: { $0.id == agent }) else { return nil }
        return target.level(reaching: value, model: state.models[agent])
    }

    /// The lid level at the same fraction of the way up a scale of `count`.
    static func proportionalLevel(index: Int, count: Int) -> EffortLevel {
        let levels = EffortLevel.allCases
        guard count > 1 else { return levels[0] }
        let position = Double(index) / Double(count - 1) * Double(levels.count - 1)
        return levels[min(levels.count - 1, max(0, Int(position.rounded())))]
    }

    // MARK: - Polling

    private func tick() {
        guard !suspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let angle = sensor.read() else {
            if state.sensorAvailable { state.sensorAvailable = false }
            return
        }
        if !state.sensorAvailable { state.sensorAvailable = true }
        // Whole degrees, and only on change: every assignment publishes,
        // and a published state re-renders the notch — five times a second
        // for a reading nothing on screen shows.
        let rounded = angle.rounded()
        if state.angle != rounded { state.angle = rounded }
        guard now >= wakeGraceUntil else { return }

        motion.add(angle: angle, now: now)
        let lid: LidState = motion.isClosed ? .closed : (motion.isResting ? .resting : .moving)
        if state.lid != lid { state.lid = lid }
        // Closed: keep the level, show nothing moving — and forget where
        // the lid last rested. Opening it again is not a push measured from
        // before it was shut: the first rest after it opens is the new
        // neutral, whatever key is held while it comes up.
        guard !motion.isClosed else {
            clearPreview()
            step.reanchor()
            return
        }

        // ⌘ is what makes a movement a gesture. Without it, every push of
        // the lid is the viewing angle — a stand, a sofa, glare — and the
        // only thing to do is follow it as the new neutral. That one key
        // replaces every guess about what the person meant.
        let armed = NSEvent.modifierFlags.contains(.command)
        if state.armed != armed { state.armed = armed }
        // The moment ⌘ goes down is where the gesture starts: travel before
        // it — a lid moved without ⌘, then ⌘ pressed — is not part of it.
        if armed, !wasArmed {
            // The gesture is for one agent — the one being worked with — and
            // starts from where that agent is, so one notch up is one level
            // above its own effort, not above some other agent's.
            let agent = focusAgent()
            gestureAgent = agent
            if let level = currentLevel(of: agent), level != step.level {
                step.set(level: level)
            }
            if step.anchor != nil {
                step.reanchor()
                step.settle(at: angle)
            }
        }
        wasArmed = armed
        guard armed else {
            // ⌘ let go with a push in progress: that is the confirmation, not
            // a cancel — it applies at once, where the lid is, rather than
            // waiting for it to rest. The rest window is for a hand that
            // stays on the key; a hand that leaves it has decided.
            if state.preview != nil {
                clearPreview()
                if step.settle(at: angle) { apply(step.level) }
                return
            }
            if motion.isResting, let rest = motion.restingAngle {
                step.reanchor()
                step.settle(at: rest)
            } else if let travel = step.preview(at: angle),
                      abs(travel - Double(step.level.rawValue)) >= 1 {
                // A level's worth of travel with nothing held: worth saying
                // how, the first few times.
                offerHint()
            }
            return
        }

        // Held: the bar follows the lid, and nothing applies until ⌘ is let
        // go — the release is the commit, the way letting go of a slider
        // is. No rest window: a hand that is still on the key has not
        // decided, however still the lid is.
        //
        // The bar only comes out once the lid has actually moved: ⌘ is
        // pressed for a hundred other things, and a card for every ⌘C was
        // the notch getting in the way. Once out, it follows every reading.
        guard let preview = step.preview(at: angle) else { return }
        let moved = abs(preview - Double(step.level.rawValue)) >= EffortController.previewStartsAt
        if (moved || state.preview != nil), state.preview != preview {
            // Worked out once, as the bar comes out: which session this
            // would reach, so it is known before ⌘ is let go. Looking that
            // up asks Terminal which tab is selected, which is not a thing
            // to do five times a second.
            if state.preview == nil { previewNote = targetNote() }
            state.preview = preview
            onPreview?(preview, step.level, previewNote)
        }
    }

    private var previewNote: EffortTargetNote?

    /// The session a live update would go to right now, named — or why
    /// none would. The commit's own note replaces this with what happened.
    private func targetNote() -> EffortTargetNote {
        let live = liveSessions()
        let focus = EffortInjector.focus()
        let inView = AutoScope.injectTTYs(sessions: live.map(\.ref), focus: focus)
        let reached = live.filter { $0.ref.tty.map(inView.contains) ?? false }
        // The ring of the session that will get it live; only when none
        // will, the agent of whatever is in front.
        let agent = reached.first?.ref.agent ?? Self.agentInView(live, focus: focus)
        let names = reached.map(\.name)
        if !names.isEmpty, let first = reached.first {
            let aim = EffortAim(agent: first.ref.agent, session: first.name,
                                model: first.model ?? state.models[first.ref.agent])
            return EffortTargetNote(text: L10n.t("Live → \(names.joined(separator: ", "))"), isLive: true, agent: agent, aim: aim)
        }
        // The Claude app in front: what letting go will do there.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID {
            let typingOn = ClaudeDesktopComposer.isEnabled(defaults)
            guard typingOn, let desktop = Self.desktopSessionInView(live) else {
                return EffortTargetNote(text: EffortNotes.claudeAppUnreached(typingOn: typingOn).text, isLive: false, agent: agent)
            }
            let note = desktop.info.isIdle
                ? EffortNotes.Note(text: L10n.t("Live → \(desktop.name)"), isLive: true)
                : EffortNotes.claudeApp(nil, session: desktop.name)
            let aim = EffortAim(agent: "claude", session: desktop.name, model: desktop.info.model ?? state.models["claude"])
            return EffortTargetNote(text: note.text, isLive: note.isLive, agent: "claude", aim: aim)
        }
        if let codex = codexNote(focus: focus, value: state.values["codex"]) {
            return EffortTargetNote(text: codex.text, isLive: false, agent: "codex")
        }
        let refs = live.map(\.ref)
        if let host = AutoScope.unreachableHost(sessions: refs, focus: focus) {
            return EffortTargetNote(text: L10n.t("\(host) · applies next session"), isLive: false, agent: agent)
        }
        return EffortTargetNote(text: L10n.t("No session in view · applies next session"), isLive: false, agent: agent)
    }

    /// How far, in levels, the lid has to travel with ⌘ held before the
    /// bar appears: a tenth of a level, under a degree.
    static let previewStartsAt = 0.1

    // MARK: - The hint

    private static let hintCountKey = "effort.hintCount"
    private static let hintLimit = 5
    private var lastHint: TimeInterval = 0

    /// "Hold ⌘ while moving the lid" — on the card, at most five times ever
    /// and never twice inside two minutes. After that the person knows, or
    /// has decided the lid is not for them, and either way the card would
    /// only be noise.
    private func offerHint() {
        let now = ProcessInfo.processInfo.systemUptime
        let shown = defaults.integer(forKey: EffortController.hintCountKey)
        guard shown < EffortController.hintLimit, now - lastHint > 120 else { return }
        lastHint = now
        defaults.set(shown + 1, forKey: EffortController.hintCountKey)
        onChange?(EffortChangeEvent(level: step.level, values: [], at: Date(), isHint: true))
    }

    private func clearPreview() {
        guard state.preview != nil else { return }
        state.preview = nil
        previewNote = nil
        onPreview?(nil, step.level, nil)
    }

    /// `choice`: a value only a live session takes (`ultracode`), typed
    /// into the session in view instead of the level's own — the configs,
    /// the stored level and the lid's level are all left as they are.
    private func apply(_ level: EffortLevel, reason: String? = nil, choice: String? = nil, agent: String? = nil) {
        // One agent: the one named, else the gesture's, else whichever is
        // being worked with now. The others keep their own level.
        let agent = agent ?? gestureAgent ?? focusAgent()
        gestureAgent = nil
        defaults.set(agent, forKey: EffortController.lastAgentKey)
        let results: [EffortTargetWriter.Result]
        if let choice {
            log.notice("live-only choice -> \(choice, privacy: .public)")
            results = EffortTargetWriter.currentValues()
        } else {
            defaults.set(level.description, forKey: EffortController.levelKey)
            log.notice("lid level -> \(level.description, privacy: .public) for \(agent, privacy: .public)")
            // That agent's default for its *next* session; its session in
            // view, if any, gets it live below.
            results = EffortTargetWriter.apply(level: level, only: agent)
        }
        var values: [String: String] = [:]
        var models: [String: String] = [:]
        var scales: [String: [String]] = [:]
        var liveOnly: [String: [String]] = [:]
        for result in results {
            if let value = result.value { values[result.targetID] = value }
            if let model = result.model { models[result.targetID] = model }
            scales[result.targetID] = result.scale
            liveOnly[result.targetID] = result.liveOnly
        }
        if choice == nil {
            state.level = level
            state.values = values
            state.models = models
            state.scales = scales
            state.liveOnly = liveOnly
            state.lastChange = Date()
        }

        // One session only: the one you are looking at — the selected tab of
        // Terminal in front, Claude Code or Grok. The others keep their
        // level. An idle prompt gets it now; one mid-turn gets it when the
        // turn ends (see `retryPending`).
        let sessions = claudeSessions()
        let live = liveSessions()
        let refs = live.map(\.ref)
        let focus = EffortInjector.focus()
        let inView = AutoScope.injectTTYs(sessions: refs, focus: focus)
        let configs = Dictionary(EffortTargetWriter.loadTargets().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inViewSession = live.first { ($0.ref.tty.map(inView.contains) ?? false) && $0.ref.agent == agent }
        let targets = [inViewSession].compactMap { $0 }
            .compactMap { session -> EffortInjector.Target? in
                // The value for the model this session is running — which
                // need not be the config's default — else the config's.
                let model = session.model ?? models[session.ref.agent]
                guard let command = Self.command(agent: session.ref.agent, model: model, level: level,
                                                 target: configs[session.ref.agent], choice: choice) else { return nil }
                return EffortInjector.Target(session: session.ref, command: command)
            }
        // In view, but its model has no effort to set.
        let noEffort: EffortAim? = targets.isEmpty ? inViewSession.map {
            EffortAim(agent: $0.ref.agent, session: $0.name, model: $0.model ?? models[$0.ref.agent])
        } : nil
        func name(of pid: pid_t) -> String {
            live.first { $0.ref.pid == pid }?.name ?? "pid \(pid)"
        }
        let attempts = EffortInjector.inject(targets)
        pending = [:]
        pendingDesktop = nil
        for attempt in attempts where attempt.outcome != .sent {
            log.notice("live inject skipped pid \(attempt.pid, privacy: .public): \(String(describing: attempt.outcome), privacy: .public)")
            if attempt.outcome == .promptNotIdle, let target = targets.first(where: { $0.session.pid == attempt.pid }) {
                pending[attempt.pid] = PendingLive(target: target, name: name(of: attempt.pid), level: choice == nil ? level : .max,
                                                   until: Date().addingTimeInterval(Self.pendingFor))
            }
        }
        schedulePendingRetry()

        // The card names the session that got it live — there are several
        // running, and "applied" without a name says nothing. Or says why
        // none did: the one in view is busy, has no terminal to type into
        // (Claude Desktop's), or nothing is in view at all.
        var note: String?
        var noteIsLive = false
        // The one session this change is for, and the command it gets —
        // what the card names instead of every agent's new default.
        var liveCommand: (agent: String, command: String)? = targets.first.map { ($0.session.agent, $0.command) }
        var codexInView = false
        // Which session, and on which model, the card names.
        var aim: EffortAim? = targets.first.flatMap { target in
            live.first { $0.ref.pid == target.session.pid }.map { session in
                EffortAim(agent: session.ref.agent, session: session.name, model: session.model ?? models[session.ref.agent])
            }
        }
        let sent = attempts.filter { $0.outcome == .sent }.map { name(of: $0.pid) }
        var namesWithoutLive = noEffort != nil
        if let noEffort {
            note = choice.map { L10n.t("\(noEffort.text) · no \($0) on this model") }
                ?? L10n.t("\(noEffort.text) · this model has no effort level")
            aim = noEffort
        } else if !sent.isEmpty {
            note = L10n.t("Live → \(sent.joined(separator: ", "))")
            noteIsLive = true
        } else if let attempt = attempts.first(where: { $0.outcome == .promptNotIdle }) ?? attempts.first {
            note = L10n.t("\(name(of: attempt.pid)) · busy · applies next turn")
        } else if agent == "claude", let desktop = Self.desktopSessionInView(live),
                  ClaudeDesktopComposer.isEnabled(defaults) {
            // Claude Desktop in front: the session it is showing. Desktop
            // takes `/effort` in its composer; its stdin is its own, so this
            // is the one way in. Idle and the composer empty, now; otherwise
            // as soon as it is (see `retryPending`). The card says which,
            // and why not yet: in an app you are looking at, a change that
            // silently waits looks like one that failed.
            let desktopModel = desktop.info.model ?? models["claude"]
            aim = EffortAim(agent: "claude", session: desktop.name, model: desktopModel)
            if let command = Self.command(agent: "claude", model: desktopModel, level: level, target: configs["claude"], choice: choice) {
                liveCommand = ("claude", command)
                let outcome = desktop.info.isIdle ? ClaudeDesktopComposer.type(command: command) : nil
                let desktopNote = EffortNotes.claudeApp(outcome, session: desktop.name)
                note = desktopNote.text
                noteIsLive = desktopNote.isLive
                if let choice, outcome == .notSent {
                    // Nothing was written anywhere: "next session" would be untrue.
                    note = L10n.t("Claude app didn't take /effort \(choice) · nothing was sent")
                }
                // The Claude app keeps ultracode on through any /effort level
                // until told otherwise: remembered, so the card can say so and
                // picking it again switches it off.
                if outcome == .sent {
                    if choice == "ultracode" { ultracodeOn.insert(desktop.info.pid) }
                    if choice == "ultracode off" { ultracodeOn.remove(desktop.info.pid) }
                }
                if choice == nil, ultracodeOn.contains(desktop.info.pid), let current = note {
                    note = L10n.t("\(current) · ultracode is still on. Pick it again in the ring's tooltip to switch it off")
                }
                if desktopNote.waits {
                    pendingDesktop = PendingDesktop(pid: desktop.info.pid, command: command, name: desktop.name,
                                                    level: choice == nil ? level : .max, until: Date().addingTimeInterval(Self.pendingFor))
                    schedulePendingRetry()
                }
            } else {
                note = choice.map { L10n.t("\(aim?.text ?? desktop.name) · no \($0) on this model") }
                    ?? L10n.t("\(aim?.text ?? desktop.name) · this model has no effort level")
                namesWithoutLive = true
            }
        } else if let choice {
            // Nothing in view to type it into, and no config to fall back
            // on: every "applies next session" below would be untrue. With the
            // Claude app in front, the reason is the switch in Settings.
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID,
               !ClaudeDesktopComposer.isEnabled(defaults) {
                note = L10n.t("Typing into the Claude app is off in Settings · \(choice) was not sent")
            } else {
                note = L10n.t("No Claude Code session in view · \(choice) is only typed live, nothing was sent")
            }
        } else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID {
            note = EffortNotes.claudeAppUnreached(typingOn: ClaudeDesktopComposer.isEnabled(defaults)).text
        } else if let codex = codexNote(focus: focus, value: values["codex"]) {
            note = codex.text
            codexInView = true
        } else if let superset = supersetLive(level: level, values: values, sessions: sessions, results: results) {
            note = superset
        } else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal",
                  !EffortInjector.terminalAllowed {
            note = L10n.t("Terminal · allow pillr in Setup → Terminals to apply it live")
        } else if let host = AutoScope.unreachableHost(sessions: refs, focus: focus) {
            note = L10n.t("\(host) · applies next session")
        } else {
            // No session of its own in view: its default, said by name.
            let name = results.first { $0.targetID == agent }?.displayName ?? agent.capitalized
            note = L10n.t("\(name) · applies next session")
        }

        // A session in view: the card names it and the value it got. None:
        // every agent's new default, which is what changed.
        // Every agent's new default, with the model it is for.
        let allDefaults = results.compactMap { result in
            result.value.map { value in
                (name: result.model.map { model -> String in
                    // "Grok (4.7)", not "Grok (Grok 4.7)".
                    let pretty = ModelName.pretty(model)
                    let short = pretty.hasPrefix(result.displayName + " ") ? String(pretty.dropFirst(result.displayName.count + 1)) : pretty
                    return "\(result.displayName) (\(short))"
                } ?? result.displayName, value: value)
            }
        }
        let shown: [(name: String, value: String)]
        if let live = liveCommand, let target = results.first(where: { $0.targetID == live.agent }) {
            shown = [(target.displayName, String(live.command.dropFirst("/effort ".count)))]
        } else {
            // Only the agent the lid was for: the others did not change.
            let mine = results.first { $0.targetID == agent }.map(\.displayName)
            shown = allDefaults.filter { entry in mine.map { entry.name.hasPrefix($0) } ?? false }
        }
        onChange?(EffortChangeEvent(
            // A choice past the lid's levels sits at the bar's top.
            level: choice == nil ? level : .max,
            values: shown,
            at: Date(),
            forSession: liveCommand != nil,
            note: note,
            noteIsLive: noteIsLive,
            reason: choice.flatMap(EffortNotes.choiceDetail) ?? reason,
            // The card comes out of the ring of a session that took the new
            // level — Grok's, when Grok's session got it — not of whichever
            // app happened to be in front. Only when none took it live does
            // the app in view decide.
            agent: codexInView ? "codex" : Self.cardAgent(attempts: attempts, live: live, focus: focus),
            aim: liveCommand == nil && !namesWithoutLive ? nil : aim,
            choice: choice
        ))
    }

    /// Codex in front — the app, or the CLI in the selected Terminal tab —
    /// where a running session keeps its effort; the card says so rather
    /// than "no session in view" over a session plainly in view.
    private func codexNote(focus: FocusContext, value: String?) -> EffortNotes.Note? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let cliInView = focus.focusedTTY.map { tty in
            EffortInjector.terminalSessions(agents: ["codex"]).contains { $0.tty == tty }
        } ?? false
        return EffortNotes.codex(frontBundleID: front, cliInView: cliInView, value: value)
    }

    // MARK: - Live sessions

    /// A running session a live update could reach, with the name the card
    /// uses for it.
    struct LiveSession {
        let ref: EffortSessionRef
        let name: String
        /// The model the session is running now, when it can be read.
        var model: String? = nil
    }

    /// Claude Code and Grok running in a terminal, from the process table —
    /// every tab and window, not only the Claude sessions the notch lists —
    /// plus Claude's own sessions without a terminal (Claude Desktop's), so
    /// the card can say why those wait for their next session.
    private func liveSessions() -> [LiveSession] {
        let fleet = claudeSessions()
        let grokModels = SessionModels.grok()
        var result: [LiveSession] = []
        var seen = Set<pid_t>()
        for found in EffortInjector.terminalSessions() {
            let app = SessionFocus.owningApp(of: found.pid)
            let ref = EffortSessionRef(pid: found.pid, tty: found.tty, hostName: app?.localizedName,
                                       hostBundleID: app?.bundleIdentifier, agent: found.agent)
            let name = fleet.first { $0.processID == found.pid }?.name
                ?? (found.agent == "grok" ? "Grok" : "Claude Code")
            let model = found.agent == "grok" ? grokModels[found.pid] : SessionModels.claude(pid: found.pid)
            result.append(LiveSession(ref: ref, name: name, model: model))
            seen.insert(found.pid)
        }
        for session in fleet {
            guard let pid = session.processID, !seen.contains(pid), let ref = EffortController.ref(for: session) else { continue }
            result.append(LiveSession(ref: ref, name: session.name))
        }
        return result
    }

    /// What to type into a session of `agent` running `model`: the value
    /// that model's scale gives this level. Claude Code's top band is `max`
    /// live, on a model that has it — its CLI takes it; only settings.json
    /// drops it to `xhigh`. Nil for a model that takes no effort level
    /// (Haiku 4.5): nothing is typed into it.
    ///
    /// `choice`, a value only a live session takes (`ultracode`), is typed
    /// as it is in place of the level's — and only into a model whose scale
    /// has it: nil for another agent, or an older Claude model.
    static func command(agent: String, model: String?, level: EffortLevel, target: EffortTarget?,
                        choice: String? = nil) -> String? {
        if let choice {
            if choice == "ultracode off", agent == "claude" { return "/effort ultracode off" }
            guard let target, target.id == agent, target.liveOnly(for: model).contains(choice) else { return nil }
            return "/effort \(choice)"
        }
        guard let target else { return "/effort \(level.description)" }
        guard let value = target.value(for: level, model: model) else { return nil }
        if agent == "claude", level == .max, target.liveOnly(for: model).contains("max") { return "/effort max" }
        return "/effort \(value)"
    }

    /// Which ring the change card comes out of: the agent of the first
    /// session that got it live (the one in view is tried first), then of a
    /// session waiting for its turn to end, then of whatever is in front.
    static func cardAgent(attempts: [EffortInjector.Attempt], live: [LiveSession], focus: FocusContext) -> String? {
        func agent(_ attempt: EffortInjector.Attempt?) -> String? {
            attempt.flatMap { attempt in live.first { $0.ref.pid == attempt.pid }?.ref.agent }
        }
        return agent(attempts.first { $0.outcome == .sent })
            ?? agent(attempts.first { $0.outcome == .promptNotIdle })
            ?? agentInView(live, focus: focus)
    }

    /// The agent whose session you are looking at: the selected Terminal
    /// tab's, or Claude's when Claude Desktop is in front with a session.
    static func agentInView(_ live: [LiveSession], focus: FocusContext) -> String? {
        if let tty = focus.focusedTTY, let session = live.first(where: { $0.ref.tty == tty }) {
            return session.ref.agent
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID,
           live.contains(where: { $0.ref.agent == "claude" && $0.ref.tty == nil }) {
            return "claude"
        }
        return nil
    }

    // MARK: - Waiting for a turn to end

    private struct PendingLive {
        var target: EffortInjector.Target
        /// For the card that comes back once it has gone in.
        let name: String
        let level: EffortLevel
        let until: Date
    }

    /// The Claude Desktop session in view, owed a `/effort` it could not
    /// take yet: mid-turn, or its composer not empty.
    private struct PendingDesktop {
        let pid: pid_t
        let command: String
        let name: String
        let level: EffortLevel
        let until: Date
    }
    private var pendingDesktop: PendingDesktop?

    /// Claude's sessions without a terminal — Claude Desktop's — as live
    /// sessions, without walking the process table for the terminal ones.
    private func desktopSessions() -> [LiveSession] {
        claudeSessions().compactMap { session in
            Self.ref(for: session).map { LiveSession(ref: $0, name: session.name) }
        }
    }

    /// A change that waited has gone in: the card comes back to say so,
    /// from the ring of the agent that took it, naming the value it got.
    private func delivered(_ command: String, agent: String, name: String, level: EffortLevel) {
        let display = EffortTargetWriter.loadTargets().first { $0.id == agent }?.displayName ?? name
        let value = String(command.dropFirst("/effort ".count))
        // A choice past the levels (`ultracode`) comes back named as itself.
        let detail = EffortNotes.choiceDetail(value)
        onChange?(EffortChangeEvent(level: level,
                                    values: [(display, value)],
                                    at: Date(), forSession: true,
                                    note: EffortNotes.delivered(to: name), noteIsLive: true,
                                    reason: detail, agent: agent,
                                    aim: EffortAim(agent: agent, session: name, model: nil),
                                    choice: detail == nil ? nil : value))
    }

    /// The session Claude Desktop is showing, when Desktop is in front: the
    /// one its window has open, read from the window. Only when the window
    /// cannot be read, the one Desktop's records say was focused last.
    static func desktopSessionInView(_ live: [LiveSession]) -> (info: SessionModels.DesktopSession, name: String)? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID else { return nil }
        let known = live.filter { $0.ref.tty == nil && $0.ref.hostBundleID == ClaudeDesktopComposer.bundleID }
            .compactMap { session in SessionModels.desktop(pid: session.ref.pid).map { ($0, session.name) } }
        switch ClaudeDesktopComposer.view() {
        case .session(let id):
            if let match = known.first(where: { $0.0.hostSessionID == id }) { return match }
            return SessionModels.desktop(hostSessionID: id).map { ($0, $0.title ?? "Claude Code") }
        case .noSession:
            return nil
        case .unknown:
            return known.max { $0.0.lastFocusedAt < $1.0.lastFocusedAt }
        }
    }

    /// Sessions that were mid-turn when the level changed, by pid. Replaced
    /// wholesale by the next change — only the latest level is owed.
    private var pending: [pid_t: PendingLive] = [:]
    private var pendingTimer: Timer?
    /// Long enough for a long turn; not so long that a level from an hour
    /// ago lands in a session that has moved on.
    static let pendingFor: TimeInterval = 10 * 60
    static let pendingEvery: TimeInterval = 3

    private func schedulePendingRetry() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        guard !pending.isEmpty || pendingDesktop != nil else { return }
        let timer = Timer(timeInterval: Self.pendingEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryPending() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingTimer = timer
    }

    private func retryPending() {
        guard !suspended else { return }
        let now = Date()
        // Gone, or waited long enough: dropped, not typed.
        pending = pending.filter { pid, entry in entry.until > now && kill(pid, 0) == 0 }
        let attempts = EffortInjector.inject(pending.values.map(\.target))
        for attempt in attempts {
            switch attempt.outcome {
            case .sent:
                if let sent = pending[attempt.pid] {
                    delivered(sent.target.command, agent: sent.target.session.agent, name: sent.name, level: sent.level)
                }
                pending[attempt.pid] = nil
            case .promptNotIdle:
                break
            default:
                // The tab closed or its contents can't be read: nothing to wait for.
                log.notice("live retry dropped pid \(attempt.pid, privacy: .public): \(String(describing: attempt.outcome), privacy: .public)")
                pending[attempt.pid] = nil
            }
        }
        if let owed = pendingDesktop {
            if owed.until <= now || kill(owed.pid, 0) != 0 {
                pendingDesktop = nil
            } else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopComposer.bundleID,
                      SessionModels.desktop(pid: owed.pid)?.isIdle == true,
                      // Still the session it was meant for: the composer in
                      // view belongs to whichever session Desktop shows now.
                      Self.desktopSessionInView(desktopSessions())?.info.pid == owed.pid {
                switch ClaudeDesktopComposer.type(command: owed.command, askForTrust: false) {
                case .sent:
                    log.notice("live \(owed.command, privacy: .public) -> Claude Desktop pid \(owed.pid, privacy: .public)")
                    pendingDesktop = nil
                    delivered(owed.command, agent: "claude", name: owed.name, level: owed.level)
                case .notTrusted, .notSent:
                    // Waiting will not change these.
                    pendingDesktop = nil
                default:
                    break
                }
            }
        }
        if pending.isEmpty, pendingDesktop == nil {
            pendingTimer?.invalidate()
            pendingTimer = nil
        }
    }

    /// The Superset pane you are looking at, when Superset is in front: its
    /// session gets `/effort` typed through Superset's host service if it is
    /// on the new terminal stack and idle. The card says so, then says how it
    /// went — the send is a network call, so the answer comes a moment later.
    private func supersetLive(level: EffortLevel, values: [String: String],
                              sessions: [AgentSession], results: [EffortTargetWriter.Result]) -> String? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == Superset.bundleID else { return nil }
        guard let (session, place) = sessions.lazy.compactMap({ session -> (AgentSession, Superset.Place)? in
            guard let pid = session.processID, let place = Superset.place(of: pid) else { return nil }
            return (session, place)
        }).first(where: { Superset.isInView($0.1, frontmostBundleID: front) }) else {
            return L10n.t("Superset · no Claude session in view · applies next session")
        }
        guard case .v2 = place.stack else {
            return L10n.t("\(session.name) · Superset · applies next session")
        }
        guard session.state == .idle else {
            return L10n.t("\(session.name) · busy · applies next turn")
        }
        guard let value = values["claude"] else { return nil }
        let eventValues = results.compactMap { result in result.value.map { (result.displayName, $0) } }
        Task { @MainActor [weak self] in
            let outcome = await Superset.send("/effort \(value)", to: place)
            let note: String
            switch outcome {
            case .sent: note = L10n.t("Live → \(session.name) (Superset)")
            case .noHost: note = L10n.t("\(session.name) · Superset is closed · applies next session")
            case .notV2: note = L10n.t("\(session.name) · Superset · applies next session")
            case .failed: note = L10n.t("\(session.name) · Superset refused · applies next session")
            }
            self?.onChange?(EffortChangeEvent(level: level, values: eventValues, at: Date(),
                                              note: note, noteIsLive: outcome == .sent))
        }
        return L10n.t("Sending to \(session.name) in Superset…")
    }

    /// A notch session, located: its tty and the app that owns it, via the
    /// same process-tree walk `SessionFocus` uses to raise a session's window.
    static func ref(for session: AgentSession) -> EffortSessionRef? {
        guard let pid = session.processID else { return nil }
        let app = SessionFocus.owningApp(of: pid)
        return EffortSessionRef(pid: pid, tty: SessionFocus.tty(of: pid),
                                hostName: app?.localizedName, hostBundleID: app?.bundleIdentifier)
    }

    // MARK: - Sleep / wake

    private func willSleep() {
        suspended = true
        motion.reset()
    }

    private func didWake() {
        suspended = false
        // The lid is being opened right now; let it come to rest before
        // reading anything, and don't count the opening as a push.
        wakeGraceUntil = ProcessInfo.processInfo.systemUptime + EffortController.wakeGrace
        motion.reset()
        step.reanchor()
    }
}
