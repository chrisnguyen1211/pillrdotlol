import Darwin
import Foundation

/// One agent session, whichever tool it belongs to.
///
/// Deliberately a *display* model rather than a mirror of any one tool's file
/// format: Claude Code publishes a session registry, Cursor keeps composer rows
/// in SQLite, and neither shape belongs in the notch. Each monitor does its own
/// parsing and hands back this.
struct AgentSession: Identifiable, Equatable {
    /// What the session is doing right now.
    enum State: Equatable {
        case busy
        case waiting
        case success
        case idle
    }

    let id: String
    /// What to call it in the tooltip.
    let name: String
    /// The quieter second line — where it is running, or what it is doing.
    let detail: String
    let state: State
    /// Set while `waiting`: what it wants from you.
    let waitingFor: String?
    /// When it entered its current state.
    let since: Date
    /// The agent's own process, when the tool publishes one.
    ///
    /// Only used to find the window it is running in — see `SessionFocus`.
    /// Nil for the tools that report activity from a database or a log file
    /// rather than from a process, and a nil here costs nothing but the ability
    /// to jump to that session.
    let processID: pid_t?
    /// While busy: the step it is on, when its transcript says.
    var doing: Doing? = nil
    /// Tokens it has gone through, as shown ("1.2M tokens") — rounded, so
    /// the session is not republished on every message.
    var tokens: String? = nil
    /// The model it runs now, as an id ("claude-opus-5-5", "grok-4.7"),
    /// and its effort where the agent keeps one per session.
    var model: String? = nil
    var effort: String? = nil
    /// Whatever else its agent records about it, already worded and short —
    /// "+120 −30", "64% context" — shown after the model, the same slot for
    /// every agent.
    var facts: [String] = []

    /// This session with `other`'s model, effort and facts — for a copy
    /// rebuilt with a new state or place, which should not forget them.
    func keepingModel(of other: AgentSession) -> AgentSession {
        var copy = self
        copy.model = other.model
        copy.effort = other.effort
        copy.facts = other.facts
        return copy
    }

    /// Written out rather than synthesised so `processID` can default to nil:
    /// four of the five monitors have no pid to give, and a memberwise
    /// initialiser would have made every one of them say so.
    init(
        id: String,
        name: String,
        detail: String,
        state: State,
        waitingFor: String?,
        since: Date,
        processID: pid_t? = nil,
        doing: Doing? = nil,
        tokens: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.waitingFor = waitingFor
        self.since = since
        self.processID = processID
        self.doing = doing
        self.tokens = tokens
    }
}
