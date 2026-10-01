import Testing
@testable import LidEffortCore

struct ConfigDocumentTests {
    // Verbatim shape of the real ~/.grok/config.toml and ~/.codex/config.toml.
    static let grokToml = """
    [cli]
    installer = "internal"
    auto_update = true

    [ui]
    fork_secondary_model = "grok-build"
    permission_mode = "always-approve"

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

    @Test func readsTomlKeyInsideSection() {
        #expect(ConfigDocument.readString(key: "default", section: "models", format: .toml, text: Self.grokToml) == "grok-4.5")
        #expect(ConfigDocument.readString(key: "default_reasoning_effort", section: "models", format: .toml, text: Self.grokToml) == "high")
        // Same key name in the wrong section must not match.
        #expect(ConfigDocument.readString(key: "default", section: "ui", format: .toml, text: Self.grokToml) == nil)
    }

    @Test func readsTopLevelTomlKeyOnlyBeforeFirstSection() {
        #expect(ConfigDocument.readString(key: "model", section: nil, format: .toml, text: Self.codexToml) == "gpt-5.6-sol")
        #expect(ConfigDocument.readString(key: "source", section: nil, format: .toml, text: Self.codexToml) == nil)
    }

    @Test func rewritesTomlValueInPlacePreservingEverythingElse() {
        let out = ConfigDocument.writeString(key: "default_reasoning_effort", section: "models", value: "low", format: .toml, text: Self.grokToml)!
        #expect(out.contains("default_reasoning_effort = \"low\""))
        #expect(!out.contains("\"high\""))
        #expect(out.contains("default = \"grok-4.5\""))
        #expect(out.components(separatedBy: "\n").count == Self.grokToml.components(separatedBy: "\n").count)
    }

    @Test func rewritesTopLevelTomlValue() {
        let out = ConfigDocument.writeString(key: "model_reasoning_effort", section: nil, value: "ultra", format: .toml, text: Self.codexToml)!
        #expect(out.contains("model_reasoning_effort = \"ultra\""))
        #expect(out.contains("model = \"gpt-5.6-sol\""))
    }

    @Test func insertsMissingTomlKeyAtSectionStart() {
        let toml = "[models]\ndefault = \"grok-4.5\"\n"
        let out = ConfigDocument.writeString(key: "default_reasoning_effort", section: "models", value: "max", format: .toml, text: toml)!
        #expect(out == "[models]\ndefault_reasoning_effort = \"max\"\ndefault = \"grok-4.5\"\n")
    }

    @Test func refusesToInventAMissingTomlSection() {
        #expect(ConfigDocument.writeString(key: "x", section: "nope", value: "1", format: .toml, text: Self.grokToml) == nil)
    }

    @Test func jsonReadAndWriteMatchSettingsPatchBehaviour() {
        let json = "{\n  \"model\": \"fable\",\n  \"effortLevel\": \"max\"\n}\n"
        #expect(ConfigDocument.readString(key: "model", section: nil, format: .json, text: json) == "fable")
        let out = ConfigDocument.writeString(key: "effortLevel", section: nil, value: "xhigh", format: .json, text: json)!
        #expect(out.contains("\"effortLevel\": \"xhigh\""))
        #expect(out.contains("\"model\": \"fable\""))
        #expect(ConfigDocument.writeString(key: "k", section: nil, value: "v", format: .json, text: "{ broken") == nil)
    }
}
