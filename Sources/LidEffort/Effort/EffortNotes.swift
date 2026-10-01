import Foundation

/// What the effort card says when the app in front is Claude's or Codex's
/// own. Those sessions have no terminal to type into, so a change can wait,
/// or not reach them at all — and a card that only said "applies next
/// session" while the app was plainly open read as spyx being broken. Each
/// case gets its reason and what happens next, in one or two lines.
enum EffortNotes {
    struct Note: Equatable {
        let text: String
        let isLive: Bool
        /// The command is still owed: sent the moment the reason goes away.
        var waits = false
    }

    static let codexBundleID = "com.openai.codex"

    /// A Claude app session and what became of the `/effort` typed into it.
    /// `nil` is "not tried": Claude was mid-reply.
    static func claudeApp(_ outcome: ClaudeDesktopComposer.Outcome?, session: String) -> Note {
        guard let outcome else {
            return Note(text: L10n.t("Claude is replying · sends to \(session) when it's done"), isLive: false, waits: true)
        }
        switch outcome {
        case .sent:
            return Note(text: L10n.t("Live → \(session)"), isLive: true)
        case .notFront:
            return Note(text: L10n.t("\(session) · sends when the Claude app is in front"), isLive: false, waits: true)
        case .notTrusted:
            return Note(text: L10n.t("Allow spyx in Accessibility to change Claude app sessions live"), isLive: false)
        case .noComposer:
            return Note(text: L10n.t("Claude app · no message box in view · sends when there is one"), isLive: false, waits: true)
        case .draft, .userTyping:
            return Note(text: L10n.t("Draft in the message box · sends to \(session) once it's empty"), isLive: false, waits: true)
        case .notSent:
            return Note(text: L10n.t("Claude app didn't take /effort · applies next session"), isLive: false)
        }
    }

    /// The Claude app in front, with nothing spyx will type into.
    static func claudeAppUnreached(typingOn: Bool) -> Note {
        typingOn
            ? Note(text: L10n.t("Claude app · no Claude Code session open · applies next session"), isLive: false)
            : Note(text: L10n.t("Claude app · live change is off in Settings · applies next session"), isLive: false)
    }

    /// Codex in front — its app, or its CLI in the Terminal tab in view.
    /// Neither takes a new effort mid-session; new ones start at `value`.
    static func codex(frontBundleID: String?, cliInView: Bool, value: String?) -> Note? {
        if frontBundleID == codexBundleID {
            return Note(text: value.map { L10n.t("Codex app keeps each chat's effort · new chats start at \($0)") }
                            ?? L10n.t("Codex app keeps each chat's effort · applies to new chats"),
                        isLive: false)
        }
        if cliInView {
            return Note(text: L10n.t("Codex CLI can't change a running session · applies next session"), isLive: false)
        }
        return nil
    }

    /// A change that waited — for a turn to end, a draft to clear — and
    /// has now gone in: the card comes back to say so.
    static func delivered(to session: String) -> String {
        L10n.t("Now live → \(session)")
    }
}
