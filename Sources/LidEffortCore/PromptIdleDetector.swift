import Foundation

/// Decides whether it's safe to inject a command into a terminal's current
/// input line without corrupting whatever the person is already typing —
/// or queueing it behind a turn that's still running.
public enum PromptIdleDetector {
    /// Claude Code keeps the input line open while a turn runs (typed text
    /// is queued), so an empty `❯` alone doesn't mean idle. These render
    /// only while a turn is in progress.
    /// Grok's composer stays open too; while a turn runs its key hint
    /// offers to queue what you type rather than send it.
    public static let busyMarkers = ["esc to interrupt", "to interrupt", "enter:queue"]

    /// The frame some TUIs draw round their input line — Grok's `│ ❯ │`.
    static let frame = CharacterSet(charactersIn: "│┃|").union(.whitespaces)

    /// Claude Code's ink UI reuses the `❯` marker both for its idle input
    /// prompt and for menu/dialog selections (e.g. `❯ 1. Yes, I trust this
    /// folder`). So the one thing that specifically identifies an idle, safe
    /// -to-inject prompt — as opposed to typed text, an open submenu, a
    /// dialog, a running turn, or a screen we don't recognize at all — is:
    /// no busy marker anywhere, and the *last* `❯` line has nothing after it.
    public static func isIdle(screenText: String) -> Bool { state(screenText: screenText) == .idle }

    /// The input line as the screen shows it.
    public enum State: Equatable {
        /// Empty, and no turn running: safe to type into.
        case idle
        /// No turn running, but something typed is waiting on the line:
        /// someone's draft.
        case draft
        /// A turn running, a menu or dialog open, or a screen not known.
        case busy
    }

    public static func state(screenText: String) -> State {
        let lower = screenText.lowercased()
        if busyMarkers.contains(where: { lower.contains($0) }) { return .busy }
        // A framed input line reads the same once its border is off: Grok
        // draws `│ ❯` where Claude Code draws a bare `❯`.
        let lines = screenText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: frame) }
        guard let index = lines.lastIndex(where: { $0.hasPrefix("❯") }) else { return .busy }
        let afterMarker = String(lines[index].dropFirst("❯".count)).trimmingCharacters(in: frame)
        if afterMarker.isEmpty { return .idle }
        // A numbered choice under the marker is a menu, not a draft.
        if afterMarker.range(of: #"^[0-9]+\. "#, options: .regularExpression) != nil { return .busy }
        // Only the input box itself, drawn under its top rule: a picker's
        // highlighted row (a session in /resume) has the same marker.
        guard index > 0, lines[index - 1].contains("──") else { return .busy }
        return .draft
    }
}
