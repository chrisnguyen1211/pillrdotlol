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
                version: "1.2.1",
                headline: L10n.t("The intro tour shows what's new."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Badges in the tour"),
                        detail: L10n.t("The tour now shows a badge arriving on the notch, and where the dashboard is in Settings.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Answered anywhere, said in the tour"),
                        detail: L10n.t("The approvals step says that answering in the terminal or the Claude app takes the card off the notch.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.2.0",
                headline: L10n.t("A dashboard for your agents, at the head of Settings."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("A dashboard in Settings"),
                        detail: L10n.t("Agent time, commits shipped and what the API cost, for today, this week or this month, in widgets over a sky that follows your Mac's clock. Unfold it for everything, or slide it away.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Records, nudges and badges"),
                        detail: L10n.t("pillr cheers when you beat your own best day, week or month, nudges you on a slow week, and gives 48 bronze, silver and gold badges. Your streak catches fire at 10, 50, 100, 150 and 365 days.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Coding plans priced for you"),
                        detail: L10n.t("The plans your agents report are priced from each vendor's own list, so the dashboard counts them without you typing a price.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Answered elsewhere, gone from the notch"),
                        detail: L10n.t("A question or an approval you answer in the terminal or the Claude app now leaves the notch, and its reminder stops.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Easier to read"),
                        detail: L10n.t("Card text stays clear over whatever shows through the glass, in light and in dark.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.1.3",
                headline: L10n.t("Every done card says which session it means."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("The done card names the session"),
                        detail: L10n.t("It shows the session's name or your last message, and the agent's last words, for Claude Code, Codex and the Codex app, Grok, Kimi, Cursor, Gemini CLI, OpenCode, Hermes, Antigravity, Copilot CLI and Droid.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Track one key under a management key"),
                        detail: L10n.t("Paste an OpenRouter, OpenAI, Anthropic, xAI or Exa management key and pick one of the keys under it, or keep the whole account.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Safer keys, said plainly"),
                        detail: L10n.t("Keys that can change things now link straight to where they are made, say how to make them read-only, and say they stay in this Mac's Keychain.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Anthropic personal keys"),
                        detail: L10n.t("A personal key that isn't held to one workspace now reads costs too, and an individual account is told how to get there.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Every word translated"),
                        detail: L10n.t("Sign-ins and the newer settings read in every language, and every Settings control has a name for VoiceOver.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.1.2",
                headline: L10n.t("Opens on every Mac again."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("No more quitting at launch"),
                        detail: L10n.t("1.1.1 closed the moment it opened on most Macs, because it looked for its own languages and icons in the wrong place. It finds them inside the app now.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.1.1",
                headline: L10n.t("Signed by Apple, and sign-ins on your terms."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("Opens with a double-click"),
                        detail: L10n.t("pillr is now signed with a Developer ID and notarized by Apple, so macOS opens it without Open Anyway.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("pillr asks before reading other apps' sign-ins"),
                        detail: L10n.t("Reading Claude Code's and Antigravity's keychain items without a prompt is now a choice in Settings → General → Sign-ins, off by default.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Background Claude renewal can be turned off"),
                        detail: L10n.t("The brief `claude` run that keeps Claude's sign-in fresh has its own switch in Settings → General → Sign-ins.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Every language shows again"),
                        detail: L10n.t("Français, 日本語, Português, Русский and 简体中文 are back in the app.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.1.0",
                headline: L10n.t("Every API key has a place, and every agent says when it is done."),
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
                        detail: L10n.t("One icon in Settings, or let pillr follow your Mac.")
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
                        detail: L10n.t("A value from an agent's model list that is not a plain level is ignored. It is never written into a config or typed into a session.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.1",
                headline: L10n.t("Live effort in the Claude app, done right."),
                changes: [
                    ReleaseNote.Change(
                        title: L10n.t("The session on screen gets the change"),
                        detail: L10n.t("The card names the Claude app session you are looking at, and /effort goes into that one, even right after you switch.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("Works with any input method"),
                        detail: L10n.t("The command is put in whole and checked before it is sent, so Telex or another input method can no longer change it.")
                    ),
                    ReleaseNote.Change(
                        title: L10n.t("The card says why a change is waiting"),
                        detail: L10n.t("Claude mid-reply, a draft in the message box, Codex chats that keep their level. It comes back once the change is live.")
                    )
                ]
            ),
            ReleaseNote(
                version: "1.0.0",
                headline: L10n.t("Your agents' limits, status and effort, on a notch, and a lid."),
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
