import Testing
@testable import LidEffortCore

/// Each agent's levels as its own model takes them — read off Claude Code
/// 2.1, Grok 1.0's catalog and Hermes 0.5 — and the YAML Hermes keeps them in.
struct PerModelEffortTests {
    static let hermesYaml = """
    model:
      default: minimax/MiniMax-M2.7-highspeed
      provider: minimax
    toolsets:
    - hermes-cli
    agent:
      max_turns: 60
      reasoning_effort: medium  # how hard it thinks
      personalities:
        reasoning_effort: not-this-one
    display:
      show_reasoning: false
    """

    @Test func readsHermesModelAndEffortFromYAML() {
        #expect(ConfigDocument.readString(key: "default", section: "model", format: .yaml, text: Self.hermesYaml)
                == "minimax/MiniMax-M2.7-highspeed")
        #expect(ConfigDocument.readString(key: "reasoning_effort", section: "agent", format: .yaml, text: Self.hermesYaml) == "medium")
    }

    @Test func writesOnlyTheOneYAMLLineKeepingItsComment() {
        let out = ConfigDocument.writeString(key: "reasoning_effort", section: "agent", value: "xhigh",
                                             format: .yaml, text: Self.hermesYaml)!
        #expect(out.contains("  reasoning_effort: xhigh  # how hard it thinks"))
        #expect(out.contains("    reasoning_effort: not-this-one"), "a deeper key of the same name is left alone")
        #expect(out.components(separatedBy: "\n").count == Self.hermesYaml.components(separatedBy: "\n").count)
    }

    @Test func insertsAMissingYAMLKeyAtTheSectionsIndent() {
        let text = "agent:\n    max_turns: 60\nother: 1\n"
        let out = ConfigDocument.writeString(key: "reasoning_effort", section: "agent", value: "low", format: .yaml, text: text)
        #expect(out == "agent:\n    reasoning_effort: low\n    max_turns: 60\nother: 1\n")
        #expect(ConfigDocument.writeString(key: "reasoning_effort", section: "nope", value: "low", format: .yaml, text: text) == nil)
        #expect(ConfigDocument.writeString(key: "reasoning_effort", section: "agent", value: "a: b", format: .yaml, text: text) == nil)
    }

    @Test func claudeLevelsFollowTheModel() {
        let claude = BuiltInTargets.claude
        func levels(_ model: String?) -> [String?] { EffortLevel.allCases.map { claude.value(for: $0, model: model) } }
        #expect(levels("claude-opus-5-5") == ["low", "medium", "high", "xhigh", "xhigh"])
        #expect(levels("opus[1m]") == ["low", "medium", "high", "xhigh", "xhigh"])
        #expect(levels("claude-sonnet-4-6") == ["low", "medium", "high", "high", "high"], "no xhigh on 4.6")
        #expect(levels("claude-opus-4-5-20251101") == ["low", "medium", "high", "high", "high"], "dated ids are the family's")
        #expect(levels("claude-haiku-4-5-20251001") == [nil, nil, nil, nil, nil], "Haiku 4.5 takes no effort")
        #expect(!claude.takesEffort(model: "haiku"))
        #expect(!claude.takesEffort(model: "claude-3-7-sonnet-20250219"))
        #expect(claude.scale(for: "claude-opus-4-6") == ["low", "medium", "high", "max"])
        #expect(claude.scale(for: "claude-opus-5-5").suffix(2) == ["max", "ultracode"])
    }

    @Test func ultracodeIsLiveOnlyAndOnlyOnModelsWithXhigh() {
        let claude = BuiltInTargets.claude
        // Newer models: past max, live only, and no band reaches it.
        #expect(claude.scale(for: "claude-opus-5-5").last == "ultracode")
        #expect(claude.scale(for: "opus[1m]").last == "ultracode")
        #expect(claude.liveOnly(for: "claude-opus-5-5") == ["max", "ultracode"])
        #expect(EffortLevel.allCases.allSatisfy { claude.value(for: $0, model: "claude-opus-5-5") != "ultracode" })
        // Opus and Sonnet 4.6 have max but no xhigh, and Claude Code turns
        // ultracode down on them; Opus 4.5 and Haiku have neither.
        #expect(!claude.scale(for: "claude-opus-4-6").contains("ultracode"))
        #expect(!claude.scale(for: "claude-sonnet-4-6").contains("ultracode"))
        #expect(claude.liveOnly(for: "claude-opus-4-6") == ["max"])
        #expect(claude.liveOnly(for: "claude-opus-4-5").isEmpty)
        #expect(claude.liveOnly(for: "claude-haiku-4-5").isEmpty)
        // Nobody else has it.
        #expect(BuiltInTargets.all.filter { $0.id != "claude" }.allSatisfy { $0.liveOnly(for: nil).isEmpty })
    }

    @Test func aBandNamingALiveOnlyValueIsIgnored() {
        let json = #"{"claude": {"bands": {"*": ["low","medium","high","xhigh","ultracode"], "x": ["low","medium","high","max","max"]}}}"#
        let claude = TargetOverrides.apply(json, to: [BuiltInTargets.claude])[0]
        #expect(claude.value(for: .max, model: nil) == "xhigh")
        #expect(claude.bands["x"] == nil)
    }

    @Test func familyMatchingNeedsABoundary() {
        let claude = BuiltInTargets.claude
        #expect(claude.entry(for: "claude-opus-4-6[1m]") == "claude-opus-4-6")
        #expect(claude.entry(for: "claude-opus-4-60") == nil, "4-60 is not 4-6")
        #expect(claude.entry(for: "claude-3") == "claude-3")
    }

    @Test func grokWithoutItsCatalogStopsAtXhigh() {
        let grok = BuiltInTargets.grok
        #expect(grok.value(for: .max, model: "grok-4.7") == "xhigh")
        #expect(grok.value(for: .max, model: "grok-4.5") == "high")
        #expect(!grok.scale(for: nil).contains("max"))
    }

    @Test func hermesTakesItsOwnScale() {
        let hermes = BuiltInTargets.hermes
        #expect(hermes.value(for: .low, model: "minimax/MiniMax-M2.7") == "low")
        #expect(hermes.value(for: .max, model: nil) == "xhigh")
        #expect(BuiltInTargets.all.map(\.id) == ["claude", "codex", "grok", "hermes", "droid", "copilot", "kimi"])
    }

    @Test func aValueAboveEveryBandIsTheTopLevel() {
        #expect(BuiltInTargets.claude.level(reaching: "max", model: "claude-opus-5-5") == .max)
        #expect(BuiltInTargets.claude.level(reaching: "xhigh", model: "claude-opus-5-5") == .xhigh)
    }
}
