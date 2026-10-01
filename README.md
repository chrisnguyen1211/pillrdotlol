# spyx

A macOS app that pins a small notch to a screen edge showing, for each coding
agent, how much of its usage limit you've burned, whether it's still working
— and the **reasoning effort** it's set to, which you change by pushing the
laptop lid. Open the lid a notch: every agent steps up a level. Close it a
notch: down. No settings for that; it works out what you meant.

## The lid

**The gesture** ([Sources/LidEffortCore/StepController.swift](Sources/LidEffortCore/StepController.swift),
[EffortController.swift](Sources/LidEffort/Effort/EffortController.swift)):
**hold ⌘**, move the lid, **let go**. One level per 7° of travel from
where the lid was when ⌘ went down — open is up, closed is down — and the
release is the commit, the way letting go of a slider is: it lands on
whichever level the lid is nearer (past halfway, more than 3.5°, goes on;
at or short of halfway falls back). No waiting for the lid to settle — a
hand still on the key has not decided, however still the lid is.

Without ⌘ the lid is only ever the viewing angle: a stand, a sofa, glare —
wherever it stops becomes the new neutral and nothing changes. That one key
replaces every guess about what a movement meant. The first few times the
lid travels a level's worth with nothing held, the card says so ("Hold ⌘ to
change effort"), then stops mentioning it.

**What it also ignores** ([LidMotion.swift](Sources/LidEffortCore/LidMotion.swift)):
closing the laptop (below 60° the level holds, and the lid's neutral is
forgotten — opening it again is never a push), and sleep (suspended; the
first 2 s after wake are ignored).

**Where the level goes** ([EffortTargetWriter.swift](Sources/LidEffort/Effort/EffortTargetWriter.swift),
[EffortTarget.swift](Sources/LidEffortCore/EffortTarget.swift)): every
agent's default config, each on its own per-model scale — defaults for the
*next* session:

| Agent | Config | Accepted scale |
|---|---|---|
| Claude Code | `~/.claude/settings.json` → `effortLevel` | `low medium high xhigh` (`max` is dropped by the settings schema; the top two lid levels both write `xhigh`) |
| Codex | `~/.codex/config.toml` → `model_reasoning_effort` | per model, from `~/.codex/models_cache.json` |
| Grok | `~/.grok/config.toml` → `[models] default_reasoning_effort` | `low … max` |

Only the one line holding the value is rewritten.

**The session in view gets it live** — one session, the one you are looking
at; the others keep their level until they next start
([EffortController.swift](Sources/LidEffort/Effort/EffortController.swift)):

- **Claude Code and Grok in Terminal.app** — the selected tab gets
  `/effort <value>` typed in, the value its *running model* takes
  ([EffortInjector.swift](Sources/LidEffort/Effort/EffortInjector.swift)),
  only when its prompt is empty. Mid-turn, it goes in when the turn ends.
- **The Claude app's Claude Code sessions** — with Accessibility allowed,
  spyx types `/effort <value>` and Return into the message box of the
  session on screen, and checks the box emptied
  ([ClaudeDesktopComposer.swift](Sources/LidEffort/Effort/ClaudeDesktopComposer.swift)).
  It never types into a draft: while Claude is replying or the box has text
  in it, the command waits (up to 10 minutes) and goes in once it can.
  Settings → Lid turns it off.
- **Superset** — typed into the pane in view through Superset's own host
  service, when the session is idle.
- **Codex** — its app and CLI keep a running chat's level; new chats start
  at the new one.

The card always says which: "Live → *session*", or why not yet and what
happens next ("Claude is replying · sends to *session* when it's done",
"Draft in the message box · …", "Codex app keeps each chat's effort · …").
A change that waited brings the card back once it is live ("Now live →
*session*").

**Superset** ([Superset.swift](Sources/LidEffort/Sessions/Superset.swift)):
a Claude session running in a Superset pane is found from the environment
Superset gives the pane, named by its workspace and branch, and a click on
it opens that very workspace and terminal through Superset's own
`superset://` link. Superset's databases are only ever read.

**In the notch:** each ring the lid drives is a gauge, and the dots in the
opening at its foot are that model's scale, filled to its value. The bar
lives in the two cards: the change card's bar **follows the lid live** while
it moves with ⌘ held ("⌘ held · let go to apply") and settles when ⌘ is
released, which is when the level actually changes; the tooltip's effort row
has the same bar on the provider's own scale. Drag either to set a level by
hand — it becomes the lid level whose band lands nearest and is applied to
every agent, exactly as a gesture would be
([EffortController.set](Sources/LidEffort/Effort/EffortController.swift)).
At the top of a scale the fill runs in colour. Overrides per model:
`~/.lid-effort/targets.json` (`{"codex": {"enabled": false}}`).

**Sizes:** the pill and its rings have one size (Settings → Notch → Size);
the cards — tooltips, questions and the done card — have their own
(Tooltip size, 75–150%), so a small pill can still carry readable cards.

**The pill:** a click on the handle above the notch sends it clockwise to
the next side — left, top, right — and the notch runs there itself, as a
glowing drop of colour along the bezel and round the corner
([EdgeFlow.swift](Sources/LidEffort/Notch/EdgeFlow.swift)). Folded, the
pill wears a dark-outside, light-inside rim with a slow sheen, so it reads
over a light window as well as a dark one.

## Usage & sessions

Rings for Claude Code, Codex, Grok and the other providers spyx reads
(Cursor, Copilot, Kimi, Gemini/Antigravity, DeepSeek, GLM, Ollama, LM Studio,
OpenCode, Command Code, Devin). Switch providers on and off in Settings → Accounts. A thin arc spins
inside a ring while a session is busy; amber when it's waiting on you. When
a session finishes, a card pops out of the folded pill for the peek
duration, without opening the notch — and it cheers rather than reports
("Shipped it! · Keep building.", one of eight; a session that stopped to
ask gets "Needs your answer" and the question itself). Click it to jump
to that session
([DoneToast.swift](Sources/LidEffort/Features/DoneToast.swift)).

**Answering Claude from the notch** (Settings → Sessions & Approvals,
on by default; [Prompts/](Sources/LidEffort/Prompts)). Turned on, it adds a
`PermissionRequest` hook to `~/.claude/settings.json` that runs this app's
binary with `--prompt-hook`; the hook hands the prompt to the app over a
Unix socket (`~/.lid-effort/prompt.sock`) and waits. A permission request
shows as *Deny · Always · Allow* (Always takes Claude's own "don't ask
again" suggestion); an AskUserQuestion one question at a time — the
question as the heading, its options, and "Something else…" for an answer
of your own; a pick only picks — Continue moves on and Send sends,
Skip leaves a question out, and the card slides and resizes between
questions. ↗ opens the session, ✕ hands the prompt back to Claude's own
dialog. Its options — in the Claude
tooltip right under the row of the session that is asking (moved to the top
and marked waiting), and beside the folded pill. The card stays
until it is answered — like the "waiting on you" card, which now also
stays until the session stops waiting. Open the notch while one waits and
it stays open with the question's tooltip up, however far the pointer
wanders, until you answer (another ring still shows its own card while
you point at it). A fresh screen of choices takes no clicks for its first
0.7 s, so a click already on its way — in a game, in another app — cannot
land on Allow. Test cases: [docs/test-cases](docs/test-cases/approvals-and-questions.md). If you are looking at that session
or switch to it, the app is not running, or nobody answers for 9 minutes,
the hook returns no decision and Claude asks in its own dialog as usual. Answering AskUserQuestion this way relies on its `answers` input
field, which the binary defines but the docs do not yet describe — treat
it as experimental.

A waiting prompt makes itself known in its own voice (Settings →
Notifications → When Claude asks): one sound for a permission, another for
a question, again every 1, 2 or 5 minutes while unanswered if you like, an
optional macOS notification (withdrawn once it is answered), and — for
games and presentations — "Sound only" over full-screen apps, where the
card waits until you are back instead of coming up under a busy pointer.

With several sessions running, a prompt says which piece of work it
belongs to: the card's subtitle names the session, its folder and git
branch, and two lines above the question quote your last message to that
session and what Claude said just before asking — read once, from the end
of the transcript the hook names ([PromptContext.swift](Sources/LidEffort/Prompts/PromptContext.swift)).

The tooltip lists at most 6 sessions (Settings, 3–10): what needs you
first, then what runs, then the rest newest first; idle ones older than
6 h (configurable) are left out.

When a session limit comes back, the card beside the notch cheers rather
than reports ("Hurray! Claude is back — session limit reset, let's build";
one of eight lines, [ResetCheer.swift](Sources/LidEffort/Model/ResetCheer.swift)).
It stays quiet when the provider's weekly limit is still spent — a session
back at zero inside a spent week isn't usable, so it isn't news
([UsageResetWatcher.swift](Sources/LidEffort/Model/UsageResetWatcher.swift)).
"Preview notification" in Settings shows the card on demand.

## Install

1. Download `spyx-<version>.dmg` from
   [Releases](https://github.com/chrisnguyen1211/spyxdotlol/releases/latest),
   open it, and drag **spyx** onto **Applications**. Or build it yourself — see
   [Build & run](#build--run); a copy you build on your own Mac is never
   quarantined, so Gatekeeper doesn't stop it.
2. Open it from Applications. A downloaded copy that isn't notarized is
   stopped by Gatekeeper the first time: open **System Settings → Privacy &
   Security**, scroll to "spyx was blocked", click **Open Anyway**, and
   confirm. Or clear the download's quarantine flag yourself:

   ```bash
   xattr -dr com.apple.quarantine /Applications/spyx.app
   ```

   Only the first launch asks; Sparkle updates install without it.
3. The **setup assistant** opens and walks through everything the notch needs,
   one page each, with every status read live from macOS:

   | Step | What it asks for | What it's for |
   | --- | --- | --- |
   | Install | Move to Applications (only if it's running from the disk image, Downloads or a build folder) | macOS forgets permissions given to a translocated copy and refuses the login item outside Applications |
   | Claude Code | The PermissionRequest hook in `~/.claude/settings.json`; keychain access to Claude's login (choose **Always Allow**) | Answering from the notch; the usage rings |
   | Terminals | Automation for Terminal, iTerm2 and cmux — the ones that are scripted. Superset, Ghostty, Warp, VS Code, Cursor, Zed, kitty and WezTerm are listed as working with nothing to allow | Typing `/effort` into an idle tab; opening a session's tab |
   | Claude app | Accessibility | Setting the level in a Claude app session live |
   | Agents | Every supported agent with a switch; once on, Connected or its one fix (Sign in in Terminal, Open app, Allow access) | Their rings |
   | Try it | Open at login; the ⌘ + lid gesture with a live level meter | — |

   No notifications step: prompts and limits show in the notch, system banners
   are opt-in in Settings, and macOS asks the first time one is sent.
   Every step can be skipped. It opens on its own once per Mac, and again from
   the menu bar's **Set Up spyx…**. `open -a spyx --args --setup` forces it.

4. When setup finishes, the **intro tour** takes over. **Liquid Glass**, the default look, opens
   with a short film: the screen blurs and dims, drops of liquid run together
   into a big pill that turns to glass, every coding agent spyx reads runs
   through it faster and faster before settling on yours, "spyx — Every coding
   agent. One pill." arrives and holds, and the pill shrinks
   and flies into the real one on the right edge, which only then appears — over a soft, warm drone that
   rises gently from silence and opens a little at the name, synthesised in code
   ([MeditationRise.swift](Sources/LidEffort/Onboarding/MeditationRise.swift)). Its steps are glass cards whose
   pictures are the app's real UI — the pill with your agents' rings, the done
   note, the approval and question cards, the effort card — with a pool of
   light on the pill and a glowing line with a bead of light running to it.
   Every step has its own soft sound: a muted wooden tap on Next, a warm
   marimba when you approve, a quiet sparkle when you answer a question, a low
   pair on Deny, a quick run of bubbles as the pill moves to another edge, a warm chord
   at the end. `open -a spyx --args --tour-at done` opens the tour on one step.
   **Doodle** is the other look: sticky notes in a
   hand-drawn style, with marker doodles drawn over the screen pointing at the
   real pill. It demos on the notch itself — a finished session sliding out of
   the pill, an approval and a question to answer (answers go nowhere; the
   tour's own card takes the prompt's place and says what the answer would
   have done) — then
   sends you to move the pill ("spyx can be anywhere!", with a Show me that
   flies it round all four sides and home, each side ticked off as it lands) and to try ⌘ + lid, with a doodled MacBook
   flapping its lid and the ⌘ key blinking. It notices when you actually move
   the pill or change the effort. The tour is laid out for the pill's home on the right:
   it flies the pill there first if it lives elsewhere, brings it back after
   "anywhere", and the last note offers to put it back where it was. There is no Skip — only Next. Again from the menu bar's **Take the Tour**;
   `open -a spyx --args --tour` forces it.

### Making the disk image

```bash
script/package.sh
```

That gives `build/spyx-<version>.dmg`, signed with the identity
`bundle.sh` finds. To ship it to people who shouldn't have to use Open Anyway,
sign with a Developer ID and notarize — store the notary credentials once with
`xcrun notarytool store-credentials spyx`, then:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=spyx script/package.sh
```

Publishing a release, with the Sparkle appcast that updates installed copies,
is `script/release.sh` — see [RELEASING.md](RELEASING.md).

## Build & run

Xcode 16+ (for the SDK; the build itself is SwiftPM), Apple silicon, macOS 15+.

```bash
script/bundle.sh --run           # swift build → build/spyx.app → launch
script/bundle.sh --release       # Release build
swift test
```

**Name and icon.** The app is **spyx** (always lowercase): `build/spyx.app`,
process `spyx`. The Swift target and source folders are still `LidEffort`, and
the bundle ID is `lol.spyx.app` on purpose — macOS keeps granted
permissions, the keychain's Always Allow and the login item against it, so the
rename costs no one a re-setup. The logo is the **halftone iris** — an eye
drawn in dots, keeping watch on your agents. Its source files are in
[docs/brand/halftone-iris](docs/brand/halftone-iris); the icon set is rendered
from them, every size drawn at its own pixels (64 px and under use the same
halftone at half the density, where the full one would blur into a grey ring):

```bash
swift script/icon/render-icon.swift docs/brand/halftone-iris Sources/LidEffort/Resources/Assets.xcassets/AppIcon.appiconset
```

The menu-bar glyph is the same eye as a template SVG
(`MenuBarIcon.imageset/menubar-spyx.svg`, from `MenuBarIcon.svg`).

The app must run as a bundle: a bare `swift run` binary has no bundle
identifier, so notifications throw on first use and the keychain can't
remember consent. `bundle.sh` signs with an Apple Development identity when
one is in the keychain (stable across rebuilds), ad-hoc otherwise.

## Layout

- `Sources/LidEffortCore` — the lid: gesture, motion, effort scales, config
  patching, prompt-idle detection. Pure Swift, Swift Testing.
- `Sources/LidEffort` — the app. `Effort/` is the lid module (controller,
  writer, injector, sensor); `Notch/`, `Features/`, `Model/`,
  `Providers/`, `Sessions/`, `Settings/` are the notch, the usage readers
  and the session monitors. XCTest.
- `Sources/CZstd` — vendored Zstandard decoder for Claude Desktop's cache.

## Privacy

spyx runs entirely on your Mac. There is no account, no analytics and no
server of ours: nothing about you or your work is sent anywhere.

- **Usage rings** — each provider's usage is read from that provider's own
  API, with the login its CLI or app already has on this Mac (Claude Code's
  keychain item, `~/.codex/auth.json`, …) or a sign-in you make in spyx's
  own web view. Those requests go to that provider and nowhere else.
- **Sessions** — read from the agents' own files (`~/.claude`, `~/.codex`,
  `~/.grok`, Claude app's session records), only ever read.
- **Effort** — the one line holding the value in each agent's config is
  rewritten. Typing `/effort` uses Terminal's scripting (Automation) and,
  for the Claude app, Accessibility — only into the session in view, only
  the command, never into a draft.
- **Approvals** — a hook in `~/.claude/settings.json` hands a prompt to the
  app over a local Unix socket; your answer goes back the same way.
- **Diagnostics** — MetricKit's crash and hang reports are kept in
  `~/Library/Application Support/spyx/Diagnostics` and never uploaded;
  Settings → General copies them if you want to send one in an issue.
- **Updates** — Sparkle checks the appcast on this repository's Releases,
  and installs only updates signed with spyx's key.
- **The app itself** runs with macOS's hardened runtime: no other program
  can load code into spyx and borrow its Accessibility or Terminal access.
- **Approvals** show the whole command: one longer than the card scrolls,
  and Allow waits until its last line has been seen; invisible and
  text-reordering characters are written out (`⟨U+202E⟩`).

## License

MIT. Third-party components and their licenses are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
