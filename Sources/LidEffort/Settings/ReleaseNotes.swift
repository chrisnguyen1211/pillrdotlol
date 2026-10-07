import Foundation

/// What one release changed, in the app's own words.
struct ReleaseNote: Equatable {
    /// Matched against `CFBundleShortVersionString`, so it has to be exactly
    /// the string `MARKETING_VERSION` is set to.
    let version: String
    /// One line under the title. What this release is *about*.
    let headline: String
    let changes: [Change]

    /// A title carries the change; the detail is optional, so a small fix can
    /// be a single line rather than a line padded out to match its neighbours.
    struct Change: Equatable {
        let title: String
        let detail: String

        init(title: String, detail: String = "") {
            self.title = title
            self.detail = detail
        }
    }
}

/// The release history the app ships with.
///
/// Written here rather than fetched from the appcast: it has to be there on a
/// first launch with no network, and it belongs to the build it describes.
/// Bumping `MARKETING_VERSION` without adding an entry is caught by
/// `testTheCurrentVersionHasANote`.
enum ReleaseNotes {
    static var all: [ReleaseNote] {
        [
            ReleaseNote(
                version: "1.1.0",
                headline: L10n.t("Every API key has a place — and every agent says when it is done."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Every API key in one cell"),
                        detail: L10n.t("Credit left, spent this month and spent in total, for about 70 providers. The ring follows the key closest to running out.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Reply from the card"),
                        detail: L10n.t("Hover an idle session and answer it. pillr types it in only when the agent is waiting, never over a draft.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Ten agents say when they're done"),
                        detail: L10n.t("Claude Code, Codex, Grok, Cursor, Kimi Code, Gemini CLI, OpenCode, Copilot CLI, Droid and Antigravity.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Connect in one click"),
                        detail: L10n.t("Setup connects each agent, and shows how to install one that isn't on your Mac.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Light, Dark or System"),
                        detail: L10n.t("One icon in Settings — or let pillr follow your Mac.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.2",
                headline: L10n.t("Safer approvals, and a locked-down app."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Read the whole command before you allow it"),
                        detail: L10n.t("A command longer than the card scrolls, and Allow waits until you have seen its last line. Invisible and reordering characters are shown, not hidden.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("pillr's permissions stay pillr's"),
                        detail: L10n.t("The app now runs with macOS's hardened runtime, so no other program can load itself into pillr and use its Accessibility or Terminal access.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Only plain effort values are written"),
                        detail: L10n.t("A value from an agent's model list that is not a plain level is ignored — never written into a config or typed into a session.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.1",
                headline: L10n.t("Live effort in the Claude app, done right."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("The session on screen gets the change"),
                        detail: L10n.t("The card names the Claude app session you are looking at, and /effort goes into that one — even right after you switch.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Works with any input method"),
                        detail: L10n.t("The command is put in whole and checked before it is sent, so Telex or another input method can no longer change it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The card says why a change is waiting"),
                        detail: L10n.t("Claude mid-reply, a draft in the message box, Codex chats that keep their level — and it comes back once the change is live.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.0",
                headline: L10n.t("Your agents' limits, status and effort — on a notch, and a lid."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Hold ⌘ and move the lid to set effort"),
                        detail: L10n.t("Open it a notch and every agent thinks harder; close it a notch and they speed up. Let go of ⌘ to apply.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Every agent's limit at a glance"),
                        detail: L10n.t("A ring per agent shows how much of its limit is used, spins while it works and glows when it waits on you.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Answer questions and approvals from the notch"),
                        detail: L10n.t("See the whole question, what each choice means and the full command, then answer without leaving what you were doing.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Liquid Glass that stays glass"),
                        detail: L10n.t("Over a window it refracts; over the desktop it turns to a clear blur instead of a grey slab.")
                    )
                ]
            )
        ]
    }

    static func note(for version: String) -> ReleaseNote? {
        all.first { $0.version == version }
    }

    /// The note worth showing on this launch, if there is one.
    ///
    /// `notes` is a parameter so the rule can be tested against a fixed history
    /// rather than against whatever the app happens to ship this week.
    static func unseen(in version: String,
                       lastSeen: String?,
                       notes: [ReleaseNote] = ReleaseNotes.all) -> ReleaseNote? {
        guard lastSeen != version else { return nil }
        return notes.first { $0.version == version }
    }
}
