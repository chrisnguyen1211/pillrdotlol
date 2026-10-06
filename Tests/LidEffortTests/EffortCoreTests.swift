import XCTest
import LidEffortCore
@testable import LidEffort

/// The lid-effort module's pure logic: gesture, motion, per-model mapping,
/// config patching, prompt-idle detection, and live-update scoping. Ported
/// from the standalone Lid Effort package's Swift Testing suite.
final class EffortLidMotionTests: XCTestCase {
    func testNeedsAFullWindowBeforeItCanRest() {
        var motion = LidMotion(closedBelow: 90)
        motion.add(angle: 120, now: 0.0)
        motion.add(angle: 120, now: 0.2)
        XCTAssertFalse(motion.isResting)
        motion.add(angle: 120, now: 0.4)
        motion.add(angle: 120, now: 0.65)
        XCTAssertTrue(motion.isResting)
        XCTAssertEqual(motion.restingAngle, 120)
    }

    func testMovingThroughAnglesIsNotResting() {
        var motion = LidMotion(closedBelow: 90)
        for (i, angle) in [100.0, 106, 112, 118, 124].enumerated() {
            motion.add(angle: angle, now: Double(i) * 0.2)
        }
        XCTAssertFalse(motion.isResting)
    }

    func testJitterWithinToleranceStillRests() {
        var motion = LidMotion(closedBelow: 90, restTolerance: 1.5)
        for (i, angle) in [130.0, 131, 130.5, 129.8, 130.9].enumerated() {
            motion.add(angle: angle, now: Double(i) * 0.2)
        }
        XCTAssertTrue(motion.isResting)
        XCTAssertEqual(motion.restingAngle ?? 0, 130.5, accuracy: 0.2)
    }

    func testClosedIsDetectedFromTheLatestSample() {
        var motion = LidMotion(closedBelow: 90)
        motion.add(angle: 120, now: 0)
        XCTAssertFalse(motion.isClosed)
        motion.add(angle: 12, now: 0.2)
        XCTAssertTrue(motion.isClosed)
    }

    func testResetForgetsHistory() {
        var motion = LidMotion(closedBelow: 90)
        for i in 0..<5 { motion.add(angle: 120, now: Double(i) * 0.2) }
        XCTAssertTrue(motion.isResting)
        motion.reset()
        XCTAssertFalse(motion.isResting)
        XCTAssertFalse(motion.isClosed)
    }
}

final class EffortStepControllerTests: XCTestCase {
    func testFirstRestOnlyAnchors() {
        var step = StepController(level: .medium, stepDegrees: 8)
        XCTAssertFalse(step.settle(at: 110))
        XCTAssertEqual(step.anchor, 110)
        XCTAssertEqual(step.level, .medium)
    }

    func testPushOpenPastThresholdStepsUp() {
        var step = StepController(level: .medium, stepDegrees: 8)
        step.settle(at: 110)
        XCTAssertTrue(step.settle(at: 119))
        XCTAssertEqual(step.level, .high)
        XCTAssertEqual(step.anchor, 119, "resting spot becomes the new neutral")
    }

    func testPushClosedStepsDownAndBigPushesTakeSeveralSteps() {
        var step = StepController(level: .max, stepDegrees: 8)
        step.settle(at: 150)
        XCTAssertTrue(step.settle(at: 133)) // 17° = 2 steps
        XCTAssertEqual(step.level, .high)
    }

    func testSmallViewingAngleNudgesReanchorWithoutChangingLevel() {
        var step = StepController(level: .xhigh, stepDegrees: 8)
        step.settle(at: 110)
        XCTAssertFalse(step.settle(at: 113))
        XCTAssertFalse(step.settle(at: 117)) // creeping 3° + 4° never counts as a push
        XCTAssertEqual(step.level, .xhigh)
        XCTAssertEqual(step.anchor, 117)
    }

    func testClampsAtBothEnds() {
        var step = StepController(level: .max, stepDegrees: 8)
        step.settle(at: 100)
        XCTAssertFalse(step.settle(at: 140))
        XCTAssertEqual(step.level, .max)
        var low = StepController(level: .low, stepDegrees: 8)
        low.settle(at: 140)
        XCTAssertFalse(low.settle(at: 100))
        XCTAssertEqual(low.level, .low)
    }

    func testReanchorMakesTheNextRestNeutralAgain() {
        var step = StepController(level: .medium, stepDegrees: 8)
        step.settle(at: 100)
        step.reanchor()
        XCTAssertFalse(step.settle(at: 140), "after wake/calibration the new position must not count as a push")
        XCTAssertEqual(step.level, .medium)
    }
}

final class EffortTargetTests: XCTestCase {
    func testClaudeNeverEmitsMaxBecauseSettingsCannotPersistIt() {
        let claude = BuiltInTargets.claude
        XCTAssertEqual(claude.value(for: .max, model: "fable"), "xhigh")
        XCTAssertEqual(claude.value(for: .xhigh, model: nil), "xhigh")
        XCTAssertEqual(claude.value(for: .low, model: "sonnet"), "low")
    }

    func testCodexUsesPerModelScale() {
        let codex = BuiltInTargets.codex
        XCTAssertEqual(codex.value(for: .max, model: "gpt-5.6-sol"), "ultra")
        XCTAssertEqual(codex.value(for: .max, model: "gpt-5.6-luna"), "max")
        XCTAssertEqual(codex.value(for: .max, model: "gpt-5.5"), "xhigh")
        XCTAssertEqual(codex.value(for: .max, model: "gpt-9"), "xhigh", "unknown model falls back to the wildcard row")
    }

    func testProportionalMappingCoversWholeScale() {
        XCTAssertEqual(BandMapping.proportional(from: ["a", "b", "c", "d", "e"]), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(BandMapping.proportional(from: ["low", "medium", "high", "xhigh"]), ["low", "medium", "high", "high", "xhigh"])
        XCTAssertNil(BandMapping.proportional(from: []))
    }

    func testOverridesReplaceBandsAndEnabledOnly() {
        let json = """
        { "codex": { "enabled": false },
          "grok": { "bands": { "grok-4.6": ["minimal", "low", "medium", "high", "max"], "bad": ["x"] } } }
        """
        let targets = TargetOverrides.apply(json, to: BuiltInTargets.all)
        let codex = targets.first { $0.id == "codex" }!
        let grok = targets.first { $0.id == "grok" }!
        XCTAssertFalse(codex.enabled)
        XCTAssertEqual(grok.value(for: .low, model: "grok-4.6"), "minimal")
        XCTAssertNil(grok.bands["bad"], "a non-5-entry list must be ignored, not half-applied")
        XCTAssertEqual(TargetOverrides.apply("not json", to: BuiltInTargets.all), BuiltInTargets.all)
    }

    func testCodexCatalogFillsUnknownModelsWithoutTouchingTunedOnes() {
        let cache = """
        {"models": [
          {"slug": "gpt-5.6-sol", "supported_reasoning_levels": ["low","medium","high","xhigh","max","ultra"]},
          {"slug": "gpt-7-new", "supported_reasoning_levels": ["low","medium","high"]},
          {"slug": "broken", "supported_reasoning_levels": []} ]}
        """
        let catalog = CodexCatalog.supportedLevels(json: cache)
        XCTAssertEqual(catalog["gpt-7-new"], ["low", "medium", "high"])
        XCTAssertNil(catalog["broken"])
        let filled = CodexCatalog.fill(BuiltInTargets.codex, with: catalog)
        XCTAssertEqual(filled.value(for: .max, model: "gpt-7-new"), "high")
        XCTAssertEqual(filled.value(for: .max, model: "gpt-5.6-sol"), "ultra", "hand-tuned entry wins over catalog")
    }
}

final class EffortConfigDocumentTests: XCTestCase {
    static let grokToml = """
    [cli]
    installer = "internal"

    [ui]
    fork_secondary_model = "grok-build"

    [models]
    default = "grok-4.5"
    default_reasoning_effort = "high"
    """

    static let codexToml = """
    notify = [
        "/some/app",
        "turn-ended",
    ]
    model = "gpt-5.6-sol"
    model_reasoning_effort = "medium"

    [marketplaces.openai-bundled]
    source = "/x"
    """

    func testReadsTomlKeyInsideSectionOnly() {
        XCTAssertEqual(ConfigDocument.readString(key: "default", section: "models", format: .toml, text: Self.grokToml), "grok-4.5")
        XCTAssertEqual(ConfigDocument.readString(key: "default_reasoning_effort", section: "models", format: .toml, text: Self.grokToml), "high")
        XCTAssertNil(ConfigDocument.readString(key: "default", section: "ui", format: .toml, text: Self.grokToml))
        XCTAssertEqual(ConfigDocument.readString(key: "model", section: nil, format: .toml, text: Self.codexToml), "gpt-5.6-sol")
        XCTAssertNil(ConfigDocument.readString(key: "source", section: nil, format: .toml, text: Self.codexToml))
    }

    func testRewritesTomlValueInPlacePreservingEverythingElse() throws {
        let out = try XCTUnwrap(ConfigDocument.writeString(key: "default_reasoning_effort", section: "models", value: "low", format: .toml, text: Self.grokToml))
        XCTAssertTrue(out.contains("default_reasoning_effort = \"low\""))
        XCTAssertFalse(out.contains("\"high\""))
        XCTAssertTrue(out.contains("default = \"grok-4.5\""))
        XCTAssertEqual(out.components(separatedBy: "\n").count, Self.grokToml.components(separatedBy: "\n").count)
        let top = try XCTUnwrap(ConfigDocument.writeString(key: "model_reasoning_effort", section: nil, value: "ultra", format: .toml, text: Self.codexToml))
        XCTAssertTrue(top.contains("model_reasoning_effort = \"ultra\""))
    }

    func testInsertsMissingTomlKeyAndRefusesMissingSection() {
        let out = ConfigDocument.writeString(key: "default_reasoning_effort", section: "models", value: "max", format: .toml, text: "[models]\ndefault = \"grok-4.5\"\n")
        XCTAssertEqual(out, "[models]\ndefault_reasoning_effort = \"max\"\ndefault = \"grok-4.5\"\n")
        XCTAssertNil(ConfigDocument.writeString(key: "x", section: "nope", value: "1", format: .toml, text: Self.grokToml))
    }

    func testJsonReadAndWrite() throws {
        let json = "{\n  \"model\": \"fable\",\n  \"effortLevel\": \"max\"\n}\n"
        XCTAssertEqual(ConfigDocument.readString(key: "model", section: nil, format: .json, text: json), "fable")
        let out = try XCTUnwrap(ConfigDocument.writeString(key: "effortLevel", section: nil, value: "xhigh", format: .json, text: json))
        XCTAssertTrue(out.contains("\"effortLevel\": \"xhigh\""))
        XCTAssertTrue(out.contains("\"model\": \"fable\""))
        XCTAssertNil(ConfigDocument.writeString(key: "k", section: nil, value: "v", format: .json, text: "{ broken"))
    }
}

final class EffortPromptIdleTests: XCTestCase {
    func testIdleEmptyPromptIsIdle() {
        XCTAssertTrue(PromptIdleDetector.isIdle(screenText: "● high · /effort\n────\n❯\n────\n⏵⏵ auto mode on"))
        XCTAssertTrue(PromptIdleDetector.isIdle(screenText: "output\n❯ \nfooter"))
    }

    func testTypedTextDialogsAndRunningTurnsAreNotIdle() {
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: "output\n❯ please refactor this file\nfooter"))
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: "❯ 1. Yes, I trust this folder\n  2. No, exit"))
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: "plain shell\n$ "))
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: "❯\nassistant said something\n❯ half-typed comman"))
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: "✻ Thinking… (esc to interrupt)\n\n❯"), "a running turn keeps the input open; a command typed now would be queued")
    }
}

final class EffortAutoScopeTests: XCTestCase {
    static let sessions = [
        EffortSessionRef(pid: 2, tty: "ttys004", hostName: "Terminal", hostBundleID: "com.apple.Terminal"),
        EffortSessionRef(pid: 3, tty: "ttys006", hostName: "Claude", hostBundleID: "com.anthropic.claudefordesktop"),
        EffortSessionRef(pid: 4, tty: "ttys009", hostName: "Claude", hostBundleID: "com.anthropic.claudefordesktop"),
        EffortSessionRef(pid: 5, tty: nil, hostName: "Claude", hostBundleID: "com.anthropic.claudefordesktop"),
    ]

    func testSelectedTerminalTabWins() {
        XCTAssertEqual(AutoScope.injectTTYs(sessions: Self.sessions, focus: FocusContext(frontmostApp: "Terminal", focusedTTY: "ttys004")), ["ttys004"])
    }

    func testOnlyTheSelectedTabIsTheSessionYouAreWorkingOn() {
        // Other tabs of the same app are other sessions, not the one meant.
        XCTAssertEqual(AutoScope.injectTTYs(sessions: Self.sessions, focus: FocusContext(frontmostApp: "Claude")), [])
        XCTAssertEqual(AutoScope.injectTTYs(sessions: Self.sessions, focus: FocusContext(frontmostApp: "Terminal")), [])
        XCTAssertEqual(AutoScope.injectTTYs(sessions: Self.sessions, focus: FocusContext(frontmostApp: "Terminal", focusedTTY: "ttys999")), [],
                       "a selected tab running no agent reaches nothing")
    }

    func testNoAgentInViewMeansNoLiveUpdate() {
        XCTAssertEqual(AutoScope.injectTTYs(sessions: Self.sessions, focus: FocusContext(frontmostApp: "Safari")), [])
        XCTAssertEqual(AutoScope.injectTTYs(sessions: Self.sessions, focus: FocusContext()), [])
    }

    func testAHostWhoseSessionsHaveNoTerminalIsNamedAsUnreachable() {
        // Claude Desktop's own sessions: hosted by the app, no tty to type into.
        let desktop = [
            EffortSessionRef(pid: 7, tty: nil, hostName: "Claude", hostBundleID: "com.anthropic.claudefordesktop"),
            EffortSessionRef(pid: 8, tty: nil, hostName: "Claude", hostBundleID: "com.anthropic.claudefordesktop"),
            EffortSessionRef(pid: 2, tty: "ttys004", hostName: "Terminal", hostBundleID: "com.apple.Terminal"),
        ]
        XCTAssertEqual(AutoScope.unreachableHost(sessions: desktop, focus: FocusContext(frontmostApp: "Claude")), "Claude")
        XCTAssertNil(AutoScope.unreachableHost(sessions: desktop, focus: FocusContext(frontmostApp: "Terminal")),
                     "a terminal session in view can be typed into")
        XCTAssertNil(AutoScope.unreachableHost(sessions: desktop, focus: FocusContext(frontmostApp: "Safari")),
                     "nothing in view, nothing to say")
        XCTAssertNil(AutoScope.unreachableHost(sessions: Self.sessions, focus: FocusContext(frontmostApp: "Claude")),
                     "a host with at least one reachable session is reached")
    }

    func testProviderProfileIDsMapToTargetIDs() {
        XCTAssertEqual(EffortState.targetID(forProviderID: "claude-work"), "claude")
        XCTAssertEqual(EffortState.targetID(forProviderID: "codex"), "codex")
        var state = EffortState()
        state.values = ["claude": "xhigh"]
        XCTAssertEqual(state.value(forProviderID: "claude-work"), "xhigh")
        XCTAssertNil(state.value(forProviderID: "cursor"))
    }
}

final class EffortDotStateTests: XCTestCase {
    func testDotsCountTheModelsScaleAndFillToTheValue() {
        var state = EffortState()
        state.values = ["claude": "high", "codex": "ultra", "grok": "nope"]
        state.scales = ["claude": ["low", "medium", "high", "xhigh"],
                        "codex": ["low", "medium", "high", "xhigh", "max", "ultra"],
                        "grok": ["minimal", "low", "medium", "high", "xhigh", "max"]]
        XCTAssertEqual(state.dots(forProviderID: "claude-work"), EffortDotState(count: 4, filled: 3))
        XCTAssertEqual(state.dots(forProviderID: "codex"), EffortDotState(count: 6, filled: 6))
        XCTAssertEqual(state.dots(forProviderID: "grok"), EffortDotState(count: 6, filled: 0), "a value off the scale fills nothing")
        XCTAssertNil(state.dots(forProviderID: "cursor"))
    }

    func testLiveOnlyDotsAreMarked() {
        var state = EffortState()
        state.values = ["claude": "xhigh"]
        state.scales = ["claude": BuiltInTargets.claude.scale(for: "claude-opus-5-5")]
        state.liveOnly = ["claude": BuiltInTargets.claude.liveOnly(for: "claude-opus-5-5")]
        XCTAssertEqual(state.dots(forProviderID: "claude"), EffortDotState(count: 6, filled: 4, liveOnly: [4, 5]))
    }
}

/// A live update reaches the one session in view — Grok's framed prompt
/// included — and a session mid-turn is not typed into.
final class LiveEffortReachTests: XCTestCase {
    /// Grok 1.0's idle composer: a framed `│ ❯` line and its key hints.
    private let grokIdle = """
    Hai thứ không nằm trong skill.
      ╭──────────────────────────────────────────╮
      │ ❯                                        │
      ╰──────────────────────────────────────────╯
      Shift+Tab:mode  │  Ctrl+x:shortcuts
    """

    func testGrokFramedPromptIsIdle() {
        XCTAssertTrue(PromptIdleDetector.isIdle(screenText: grokIdle))
    }

    func testGrokWithTypedTextOrAQueuedTurnIsNotIdle() {
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: grokIdle.replacingOccurrences(of: "│ ❯   ", with: "│ ❯ fix")))
        XCTAssertFalse(PromptIdleDetector.isIdle(screenText: grokIdle + "\n  Enter:queue  │  Esc:stop"))
    }

    /// One session only: the selected tab of Terminal in front — Grok's
    /// here — and none of the others, whatever else is open.
    func testOnlyTheSessionInViewIsReached() {
        let sessions = [
            EffortSessionRef(pid: 2, tty: "ttys004", hostName: "Terminal", hostBundleID: "com.apple.Terminal", agent: "grok"),
            EffortSessionRef(pid: 3, tty: "ttys006", hostName: "Terminal", hostBundleID: "com.apple.Terminal"),
            EffortSessionRef(pid: 5, tty: nil, hostName: "Claude", hostBundleID: "com.anthropic.claudefordesktop"),
        ]
        XCTAssertEqual(AutoScope.injectTTYs(sessions: sessions,
                                            focus: FocusContext(frontmostApp: "Terminal", focusedTTY: "ttys004")),
                       ["ttys004"])
        XCTAssertEqual(AutoScope.injectTTYs(sessions: sessions, focus: FocusContext(frontmostApp: "Claude")), [],
                       "nothing typed into Terminal while another app is in front")
    }

    /// Grok's catalog as it ships: each model with the levels it accepts.
    /// (~/.grok/models_cache.json, 1.0.41: keyed by model, details under `info`.)
    private let grokCatalog = """
    {"fetched_at":"2026-09-28T05:58:57Z","models":{
      "grok-4.7":{"info":{"id":"grok-4.7","model":"grok-4.7","supports_reasoning_effort":true,
        "reasoning_efforts":[{"id":"xhigh","value":"xhigh"},{"id":"high","value":"high"},
                             {"id":"medium","value":"medium"},{"id":"low","value":"low"}]},
        "api_key":null},
      "grok-4.5":{"info":{"id":"grok-4.5","model":"grok-4.5","supports_reasoning_effort":true,
        "reasoning_efforts":[{"id":"high","value":"high"},{"id":"medium","value":"medium"},{"id":"low","value":"low"}]}}
    }}
    """

    func testGrokCatalogGivesEachModelItsOwnScale() {
        let levels = GrokCatalog.supportedLevels(json: grokCatalog)
        XCTAssertEqual(levels["grok-4.7"], ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(levels["grok-4.5"], ["low", "medium", "high"])
        let grok = GrokCatalog.fill(BuiltInTargets.grok, with: levels)
        XCTAssertEqual(grok.value(for: .max, model: "grok-4.5"), "high", "grok-4.5 has no max")
        XCTAssertEqual(grok.value(for: .max, model: "grok-4.7"), "xhigh")
        // High on the lid is high wherever the model has it.
        XCTAssertEqual(EffortLevel.allCases.map { grok.value(for: $0, model: "grok-4.5") },
                       ["low", "medium", "high", "high", "high"])
        XCTAssertEqual(EffortLevel.allCases.map { grok.value(for: $0, model: "grok-4.7") },
                       ["low", "medium", "high", "xhigh", "xhigh"])
    }

    @MainActor
    func testTheCommandFollowsTheModelTheSessionRuns() {
        let grok = GrokCatalog.fill(BuiltInTargets.grok, with: GrokCatalog.supportedLevels(json: grokCatalog))
        XCTAssertEqual(EffortController.command(agent: "grok", model: "grok-4.7", level: .max, target: grok), "/effort xhigh")
        XCTAssertEqual(EffortController.command(agent: "grok", model: "grok-4.5", level: .max, target: grok), "/effort high")
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-fable-5-1", level: .max,
                                                target: BuiltInTargets.claude), "/effort max")
        XCTAssertEqual(EffortController.command(agent: "claude", model: nil, level: .medium,
                                                target: BuiltInTargets.claude), "/effort medium")
    }

    func testTheNewestReplyNamesTheClaudeModel() {
        let tail = #"""
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}
        {"type":"user","message":{"content":"switch"}}
        {"type":"assistant","message":{"model":"claude-fable-5-1","content":[]}}
        """#
        XCTAssertEqual(SessionModels.latestModel(inTranscriptTail: tail), "claude-fable-5-1")
        XCTAssertNil(SessionModels.latestModel(inTranscriptTail: "{}"))
    }

    /// Grok's session took the level while Claude Desktop was in front: the
    /// card is Grok's, because Grok is where the change landed.
    @MainActor
    func testTheCardFollowsTheSessionThatTookIt() {
        let live = [
            EffortController.LiveSession(ref: EffortSessionRef(pid: 10, tty: nil, hostName: "Claude",
                                                               hostBundleID: "com.anthropic.claudefordesktop"),
                                         name: "SPYX"),
            EffortController.LiveSession(ref: EffortSessionRef(pid: 20, tty: "ttys004", hostName: "Terminal",
                                                               hostBundleID: "com.apple.Terminal", agent: "grok"),
                                         name: "Grok"),
        ]
        let sent = [EffortInjector.Attempt(pid: 20, tty: "ttys004", outcome: .sent)]
        XCTAssertEqual(EffortController.cardAgent(attempts: sent, live: live,
                                                  focus: FocusContext(frontmostApp: "Claude")), "grok")
        let waiting = [EffortInjector.Attempt(pid: 20, tty: "ttys004", outcome: .promptNotIdle)]
        XCTAssertEqual(EffortController.cardAgent(attempts: waiting, live: live, focus: FocusContext()), "grok")
    }

    @MainActor
    func testTheCardComesOutOfTheAgentsOwnRing() {
        let model = NotchViewModel()
        model.snapshots = ["claude", "codex", "grok"].map { id in
            ProviderSnapshot(id: id, displayName: id, glyph: .claude, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.2)], headlineID: "w")
        }
        model.effort = EffortState(values: ["claude": "high", "codex": "high", "grok": "high"])
        model.activeEffortAlert = EffortChangeEvent(level: .high, values: [], at: Date(), agent: "grok")
        XCTAssertEqual(model.effortAlertIndex(), 2)
        model.activeEffortAlert = EffortChangeEvent(level: .high, values: [], at: Date())
        XCTAssertEqual(model.effortAlertIndex(), 0)
    }
}

/// Claude Desktop's sessions: which one it is showing, whether it is idle,
/// and its model — read from the files Claude Code and Desktop keep.
final class DesktopSessionTests: XCTestCase {
    private func home(status: String, focusedAt: Double, model: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopSessionTests-\(UUID().uuidString)")
        let sessions = home.appendingPathComponent(".claude/sessions")
        let records = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/acct/org")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try #"{"pid":83408,"sessionId":"s1","entrypoint":"claude-desktop","hostSessionId":"local_abc","status":"\#(status)"}"#
            .write(to: sessions.appendingPathComponent("83408.json"), atomically: true, encoding: .utf8)
        try #"{"sessionId":"local_abc","lastFocusedAt":\#(Int(focusedAt)),"model":"\#(model)","effort":"high"}"#
            .write(to: records.appendingPathComponent("local_abc.json"), atomically: true, encoding: .utf8)
        return home
    }

    func testReadsIdleFocusAndModel() throws {
        let root = try home(status: "idle", focusedAt: 1_790_617_874_483, model: "claude-opus-5-5")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try XCTUnwrap(SessionModels.desktop(pid: 83408, home: root))
        XCTAssertTrue(session.isIdle)
        XCTAssertEqual(session.lastFocusedAt, 1_790_617_874_483)
        XCTAssertEqual(session.model, "claude-opus-5-5")
    }

    func testABusySessionIsNotIdle() throws {
        let root = try home(status: "busy", focusedAt: 1, model: "claude-fable-5-1")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(SessionModels.desktop(pid: 83408, home: root)?.isIdle, false)
    }

    func testATerminalSessionIsNotDesktops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopSessionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try #"{"pid":19027,"sessionId":"s2","entrypoint":"cli","status":"idle"}"#
            .write(to: sessions.appendingPathComponent("19027.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(SessionModels.desktop(pid: 19027, home: root))
    }

    func testTheComposerIsOnUntilSwitchedOff() throws {
        let suite = "DesktopSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ClaudeDesktopComposer.isEnabled(defaults))
        defaults.set(false, forKey: ClaudeDesktopComposer.defaultsKey)
        XCTAssertFalse(ClaudeDesktopComposer.isEnabled(defaults))
    }
}
