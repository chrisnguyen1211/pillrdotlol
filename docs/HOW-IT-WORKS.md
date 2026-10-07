# How pillr works

The technical companion to the [README](../README.md): how the lid gesture
reads the hinge, where each agent's effort level is written, how sessions and
done cards are detected, how approvals reach the notch, and how to build the
app. Paths link to the code that does each thing.

- [The lid](#the-lid)
- [Where the level goes](#where-the-level-goes)
- [The session in view gets it live](#the-session-in-view-gets-it-live)
- [In the notch](#in-the-notch)
- [Usage and sessions](#usage-and-sessions)
- [Done cards](#done-cards)
- [Answering Claude from the notch](#answering-claude-from-the-notch)
- [Reply, stop and hand off](#reply-stop-and-hand-off)
- [Limits: forecast and reset](#limits-forecast-and-reset)
- [Setup assistant and tour](#setup-assistant-and-tour)
- [Build and run](#build-and-run)
- [Making the disk image](#making-the-disk-image)
- [Layout](#layout)

## The lid

**The gesture** ([StepController.swift](../Sources/LidEffortCore/StepController.swift),
[EffortController.swift](../Sources/LidEffort/Effort/EffortController.swift)):
**hold ⌘**, move the lid, **let go**. One level per 7° of travel from where
the lid was when ⌘ went down — open is up, closed is down — and the release is
the commit, the way letting go of a slider is: it lands on whichever level the
lid is nearer (past halfway, more than 3.5°, goes on; at or short of halfway
falls back). There is no waiting for the lid to settle: a hand still on the key
has not decided, however still the lid is.

The lid has five levels — low, medium, high, xhigh, max — and each agent maps
them onto its own scale (below).

Without ⌘ the lid is only ever the viewing angle: a stand, a sofa, glare —
wherever it stops becomes the new neutral and nothing changes. The first few
times the lid travels a level's worth with nothing held, the card says so
("Hold ⌘ to change effort"), then stops mentioning it.

**What it ignores** ([LidMotion.swift](../Sources/LidEffortCore/LidMotion.swift),
[EffortController.swift](../Sources/LidEffort/Effort/EffortController.swift)):
closing the laptop (below 60° the level holds, and the lid's neutral is
forgotten — opening it again is never a push), and sleep (suspended; the first
2 s after wake are ignored).

**The sensor** ([LidAngleSensor.swift](../Sources/LidEffort/Effort/LidAngleSensor.swift))
is Apple's undocumented lid-angle HID device, opened read-only and never
seized. A Mac without a readable one — every desktop Mac, and MacBooks that
lack it — gets everything else pillr does; only the gesture is missing. The
effort bars in the cards still set the level by hand.

## Where the level goes

[EffortTargetWriter.swift](../Sources/LidEffort/Effort/EffortTargetWriter.swift),
[EffortTarget.swift](../Sources/LidEffortCore/EffortTarget.swift) (`BuiltInTargets`).

**One agent per gesture: the one you are working with.** When ⌘ goes down,
pillr picks the agent of the session in view (the selected Terminal tab, the
Claude app's session), else Codex if it is in front, else the agent the lid
changed last — and the gesture starts from that agent's own current level.
Letting go writes that agent's default config, on its model's scale (the
default for its *next* session), and types `/effort` into its session in view.
Every other agent keeps its level. Only the one line holding the value is
rewritten; nothing else in the file changes. Auto-eco steps down only the agent
that is about to run out.

The five lid levels map to values as follows. "Scale" is everything the model
accepts; "Lid writes" is what each lid level (low → max) puts in the config.

| Agent | Config → key | Model | Scale | Lid writes (low → max) |
|---|---|---|---|---|
| Claude Code | `~/.claude/settings.json` → `effortLevel` | most models (Opus 4.7 and newer, …) | `low medium high xhigh max` | `low medium high xhigh xhigh` |
| | | Opus 4.6, Sonnet 4.6 | `low medium high max` | `low medium high high high` |
| | | Opus 4.5 | `low medium high` | `low medium high high high` |
| | | before Opus 4.5; Sonnet 4.5; Haiku 4.5 | none | nothing written |
| Codex | `~/.codex/config.toml` → `model_reasoning_effort` | gpt-5.6-sol, -sol-wm, -terra | `low medium high xhigh max ultra` | `low medium high xhigh ultra` |
| | | gpt-5.6-luna | `low medium high xhigh max` | `low medium high xhigh max` |
| | | gpt-5.5, gpt-5.4, gpt-5.4-mini, others | `low medium high xhigh` | `low medium high xhigh xhigh` |
| Grok | `~/.grok/config.toml` → `[models] default_reasoning_effort` | default | `low medium high xhigh` | `low medium high xhigh xhigh` |
| | | grok-4.5 | `low medium high` | `low medium high high high` |
| Hermes | `~/.hermes/config.yaml` → `agent.reasoning_effort` | any | `none minimal low medium high xhigh` | `low medium high xhigh xhigh` |
| Droid | `~/.factory/settings.json` → `reasoningEffort` | Opus 4.6–4.8, Sonnet 4.6 | `off low medium high max` | `low medium high high max` |
| | | Opus 4.5, Sonnet 4.5, Haiku 4.5 | `off low medium high` | `low medium high high high` |
| | | gpt-5.6 | `none low medium high xhigh` | `low medium high xhigh xhigh` |
| | | others | `off low medium high` | `low medium high high high` |
| Copilot CLI | `~/.copilot/settings.json` → `effortLevel` | any | `low medium high xhigh` | `low medium high xhigh xhigh` |
| Kimi Code | `~/.kimi-code/config.toml` → `[thinking] effort` | any | `low medium high xhigh max` | `low medium high xhigh max` |

Notes:

- **Claude Code** persists four levels (`low`…`xhigh`); `max` is taken only
  live, as `/effort max` typed into a running session, so the config's top two
  lid levels both write `xhigh`. Which levels a model has follows Claude Code
  2.1: no effort before Opus 4.5 or on Haiku 4.5; Opus 4.5 stops at high;
  Opus and Sonnet 4.6 skip xhigh but have max; everything newer has all five.
  A level a model lacks lands on the nearest one below it.
- **Codex** — the table is the built-in fallback. At runtime each model's scale
  comes from Codex's own catalog, `~/.codex/models_cache.json`
  (`supported_reasoning_levels`), and a model missing from the table is spread
  across the five lid levels proportionally (`CodexCatalog`).
- **Grok** — likewise read from `~/.grok/models_cache.json`
  (`reasoning_efforts`) when present (`GrokCatalog`); the table is what Grok 1.0
  ships.
- **Kimi Code** — the `[thinking]` section is added if the file lacks it; each
  model allows its own subset (`support_efforts`) and Kimi clamps a value its
  model lacks.
- **Droid** and **Copilot CLI** and **Kimi Code** are written only when the
  agent itself is on this Mac (its binary or its sessions folder), not merely a
  config file another tool created.

**Overrides** live in `~/.lid-effort/targets.json`. Only `enabled` and
per-model `bands` (exactly five values) can be overridden:

```json
{
  "codex": { "enabled": false },
  "grok":  { "bands": { "grok-4.6": ["minimal", "low", "medium", "high", "max"] } }
}
```

## The session in view gets it live

One session — the one you are looking at — changes immediately; the others
keep their level until they next start
([EffortController.swift](../Sources/LidEffort/Effort/EffortController.swift)):

- **Claude Code and Grok in Terminal.app** — the selected tab gets
  `/effort <value>` typed in, the value its *running model* takes
  ([EffortInjector.swift](../Sources/LidEffort/Effort/EffortInjector.swift)),
  only when its prompt is empty. Mid-turn, it goes in when the turn ends.
- **The Claude app's Claude Code sessions** — with Accessibility allowed, pillr
  types `/effort <value>` and Return into the message box of the session on
  screen, and checks the box emptied
  ([ClaudeDesktopComposer.swift](../Sources/LidEffort/Effort/ClaudeDesktopComposer.swift)).
  It never types into a draft: while Claude is replying or the box has text in
  it, the command waits (up to 10 minutes) and goes in once it can. Settings →
  Lid turns it off.
- **Superset** — typed into the pane in view through Superset's own host
  service, when the session is idle.
- **Codex** — its app and CLI keep a running chat's level; new chats start at
  the new one.

The card always says which: "Live → *session*", or why not yet and what happens
next ("Claude is replying · sends to *session* when it's done", "Draft in the
message box · …", "Codex app keeps each chat's effort · …"). A change that
waited brings the card back once it is live ("Now live → *session*").

**Superset** ([Superset.swift](../Sources/LidEffort/Sessions/Superset.swift)): a
Claude session running in a Superset pane is found from the environment
Superset gives the pane, named by its workspace and branch, and a click on it
opens that workspace and terminal through Superset's own `superset://` link.
Superset's databases are only ever read.

## In the notch

Each ring the lid drives is a gauge, and the dots in the opening at its foot
are that model's scale, filled to its value. The bar lives in two cards: the
change card's bar **follows the lid live** while it moves with ⌘ held ("⌘ held ·
let go to apply") and settles when ⌘ is released, which is when the level
actually changes; the tooltip's effort row has the same bar on the provider's
own scale. Drag either to set a level by hand — it becomes the lid level whose
band lands nearest and is applied to that ring's agent only, exactly as a
gesture would be. At the top of a scale the fill runs in colour.

**Sizes:** the pill and its rings have one size (Settings → Notch → Size); the
cards — tooltips, questions and the done card — have their own (Tooltip size,
75–150%), so a small pill can still carry readable cards.

**Moving the pill:** a click on the handle above the notch sends it clockwise
to the next side — left, top, right — and the notch runs there itself, as a
glowing drop of colour along the bezel and round the corner
([EdgeFlow.swift](../Sources/LidEffort/Notch/EdgeFlow.swift)). Folded, the pill
wears a dark-outside, light-inside rim with a slow sheen, so it reads over a
light window as well as a dark one.

## Usage and sessions

Each provider's ring is read from that provider's own API with the login its
CLI or app already has on this Mac ([Providers/](../Sources/LidEffort/Providers)),
or for DeepSeek a sign-in made in pillr's own web view. Switch providers on and
off in Settings → Accounts.

- **Claude Code** — usage is read by running Claude Code's own `/usage`
  (`claude --print --no-session-persistence --strict-mcp-config /usage`, at
  most every 5 minutes, from `~/Library/Application Support/pillr/usage-scratch`;
  [ClaudeUsageCLI.swift](../Sources/LidEffort/Providers/ClaudeUsageCLI.swift)),
  falling back to the OAuth endpoint with the keychain login. Before that login
  expires, pillr runs `claude -p` to let Claude Code renew it
  ([ClaudeTokenRefresher.swift](../Sources/LidEffort/Providers/ClaudeTokenRefresher.swift));
  the session that briefly registers is never shown.
- **Gemini API** — there is no endpoint for an API key's usage, so the ring
  adds up the tokens Gemini CLI, OpenCode and Hermes record in their own logs
  ([GeminiAPIProvider.swift](../Sources/LidEffort/Providers/GeminiAPIProvider.swift)).
- **Ollama** — local models through the Ollama server; Ollama cloud with an API
  key you give in Settings (or `OLLAMA_API_KEY`), stored in the login keychain
  under pillr's own item. **LM Studio** — its SDK socket and server log, read
  only ([LMStudioMetrics.swift](../Sources/LidEffort/Sessions/LMStudioMetrics.swift)).

**Sessions** come from the agents' own files, only ever read: Claude Code
(`~/.claude/sessions`, the transcripts under `~/.claude/projects`, the Claude
app's session records), Codex, Grok, Cursor, Kimi Code, Antigravity, and the
Gemini CLI / OpenCode / Hermes sessions spending a Gemini key
([Sessions/](../Sources/LidEffort/Sessions)). Each row carries the model, the
effort and the tokens used. A thin arc spins inside a ring while a session is
busy; amber when it's waiting on you.

The tooltip lists at most 6 sessions (Settings, 3–10): what needs you first,
then what runs, then the rest newest first; idle ones older than 6 h
(configurable) are left out.

## Done cards

When a session finishes, a card pops out of the folded pill for the peek
duration, without opening the notch, and cheers rather than reports ("Shipped
it! · Keep building.", one of eight; a session that stopped to ask gets "Needs
your answer" and the question itself). Click it to jump to that session
([DoneToast.swift](../Sources/LidEffort/Features/DoneToast.swift)).

The moment comes from each agent's own turn-finished hook, not a guess from
files ([AgentHooks.swift](../Sources/LidEffort/Sessions/AgentHooks.swift),
[ClaudeHookInstaller.swift](../Sources/LidEffort/Prompts/ClaudeHookInstaller.swift)).
Every hook runs `pillr --stop-hook --agent <name>` (Codex: `--codex-notify`),
which hands the event to the app and exits at once.

| Agent | Where the hook goes | Hook |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `Stop` |
| Codex (CLI and app) | `~/.codex/config.toml` | `notify` — an existing notify program is kept and called after pillr |
| Grok | `~/.grok/hooks/pillr.json` (pillr's own file) | `Stop` |
| Cursor | `~/.cursor/hooks.json` | `stop` |
| Droid | `~/.factory/settings.json` | `Stop` under `hooks` |
| Antigravity | `~/.gemini/config/hooks.json` | entry named `pillr`, `Stop` |
| Copilot CLI | `~/.copilot/hooks/pillr.json` (pillr's own file) | `agentStop` |
| Kimi Code | `~/.kimi-code/config.toml` | one `[[hooks]]` block, `event = "Stop"` |
| Gemini CLI | `~/.gemini/settings.json` | `AfterAgent` |
| OpenCode | `~/.config/opencode/plugins/pillr.js` (pillr's own file) | plugin on `session.status` idle |

Hooks are installed only for agents present on this Mac. Each install adds only
pillr's own entry and each removal takes only that out; other tools' hooks are
never touched. A config file that is there but does not parse is left alone.

## Answering Claude from the notch

Settings → Sessions & Approvals, on by default
([Prompts/](../Sources/LidEffort/Prompts)). It adds a `PermissionRequest` hook
to `~/.claude/settings.json` that runs pillr's binary with `--prompt-hook`; the
hook hands the prompt to the app over a Unix socket (`~/.lid-effort/prompt.sock`)
and waits.

- A permission request shows as *Deny · Always · Allow* (Always takes Claude's
  own "don't ask again" suggestion). The whole command is shown: one longer
  than the card scrolls, and Allow waits until its last line has been seen;
  invisible and text-reordering characters are written out (`⟨U+202E⟩`).
- An AskUserQuestion shows one question at a time — the question as the
  heading, its options, and "Something else…" for an answer of your own. A pick
  only picks: Continue moves on, Send sends, Skip leaves a question out.
- ↗ opens the session; ✕ hands the prompt back to Claude's own dialog.
- A fresh screen of choices takes no clicks for its first 0.7 s, so a click
  already on its way cannot land on Allow.
- With several sessions running, the card names the session, its folder and git
  branch, and quotes your last message and what Claude said just before asking
  ([PromptContext.swift](../Sources/LidEffort/Prompts/PromptContext.swift)).
- If you are looking at that session, the app is not running, or nobody answers
  for 9 minutes, the hook returns no decision and Claude asks in its own dialog
  as usual.

A waiting prompt can announce itself (Settings → Notifications → When Claude
asks): one sound for a permission, another for a question, repeated every 1, 2
or 5 minutes if you like; an optional macOS notification, withdrawn once
answered; and "Sound only" over full-screen apps.

Answering AskUserQuestion this way relies on its `answers` input field, which
Claude Code defines but does not yet document — treat it as experimental. Test
cases: [docs/test-cases](test-cases/approvals-and-questions.md).

## Reply, stop and hand off

[SessionCommander.swift](../Sources/LidEffort/Sessions/SessionCommander.swift),
[ReplyPanel.swift](../Sources/LidEffort/Features/ReplyPanel.swift),
[Handoff.swift](../Sources/LidEffort/Sessions/Handoff.swift).

- **Reply** opens a small field under the notch; Enter sends. Return is pressed
  only where pillr can confirm the text went into the right session: a
  Terminal.app or iTerm2 tab (found by its tty, prompt idle), the Claude app
  (the window must show that session and the box must read back the message
  exactly), or Superset. Anywhere else the session is brought to the front with
  the text pasted and left for you to send.
- **Stop** is Esc, pressed only once the session's own tab is confirmed in
  front.
- **Hand off** writes a short brief from the end of the session's transcript
  (your last request, its last answer, the folder and branch); you read and
  edit it, and Claude Code, Codex or Grok starts in a new Terminal window in the
  same folder with the brief as its first message.

## Limits: forecast and reset

When a limit window will run out at the current rate before it resets, the
ring's tooltip says so ("out in 25 min", "out ~16:40") — and says nothing when
it will last ([UsageForecast.swift](../Sources/LidEffort/Model/UsageForecast.swift)).

When a session limit comes back, a card beside the notch cheers ("Hurray!
Claude is back — session limit reset, let's build"; one of eight lines,
[ResetCheer.swift](../Sources/LidEffort/Model/ResetCheer.swift)). It stays quiet
while the provider's weekly limit is still spent
([UsageResetWatcher.swift](../Sources/LidEffort/Model/UsageResetWatcher.swift)).
"Preview notification" in Settings shows the card on demand.

## Setup assistant and tour

The setup assistant ([Onboarding/](../Sources/LidEffort/Onboarding)) opens once
per Mac, and again from the menu bar's **Set Up pillr…**;
`open -a pillr --args --setup` forces it. Every status is read live from macOS
and every optional step can be skipped.

| Step | What it asks for | What it's for |
|---|---|---|
| Install | Move to Applications (only when running from the disk image, Downloads or a build folder) | macOS forgets permissions given to a translocated copy and refuses the login item outside Applications |
| Agents | Every supported agent with a switch; once on, Connected or its one fix (Sign in in Terminal, Open app, Allow access) | The rings |
| Done & approvals | Each agent's turn-finished hook; Claude Code's approvals hook | Done cards; answering from the notch |
| Terminals | Automation for Terminal, iTerm2 and cmux — the scripted ones. Superset, Ghostty, Warp, VS Code, Cursor, Zed, kitty and WezTerm work with nothing to allow | Typing `/effort` and replies into an idle tab; opening a session's tab |
| Desktop apps | Accessibility (shown only when the Claude or Codex app is installed) | Setting the level and replying in a Claude app session |
| Try it | Open at login; the ⌘ + lid gesture with a live level meter | — |

There is no notifications step: prompts and limits show in the notch, system
banners are opt-in in Settings, and macOS asks the first time one is sent.

When setup finishes, the **intro tour** takes over (again from the menu bar's
**Take the Tour**; `open -a pillr --args --tour` forces it,
`--tour-at done` opens one step). **Liquid Glass**, the default look, opens
with a short film and steps through glass cards whose pictures are the app's
real UI, each with its own soft sound synthesised in code
([MeditationRise.swift](../Sources/LidEffort/Onboarding/MeditationRise.swift)).
**Doodle** is the other look: hand-drawn sticky notes that demo on the notch
itself — a finished session, an approval and a question (answers go nowhere),
moving the pill, and ⌘ + lid.

## Build and run

Xcode 16+ (for the SDK; the build itself is SwiftPM), Apple silicon, macOS 15+.

```bash
script/bundle.sh --run           # swift build → build/pillr.app → launch
script/bundle.sh --release       # Release build
swift test
```

The app must run as a bundle: a bare `swift run` binary has no bundle
identifier, so notifications throw on first use and the keychain can't remember
consent. `bundle.sh` signs with an Apple Development identity when one is in the
keychain (stable across rebuilds), ad-hoc otherwise. A copy you build on your
own Mac is never quarantined, so Gatekeeper doesn't stop it.

**Name and icon.** The app is **pillr** (always lowercase): `build/pillr.app`,
process `pillr`. The Swift target and source folders are still `LidEffort`, and
the bundle ID is `lol.pillr.app` — macOS keeps granted permissions, the
keychain's Always Allow and the login item against it. The logo is the
**halftone iris**, an eye drawn in dots; its sources are in
[docs/brand/halftone-iris](brand/halftone-iris). The icon set is rendered from
them, every size drawn at its own pixels:

```bash
swift script/icon/render-icon.swift docs/brand/halftone-iris Sources/LidEffort/Resources/Assets.xcassets/AppIcon.appiconset
```

The menu-bar glyph is the same eye as a template SVG
(`MenuBarIcon.imageset/menubar-pillr.svg`, from `MenuBarIcon.svg`).

Diagnostics: `log stream --predicate 'subsystem == "lol.pillr.app"' --level debug`.
MetricKit crash and hang reports are kept in
`~/Library/Application Support/pillr/Diagnostics` and never uploaded.

## Making the disk image

```bash
script/package.sh
```

That gives `build/pillr-<version>.dmg`, signed with the identity `bundle.sh`
finds. To sign with a Developer ID and notarize, see
[RELEASING.md](../RELEASING.md#notarization). Publishing a release, with the
Sparkle appcast that updates installed copies, is `script/release.sh`.

## Layout

- `Sources/LidEffortCore` — the lid: gesture, motion, effort scales, config
  patching, prompt-idle detection. Pure Swift, Swift Testing.
- `Sources/LidEffort` — the app. `Effort/` is the lid module (controller,
  writer, injector, sensor); `Notch/`, `Features/`, `Model/`, `Providers/`,
  `Sessions/`, `Prompts/`, `Onboarding/`, `Settings/` are the notch, the usage
  readers, the session monitors, approvals, setup and settings. XCTest.
- `Sources/CZstd` — vendored Zstandard decoder for the Claude app's cache.
- `script/` — bundling, signing, packaging and release.
- `site/` — the static page at pillr.lol.
