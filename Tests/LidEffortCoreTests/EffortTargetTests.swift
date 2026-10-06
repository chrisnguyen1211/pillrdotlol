import Foundation
import Testing
@testable import LidEffortCore

struct EffortTargetTests {
    @Test func claudeNeverEmitsMaxBecauseSettingsCannotPersistIt() {
        let claude = BuiltInTargets.claude
        #expect(claude.value(for: .max, model: "fable") == "xhigh")
        #expect(claude.value(for: .xhigh, model: nil) == "xhigh")
        #expect(claude.value(for: .low, model: "sonnet") == "low")
    }

    @Test func codexUsesPerModelScale() {
        let codex = BuiltInTargets.codex
        #expect(codex.value(for: .max, model: "gpt-5.6-sol") == "ultra")
        #expect(codex.value(for: .max, model: "gpt-5.6-luna") == "max")
        #expect(codex.value(for: .max, model: "gpt-5.5") == "xhigh")
        #expect(codex.value(for: .high, model: "gpt-5.5") == "high")
        // Unknown model falls back to the wildcard row.
        #expect(codex.value(for: .max, model: "gpt-9") == "xhigh")
    }

    @Test func proportionalMappingCoversWholeScale() {
        #expect(BandMapping.proportional(from: ["a", "b", "c", "d", "e"]) == ["a", "b", "c", "d", "e"])
        #expect(BandMapping.proportional(from: ["low", "medium", "high", "xhigh"]) == ["low", "medium", "high", "high", "xhigh"])
        #expect(BandMapping.proportional(from: ["only"]) == ["only", "only", "only", "only", "only"])
        #expect(BandMapping.proportional(from: []) == nil)
    }

    @Test func overridesReplaceBandsAndEnabledOnly() {
        let json = """
        {
          "codex": { "enabled": false },
          "grok": { "bands": { "grok-4.6": ["minimal", "low", "medium", "high", "max"], "bad": ["x"] } }
        }
        """
        let targets = TargetOverrides.apply(json, to: BuiltInTargets.all)
        let codex = targets.first { $0.id == "codex" }!
        let grok = targets.first { $0.id == "grok" }!
        #expect(!codex.enabled)
        #expect(grok.enabled)
        #expect(grok.value(for: .low, model: "grok-4.6") == "minimal")
        #expect(grok.bands["bad"] == nil, "a non-5-entry list must be ignored, not half-applied")
        #expect(grok.value(for: .max, model: "grok-4.5") == "high", "a built-in row not overridden is untouched")
    }

    @Test func malformedOverridesLeaveTargetsUnchanged() {
        #expect(TargetOverrides.apply("not json", to: BuiltInTargets.all) == BuiltInTargets.all)
    }

    @Test func codexCatalogFillsUnknownModelsWithoutTouchingTunedOnes() {
        let cache = """
        {"models": [
          {"slug": "gpt-5.6-sol", "supported_reasoning_levels": ["low","medium","high","xhigh","max","ultra"]},
          {"slug": "gpt-7-new", "supported_reasoning_levels": ["low","medium","high"]},
          {"slug": "broken", "supported_reasoning_levels": []}
        ]}
        """
        let catalog = CodexCatalog.supportedLevels(json: cache)
        #expect(catalog["gpt-7-new"] == ["low", "medium", "high"])
        #expect(catalog["broken"] == nil)
        let filled = CodexCatalog.fill(BuiltInTargets.codex, with: catalog)
        #expect(filled.value(for: .max, model: "gpt-7-new") == "high")
        #expect(filled.value(for: .max, model: "gpt-5.6-sol") == "ultra", "hand-tuned entry wins over catalog")
    }
}

struct EffortScaleTests {
    @Test func scaleIsPerModelWithCatalogAsTruth() {
        #expect(BuiltInTargets.claude.scale(for: "sonnet") == ["low", "medium", "high", "xhigh", "max", "ultracode"])
        #expect(BuiltInTargets.codex.scale(for: "gpt-5.6-sol").count == 6)
        #expect(BuiltInTargets.codex.scale(for: "gpt-5.5") == ["low", "medium", "high", "xhigh"])
        #expect(BuiltInTargets.grok.scale(for: "grok-4.5") == ["low", "medium", "high"])
        let filled = CodexCatalog.fill(BuiltInTargets.codex, with: ["gpt-7": ["low", "high"]])
        #expect(filled.scale(for: "gpt-7") == ["low", "high"])
    }

    @Test func scaleFallsBackToDistinctBandValues() {
        let target = EffortTarget(id: "x", displayName: "X", configPath: "/x", format: .json,
                                  effortKey: "e", modelKey: "m",
                                  bands: ["*": ["a", "b", "b", "c", "c"]])
        #expect(target.scale(for: nil) == ["a", "b", "c"])
    }
}

@Suite struct TargetOverridesWritingTests {
    @Test func switchingAnAgentOffWritesOnlyThat() {
        let json = TargetOverrides.settingEnabled(false, for: "codex", in: nil)
        let targets = TargetOverrides.apply(json, to: BuiltInTargets.all)
        #expect(targets.first { $0.id == "codex" }?.enabled == false)
        #expect(targets.first { $0.id == "claude" }?.enabled == true)
    }

    @Test func everythingElseInTheFileIsKept() throws {
        let existing = #"{"grok":{"bands":{"grok-4.6":["minimal","low","medium","high","max"]}},"codex":{"enabled":false,"note":"mine"}}"#
        let json = TargetOverrides.settingEnabled(true, for: "codex", in: existing)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((root["codex"] as? [String: Any])?["enabled"] == nil, "on is the default, so it is not written")
        #expect((root["codex"] as? [String: Any])?["note"] as? String == "mine", "keys it does not know survive")
        #expect(root["grok"] != nil, "another agent's bands survive")
    }

    @Test func switchingBackOnLeavesNoEmptyEntry() throws {
        let off = TargetOverrides.settingEnabled(false, for: "grok", in: nil)
        let on = TargetOverrides.settingEnabled(true, for: "grok", in: off)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(on.utf8)) as? [String: Any])
        #expect(root.isEmpty)
    }

    @Test func aBrokenFileIsReplacedNotAppendedTo() {
        let json = TargetOverrides.settingEnabled(false, for: "claude", in: "{not json")
        #expect(TargetOverrides.apply(json, to: BuiltInTargets.all).first { $0.id == "claude" }?.enabled == false)
    }
}
