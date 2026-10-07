# pillr — end-to-end test cases

Generated from `script/e2e.py`; run `script/e2e.py` to execute them all.
Logic cases are proven by the automated suites named; release and security
cases (H) are read-only checks of the installed app, the disk image, the
update feed and the public repository.


## Lid gesture

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| A1 | Hold ⌘, open the lid 7° and let go | One level up; closing 7° is one level down; past halfway goes on, short of it falls back; release commits | `StepControllerTests`, `EffortStepControllerTests`, `StepPreviewTests`, `The bar follows the lid` |
| A2 | Move the lid without ⌘ | Only the viewing angle: the rest becomes the new neutral, the level never changes; a hint the first few times | `StepControllerTests`, `EffortStepControllerTests` |
| A3 | Close the laptop below 60°, sleep and wake | Level held, neutral forgotten, first 2 s after wake ignored | `LidMotionTests`, `EffortLidMotionTests` |
| A4 | Drag the bar on the card or the tooltip | Lands on the lid level whose band is nearest and applies it like a gesture | `EffortSliderTests`, `EffortLevelReachingTests`, `A value dragged to by hand` |

## Effort configs

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| B1 | Claude Code default | ~/.claude/settings.json effortLevel rewritten in place; the top band writes xhigh (max is not persistable) | `SettingsPatchTests`, `EffortTargetTests` |
| B2 | Codex default, per model | ~/.codex/config.toml model_reasoning_effort on the running model's own scale from models_cache.json | `ConfigDocumentTests`, `EffortConfigDocumentTests`, `EffortScaleTests`, `EffortBucketingTests` |
| B3 | Grok default, per model | ~/.grok/config.toml [models] default_reasoning_effort, scale read from the keyed catalog (high stays high) | `EffortTargetTests`, `EffortDotStateTests` |
| B4 | Overrides in ~/.lid-effort/targets.json | enabled/bands per agent and model applied; nothing else touched | `TargetOverridesWritingTests` |
| B5 | A catalog value with a quote or a line break | Dropped; the writer refuses it, so no extra key can be written into a config | `SecurityHardeningTests` |

## Live effort

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| C1 | Several sessions open, one Terminal tab selected | Only the selected tab's session changes; the others keep their level | `EffortAutoScopeTests`, `LiveEffortReachTests` |
| C2 | Claude Code / Grok prompt idle vs mid-turn | Typed only at an idle, empty prompt (Grok's framed │ ❯ too); mid-turn it waits for the turn to end | `PromptIdleDetectorTests`, `EffortPromptIdleTests` |
| C3 | The session runs another model than the config | The command uses the running model's value (Claude max is /effort max live) | `LiveEffortReachTests` |
| C4 | Claude app: switch session, then gesture | The session on screen is read from the window's page address; its name, model and command follow it | `ClaudeAppViewTests`, `DesktopSessionTests` |
| C5 | Claude app with a Vietnamese/Telex input method | The command is put in whole, read back, and Return goes only to exactly /effort <value> | `ComposerExactnessTests`, `SecurityHardeningTests` |
| C6 | Why a change did not land (replying, draft, no access, Codex) | The card says the reason and what happens next, in all six languages, never clipped | `EffortNotesTests`, `EffortRenderTests` |
| C7 | Superset pane in view | Typed through Superset's host service when idle; older stack says next session | `SupersetTests`, `SupersetLiveTests` |

## Approvals

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| D1 | Turn answering from the notch on and off | Only pillr's own PermissionRequest entry is added/removed in settings.json; the binary path is shell-quoted | `ClaudeHookInstallerTests` |
| D2 | Hook ↔ app round trip | Prompt held until answered; 9 min, app not running or hook killed → Claude asks itself; parallel prompts kept apart | `PromptBrokerTests`, `PromptBrokerConcurrencyTests` |
| D3 | Allow / Deny / Always | Exact decision JSON; Always carries Claude's own suggestion | `PendingPromptTests`, `PromptPermissionTests` |
| D4 | AskUserQuestion: one, several, your own answer, skip | Answers sent per question; Continue/Send/Skip behave; typing goes into Something else… | `PromptDraftTests`, `PromptDraftCopyTests`, `PromptTypingTests`, `PromptQuestionClickMapTests` |
| D5 | A click already on its way when the card appears | Ignored for 0.7 s; the clickable areas match what is drawn | `StrayClickPinTests`, `PromptClickMapTests` |
| D6 | Which work is asking | Session, folder, branch, your last message and Claude's lead-in shown | `PromptContextTests`, `PromptContextRenderTests` |
| D7 | A command longer than the card, or with hidden characters | The well scrolls; Allow/Always wait until its end is seen; bidi/zero-width written out | `SecurityHardeningTests` |
| D8 | Two sessions asking at once | Pager between them; answering one leaves the other | `PromptQueueTests` |
| D9 | Sounds, repeats, notifications, full screen | Per-kind sound, repeat interval, banner withdrawn when answered, sound only over full-screen apps | `PromptAlertsTests` |

## Usage

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| E1 | Claude usage from the keychain login | Profiles found, token refreshed before expiry, keychain refusals and expiry explained | `ClaudeOAuthProviderTests`, `ClaudeTokenRefresherTests`, `ClaudeProfileTests`, `ClaudeKeychainPromptTests`, `KeychainRefusalTests`, `KeychainDuplicateTests`, `ExpiredCredentialTests`, `ClaudeUsageCLITests`, `ClaudeDesktopUsageCacheTests` |
| E2 | Every other provider's reply | Codex, Cursor, Copilot, Kimi, GLM, Gemini, Antigravity, Ollama, LM Studio, OpenCode, DeepSeek, Devin, Perplexity, Command Code parsed into rings | `CodexUsageTests`, `CursorUsageTests`, `GitHubCopilotUsageTests`, `KimiUsageTests`, `GLMQuotaResponseTests`, `GeminiCLIUsageTests`, `AntigravityQuotaTests`, `OllamaUsageTests`, `LMStudioUsageTests`, `OpenCodeUsageTests`, `DeepSeekUsageTests`, `DevinUsageTests`, `PerplexityUsageTests`, `CommandCodeUsageTests`, `GrokUsageTests`, `UsageResponseTests` |
| E3 | Sessions working, waiting, done | Arc spins while busy, amber when waiting, done card once, click opens the session | `SessionCompletionTests`, `DoneToastTests`, `WaitingCardTests`, `ClaudeSessionStateSourceTests`, `ActivitySummaryTests`, `TerminalTabFocusTests` |
| E4 | A limit resets / is nearly spent | Cheer only when usable (not inside a spent week); threshold notices once | `UsageResetWatcherTests`, `ResetCheerTests`, `UsageLimitWatcherTests`, `ThresholdNotifierTests` |
| E5 | A web page tries the local Ollama relay | Cross-site, foreign Host or Origin refused | `OllamaRelayTransportTests` |

## Notch

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| F1 | Every edge, size and screen | Placement, folding and hit areas correct on top/left/right and on notched/flat screens | `NotchEdgeTests`, `NotchGeometryTests`, `NotchPlacementTests`, `PanelSizingTests`, `FoldingOnEveryEdgeTests`, `HardwareNotchGeometryTests`, `OrbHitAccuracyTests` |
| F2 | Glass over a window vs over the desktop | Liquid Glass where it can refract, a clear blur where it cannot | `GlassSightlineTests` |
| F3 | Tooltips and cards | Sized to their content at every card scale; nothing overflows | `TooltipOverflowTests`, `TooltipResizeTests`, `CardScaleTests`, `TooltipSessionsTests` |

## Settings

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| G1 | First launch and upgrade from a pre-1.0 build | Defaults as designed; settings copied once from dev.lideffort | `PreferencesTests`, `PreferencesDefaultsTests` |
| G2 | Six languages | Every new string translated, interpolations and % intact | `LocalizationCoverageTests`, `EffortNotesTests` |
| G3 | Check for updates | Up to date / found / failed each say so | `UpdateOutcomeTests` |
| G4 | The Settings window | Lays out at full width in every tab, dark and light | `SettingsRenderTests`, `SettingsQuitButtonTests` |

## Pill

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| I1 | Hover a busy session's ring | Its row says the step it is on ("$ swift test", "Editing X.swift", Grok's own call title, "Thinking") timed from when the step began | `SessionDoingTests` |
| I2 | Reply to a session from its row or ⌥-click on the done card | One line; Terminal.app typed in the background at an idle prompt; Claude app only when that session is on screen; elsewhere pasted unsent; the text can never run as AppleScript | `SessionCommanderTests` |
| I3 | Stop a working session | Only busy sessions in Terminal/iTerm2, Esc pressed only once their own tab is in front | `SessionCommanderTests` |
| I4 | A limit running out before its reset | "out in 25 min" / "out ~16:40" from the recent rate; nothing when it lasts | `UsageForecastTests` |
| I5 | Auto-eco on, an agent near its limit | Effort one step down, once per reset, never below low, the card says why; off by default | `UsageForecastTests` |
| I6 | A session finishes in a git repo | The done card says "3 files · +42 −7 · 2 new", read without taking git's lock | `PillInsightsTests` |
| I7 | Tokens per session; hand off to another agent | Tokens counted once per message, appended parts only; the brief is shell-quoted and never runs as shell | `PillInsightsTests` |
| I8 | The day's recap | At 6 pm once a day when there was work: sessions, tool calls, tokens, busiest agent — today's lines only | `PillInsightsTests` |

## Release

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H1 | Installed version | Matches script/version.env and has a release note | live: `installed_version` |
| H2 | Installed app signature | Valid, hardened runtime on | live: `installed_runtime` |

## Security

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H3 | Load a library into pillr with DYLD_INSERT_LIBRARIES | Refused by the hardened runtime | live: `injection_blocked` |

## Release

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H4 | The disk image | Verifies; the app inside is signed with the hardened runtime and the same version | live: `dmg_contents` |
| H5 | The update feed | releases/latest appcast names this version; the DMG it links downloads at the signed length | live: `feed_live` |

## Security

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H6 | The update's EdDSA signature | Verifies against pillr's key | live: `eddsa` |

## Release

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H7 | The public repository | Its main tree is exactly the local release commit's tree | live: `public_tree` |

## Security

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H8 | Secrets and old names in the public tree | No keys or tokens; upstream names only in THIRD_PARTY_NOTICES | live: `public_clean` |

## Approvals

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| H9 | Claude Code's hook | settings.json runs this /Applications/pillr.app binary with --prompt-hook | live: `hook_installed` |

Manual, on screen: see [approvals-and-questions.md](approvals-and-questions.md)
and `script/fake-prompt.sh` (TC37 `long`: Allow waits until the command is scrolled to its end).
