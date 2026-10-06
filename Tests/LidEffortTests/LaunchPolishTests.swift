import XCTest
import LidEffortCore
@testable import LidEffort

/// The touchpoints fixed for launch, pinned.
@MainActor
final class LaunchPolishTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "launch-\(UUID())")! }

    func testHooksWaitForConsent() {
        let d = defaults()
        XCTAssertFalse(HookConsent.given(d), "a fresh install has not agreed to anything")
        HookConsent.grant(d)
        XCTAssertTrue(HookConsent.given(d))
    }

    func testSomeoneSetUpBeforeKeepsTheirHooks() {
        let d = defaults()
        d.set(true, forKey: SetupGate.seenKey)
        HookConsent.migrate(d)
        XCTAssertTrue(HookConsent.given(d))
        let fresh = defaults()
        HookConsent.migrate(fresh)
        XCTAssertFalse(HookConsent.given(fresh))
    }

    func testHooksNeverPointIntoADiskImage() {
        let d = defaults()
        XCTAssertTrue(HookConsent.locationAllows(.applications, environment: [:], defaults: d))
        XCTAssertFalse(HookConsent.locationAllows(.diskImage, environment: ["SPYX_HOOKS_ANYWHERE": "1"], defaults: d))
        XCTAssertFalse(HookConsent.locationAllows(.translocated, environment: [:], defaults: d))
        XCTAssertFalse(HookConsent.locationAllows(.elsewhere, environment: [:], defaults: d))
        XCTAssertTrue(HookConsent.locationAllows(.elsewhere, environment: ["SPYX_HOOKS_ANYWHERE": "1"], defaults: d))
    }

    func testAFreshInstallShowsTheAgentsItFinds() {
        let codexOnly = Preferences.freshDisconnected(exists: { $0.hasSuffix("/.codex") }, appInstalled: { _ in false })
        XCTAssertFalse(codexOnly.contains("codex"))
        XCTAssertTrue(codexOnly.contains("claude"), "no Claude Code here, so no Claude ring asking to sign in")
        XCTAssertTrue(codexOnly.contains("grok"))
        let nothing = Preferences.freshDisconnected(exists: { _ in false }, appInstalled: { _ in false })
        XCTAssertEqual(nothing, Preferences.disconnectedByDefault, "nothing found: the three the lid drives, not an empty pill")
    }

    func testALimitIsNeverALimitLimit() {
        XCTAssertEqual(ResetCheer.limitPhrase("Weekly limit"), "Weekly limit")
        XCTAssertEqual(ResetCheer.limitPhrase("5h limit"), "5h limit")
        XCTAssertEqual(ResetCheer.limitPhrase("Weekly"), L10n.t("Weekly limit"))
    }

    func testEffortLevelsReadAsWords() {
        XCTAssertEqual(EffortLevel.xhigh.displayName, L10n.t("Extra high"))
        XCTAssertNotEqual(EffortLevel.xhigh.displayName, "Xhigh")
    }

    func testRecapCountsAreSingularForOne() {
        var recap = DailyRecap()
        recap.agents = [DailyRecap.Agent(name: "Codex", sessions: 1, toolCalls: 1, tokens: 10)]
        XCTAssertTrue(recap.subtitle.hasPrefix(L10n.t("1 session")))
        XCTAssertFalse(recap.subtitle.contains("1 sessions"))
    }

    func testABugReportCarriesOnlyTheVersions() {
        let url = BugReport.url(version: "1.1.0", macOS: "Version 26.0").absoluteString
        XCTAssertTrue(url.hasPrefix("https://github.com/chrisnguyen1211/spyxdotlol/issues/new"))
        XCTAssertTrue(url.contains("1.1.0"))
        XCTAssertFalse(url.contains(NSUserName()), "nothing about the person")
    }
}

@MainActor
final class NewProviderMigrationTests: XCTestCase {
    func testAnUpdateDoesNotSwitchOnProvidersNobodyChose() {
        let defaults = UserDefaults(suiteName: "migrate-\(UUID())")!
        defaults.set(["cursor"], forKey: "hiddenProviders")
        let preferences = Preferences(defaults: defaults)
        for id in Preferences.introducedLater {
            XCTAssertTrue(preferences.disconnectedProviders.contains(id), id)
        }
        XCTAssertTrue(preferences.disconnectedProviders.contains("cursor"))
        // Switched on once, it stays on: the newcomer is introduced only once.
        preferences.disconnectedProviders.remove("amp")
        let again = Preferences(defaults: defaults)
        XCTAssertFalse(again.disconnectedProviders.contains("amp"))
    }
}

final class UltracodeCommandTests: XCTestCase {
    func testTheOnlyTwoWordEffortCommandIsUltracodeOff() {
        XCTAssertTrue(EffortInjector.isEffortCommand("/effort ultracode off"))
        XCTAssertTrue(EffortInjector.isEffortCommand("/effort ultracode"))
        XCTAssertFalse(EffortInjector.isEffortCommand("/effort high now"))
        XCTAssertFalse(EffortInjector.isEffortCommand("/effort ultracode off; rm"))
    }

    @MainActor
    func testUltracodeOffIsOnlyForClaude() {
        XCTAssertEqual(EffortController.command(agent: "claude", model: "claude-opus-5-5", level: .max,
                                                target: BuiltInTargets.claude, choice: "ultracode off"),
                       "/effort ultracode off")
        XCTAssertNil(EffortController.command(agent: "grok", model: "grok-4.7", level: .max,
                                              target: BuiltInTargets.grok, choice: "ultracode off"))
    }
}

final class LidOneAgentTests: XCTestCase {
    /// The lid writes the agent being worked with and nobody else — dry run,
    /// so no config on this Mac is touched.
    func testOnlyTheChosenAgentIsWritten() {
        for agent in ["claude", "codex", "grok"] {
            let results = EffortTargetWriter.apply(level: .low, only: agent, dryRun: true)
            for result in results where result.targetID != agent {
                if case .written = result.outcome { XCTFail("\(result.targetID) was written for \(agent)") }
            }
            XCTAssertEqual(Set(results.map(\.targetID)), Set(EffortTargetWriter.loadTargets().map(\.id)),
                           "every agent is still reported, so every ring keeps its value")
        }
    }
}
