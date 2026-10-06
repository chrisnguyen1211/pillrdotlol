import Foundation
import LidEffortCore

/// What the lid is doing, for the notch and the tooltip.
enum LidState: Equatable {
    case closed, moving, resting
}

/// One running agent session as the effort module sees it — enough to decide
/// whether a live `/effort` can reach it, and whether it is in view.
struct EffortSessionRef: Equatable {
    let pid: pid_t
    /// `ttys006` style, nil for a session with no controlling terminal.
    let tty: String?
    /// The owning app's name as macOS reports it ("Terminal", "Claude").
    let hostName: String?
    let hostBundleID: String?
    /// Which agent runs there — "claude", "grok" — for the command it takes.
    var agent: String = "claude"
}

struct FocusContext: Equatable {
    var frontmostApp: String?
    var focusedTTY: String?
}

/// Decides, without asking, which running sessions a live update should
/// reach. Configs (defaults for *new* sessions) always get the level; touching
/// a session that's already running follows what the person is looking at.
enum AutoScope {
    /// The one session you are working on: the selected Terminal tab, when
    /// it runs one. Nothing else — not the other tabs of the same app, not
    /// every agent that happens to be running. A session you are not
    /// looking at is not the one you meant: it keeps its level, and picks
    /// the new default up when it is next started.
    static func injectTTYs(sessions: [EffortSessionRef], focus: FocusContext) -> Set<String> {
        if let tty = focus.focusedTTY, sessions.contains(where: { $0.tty == tty }) {
            return [tty]
        }
        return []
    }

    /// The app in front, when it hosts sessions a live update cannot reach:
    /// sessions with no terminal of their own — Claude Desktop's, an IDE's
    /// — where nothing can be typed. Nil when nothing is in view, or what
    /// is in view can be reached. What the card says instead of nothing.
    static func unreachableHost(sessions: [EffortSessionRef], focus: FocusContext) -> String? {
        guard let app = focus.frontmostApp else { return nil }
        let inView = sessions.filter { $0.hostName == app }
        guard !inView.isEmpty, inView.allSatisfy({ $0.tty == nil }) else { return nil }
        return app
    }
}

/// What a ring's dots show: how many levels this model has, and how far up
/// them the current value sits (0 = value not on the scale).
struct EffortDotState: Equatable {
    let count: Int
    let filled: Int
    /// The dots, by index, for values only a running session takes —
    /// Claude Code's `max` and `ultracode` — drawn hollow until reached.
    var liveOnly: Set<Int> = []
}

/// The effort module's whole published state.
struct EffortState: Equatable {
    var level: EffortLevel = .medium
    var lid: LidState = .moving
    var angle: Double?
    var sensorAvailable = false
    /// The lid's level while it is still moving, in levels, continuous —
    /// what the bar shows before the level actually changes. Nil at rest.
    var preview: Double?
    /// ⌘ is held: the lid's movement is a gesture, not a viewing angle.
    var armed = false
    /// Target id ("claude", "codex", "grok") → value written for its current model.
    var values: [String: String] = [:]
    /// Target id → model the value was chosen for.
    var models: [String: String] = [:]
    /// Target id → the full ordered scale that model accepts.
    var scales: [String: [String]] = [:]
    /// Target id → the values on that scale only a running session takes.
    var liveOnly: [String: [String]] = [:]
    var lastChange: Date?

    /// The value written for a spyx provider id, which may carry a
    /// profile suffix ("claude-work") the target ids never do.
    func value(forProviderID providerID: String) -> String? {
        values[EffortState.targetID(forProviderID: providerID)]
    }

    func dots(forProviderID providerID: String) -> EffortDotState? {
        let id = EffortState.targetID(forProviderID: providerID)
        guard let value = values[id], let scale = scales[id], !scale.isEmpty else { return nil }
        let filled = scale.firstIndex(of: value).map { $0 + 1 } ?? 0
        let live = Set((liveOnly[id] ?? []).compactMap { scale.firstIndex(of: $0) })
        return EffortDotState(count: scale.count, filled: filled, liveOnly: live)
    }

    static func targetID(forProviderID providerID: String) -> String {
        String(providerID.split(separator: "-").first ?? Substring(providerID))
    }
}

/// The one session a lid change goes to, as the card names it.
struct EffortAim: Equatable {
    /// "claude", "grok", "codex".
    let agent: String
    let session: String
    /// The model it runs, as an id; shown with `ModelName.pretty`.
    let model: String?

    var text: String {
        model.map { "\(session) · \(ModelName.pretty($0))" } ?? session
    }
}

/// Fired once per level change, for the transient card beside the notch.
struct EffortChangeEvent: Equatable, Identifiable {
    let id = UUID()
    let level: EffortLevel
    /// Display name → value, in the order the notch draws them.
    let values: [(name: String, value: String)]
    let at: Date
    /// For one session — the one in view — rather than the defaults new
    /// sessions start with.
    var forSession = false
    /// Not a change: the lid moved without ⌘ held, and the card says how
    /// to make it count. Shown a few times, then never again.
    var isHint = false
    /// What happened to the session in view, when it is not simply "sent":
    /// "Claude · applies next session", or "Claude · typed /effort high".
    var note: String? = nil
    /// Whether the note is good news (typed) or a limit (next session).
    var noteIsLive = false
    /// Not a gesture: why the level moved by itself ("Auto-eco · Claude
    /// near its limit"), said where the card would say "Lid gesture".
    var reason: String? = nil
    /// The agent whose session is in view ("claude", "grok"): the card
    /// comes out of that agent's ring rather than the first one.
    var agent: String? = nil
    /// What the lid is changing, named on the card: the session in view
    /// and the model it runs — or nil, for every agent's next sessions.
    var aim: EffortAim? = nil
    /// A value past the lid's levels typed into the session in view —
    /// `ultracode` — which the card names in place of a level.
    var choice: String? = nil

    static func == (lhs: EffortChangeEvent, rhs: EffortChangeEvent) -> Bool { lhs.id == rhs.id }
}
