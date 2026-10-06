import XCTest
import LidEffortCore
@testable import LidEffort

final class EffortOfferTests: XCTestCase {
    func testClaudesMaxIsLiveOnly() {
        let offer = EffortOffer.make(target: BuiltInTargets.claude, installed: true, model: "opus[1m]",
                                     current: "high", listed: nil)
        XCTAssertEqual(offer.liveOnly, ["max", "ultracode"])
        XCTAssertEqual(offer.liveAtTop, "max")
        XCTAssertEqual(offer.liveChoices, ["ultracode"])
        XCTAssertEqual(offer.perLevel, ["low", "medium", "high", "xhigh", "xhigh"])
        XCTAssertNil(offer.warning)
    }

    func testUltracodeIsOfferedOnlyWhereClaudeCodeTakesIt() {
        let older = EffortOffer.make(target: BuiltInTargets.claude, installed: true, model: "claude-opus-4-6",
                                     current: "high", listed: nil)
        XCTAssertEqual(older.liveOnly, ["max"])
        XCTAssertTrue(older.liveChoices.isEmpty, "no ultracode on a model without xhigh")
        let codex = EffortOffer.make(target: BuiltInTargets.codex, installed: true, model: "gpt-5.6-sol",
                                     current: "high", listed: nil)
        XCTAssertTrue(codex.liveOnly.isEmpty)
        XCTAssertNil(codex.liveAtTop)
    }

    @MainActor
    func testUltracodeIsTypedAsItIsAndOnlyWhereItExists() {
        let claude = BuiltInTargets.claude
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-opus-5-5", level: .medium,
                                                target: claude, choice: "ultracode"), "/effort ultracode")
        XCTAssertNil(EffortController.command(agent: "claude", model: "claude-opus-4-6", level: .max,
                                              target: claude, choice: "ultracode"))
        XCTAssertNil(EffortController.command(agent: "grok", model: nil, level: .max,
                                              target: BuiltInTargets.grok, choice: "ultracode"))
        XCTAssertNil(EffortController.command(agent: "grok", model: nil, level: .max,
                                              target: claude, choice: "ultracode"), "another agent's session")
        // The lid's top still types max, never ultracode.
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-opus-5-5", level: .max,
                                                target: claude), "/effort max")
        XCTAssertTrue(EffortController.isLiveChoice("ultracode", agent: "claude", model: "claude-opus-5-5", target: claude))
        XCTAssertFalse(EffortController.isLiveChoice("max", agent: "claude", model: "claude-opus-5-5", target: claude))
        XCTAssertFalse(EffortController.isLiveChoice("xhigh", agent: "claude", model: "claude-opus-5-5", target: claude))
        XCTAssertTrue(EffortInjector.isEffortCommand("/effort ultracode"))
    }

    func testTheConfigWriterNeverWritesUltracode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("settings.json")
        let original = "{\n  \"model\": \"claude-opus-5-5\",\n  \"effortLevel\": \"high\"\n}\n"
        try original.write(to: path, atomically: true, encoding: .utf8)
        let base = BuiltInTargets.claude
        // Even with a band that names it — which the overrides file refuses
        // anyway — every lid level leaves ultracode out of the config.
        var bands = base.bands
        bands[EffortTarget.wildcard] = ["low", "medium", "high", "xhigh", "ultracode"]
        let target = EffortTarget(id: base.id, displayName: base.displayName, configPath: path.path, format: base.format,
                                  effortKey: base.effortKey, modelKey: base.modelKey, bands: bands, scales: base.scales,
                                  liveOnlyValues: base.liveOnlyValues)
        for level in EffortLevel.allCases {
            let result = EffortTargetWriter.apply(level: level, to: target, dryRun: false)
            XCTAssertNotEqual(result.value, "ultracode", "\(level)")
            let text = try String(contentsOf: path, encoding: .utf8)
            XCTAssertFalse(text.contains("ultracode"), "\(level): \(text)")
        }
        // And the built-in bands land on xhigh at the lid's top.
        let builtIn = EffortTarget(id: base.id, displayName: base.displayName, configPath: path.path, format: base.format,
                                   effortKey: base.effortKey, modelKey: base.modelKey, bands: base.bands, scales: base.scales,
                                   liveOnlyValues: base.liveOnlyValues)
        XCTAssertEqual(EffortTargetWriter.apply(level: .max, to: builtIn, dryRun: false).value, "xhigh")
        XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("ultracode"))
    }

    func testAModelWithNoEffortSaysSo() {
        let offer = EffortOffer.make(target: BuiltInTargets.claude, installed: true, model: "claude-haiku-4-5",
                                     current: nil, listed: nil)
        XCTAssertNil(offer.perLevel)
        XCTAssertNotNil(offer.warning)
        XCTAssertTrue(offer.liveOnly.isEmpty)
        XCTAssertNil(offer.liveAtTop)
    }

    func testAModelMissingFromTheAgentsCatalogIsFlagged() {
        let offer = EffortOffer.make(target: BuiltInTargets.codex, installed: true, model: "gpt-5.6-sol",
                                     current: "high", listed: ["gpt-5.6-terra", "gpt-5.5"])
        XCTAssertTrue(offer.warning?.contains("gpt-5.6-sol") == true)
        let listed = EffortOffer.make(target: BuiltInTargets.codex, installed: true, model: "gpt-5.5",
                                      current: "high", listed: ["gpt-5.6-terra", "gpt-5.5"])
        XCTAssertNil(listed.warning)
    }

    func testAnAgentNotOnThisMac() {
        let offer = EffortOffer.make(target: BuiltInTargets.hermes, installed: false, model: nil, current: nil, listed: nil)
        XCTAssertFalse(offer.installed)
        XCTAssertNotNil(offer.warning)
    }

    @MainActor
    func testNothingIsTypedIntoAModelWithNoEffort() {
        XCTAssertNil(EffortController.command(agent: "claude", model: "claude-haiku-4-5-20251001", level: .high,
                                              target: BuiltInTargets.claude))
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-opus-4-6", level: .max,
                                                target: BuiltInTargets.claude), "/effort max")
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-sonnet-4-6", level: .xhigh,
                                                target: BuiltInTargets.claude), "/effort high")
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-opus-4-5", level: .max,
                                                target: BuiltInTargets.claude), "/effort high", "no max on 4.5")
    }

    func testHookStatusIsReadTheSameWayForEveryAgent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let codex = dir.appendingPathComponent("config.toml")
        try "model = \"x\"\n".write(to: codex, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentHooks.isCodexInstalled(at: codex))
        try AgentHooks.installCodex(executable: "/A/spyx", at: codex)
        XCTAssertTrue(AgentHooks.isCodexInstalled(at: codex))
        let cursor = dir.appendingPathComponent("hooks.json")
        XCTAssertFalse(AgentHooks.isCursorInstalled(at: cursor))
        try AgentHooks.installCursor(executable: "/A/spyx", at: cursor)
        XCTAssertTrue(AgentHooks.isCursorInstalled(at: cursor))
        XCTAssertEqual(AgentHooks.links().map(\.id),
                       ["claude", "codex", "grok", "cursor", "droid", "antigravity", "copilot", "kimi", "gemini-api", "opencode"])
    }
}
