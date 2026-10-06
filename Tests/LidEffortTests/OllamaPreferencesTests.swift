import XCTest
@testable import LidEffort

@MainActor
final class OllamaPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "OllamaPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        // These are about Ollama's own migration: the providers added since
        // (see `NewProviderMigrationTests`) are already introduced here.
        defaults.set(Array(Preferences.introducedLater), forKey: "introducedProviders")
        return defaults
    }

    func testFreshAndUpstreamUsersKeepInventoryEnabledWithoutStartingRelay() {
        let store = defaults()
        let fresh = Preferences(defaults: store)
        XCTAssertFalse(fresh.isConnected("ollama-local"), "off by default: only the three lid-driven agents start connected")
        XCTAssertFalse(fresh.ollamaMetricsEnabled)
        fresh.setConnected(false, for: "ollama-local")
        let next = Preferences(defaults: store)
        XCTAssertFalse(next.isConnected("ollama-local"))
        XCTAssertFalse(next.ollamaMetricsEnabled)
    }

    func testLegacyDisabledRuntimeAndHiddenModelsMigrateOnlyOnce() {
        let store = defaults()
        store.set(true, forKey: "introducedOllama")
        store.set(["cursor", "ollama", "ollama:model:qwen3"], forKey: "hiddenProviders")
        store.set(["ollama:model:qwen3", "codex", "ollama-local:model:qwen3", "ollama"], forKey: "providerOrder")
        store.set(["ollama", "claude"], forKey: "mutedAlertProviders")
        let preferences = Preferences(defaults: store)
        XCTAssertEqual(preferences.disconnectedProviders, ["cursor", "ollama-local", "ollama-local:model:qwen3"])
        XCTAssertEqual(preferences.providerOrder, ["ollama-local:model:qwen3", "codex", "ollama-local"])
        XCTAssertEqual(preferences.mutedAlertProviders, ["ollama-local", "claude"])
        XCTAssertFalse(preferences.ollamaMetricsEnabled)
        preferences.setConnected(true, for: "ollama-local")
        preferences.ollamaMetricsEnabled = false
        let next = Preferences(defaults: store)
        XCTAssertTrue(next.isConnected("ollama-local"))
        XCTAssertFalse(next.isConnected("ollama-local:model:qwen3"))
        XCTAssertFalse(next.ollamaMetricsEnabled)
    }

    func testLegacyEnabledRelayChoiceSurvivesAndCanonicalDisconnectionWins() {
        let store = defaults()
        store.set(true, forKey: "introducedOllama")
        XCTAssertTrue(Preferences(defaults: store).ollamaMetricsEnabled)
        store.set(["ollama-local"], forKey: "hiddenProviders")
        XCTAssertFalse(Preferences(defaults: store).ollamaMetricsEnabled)
    }

    func testUnrelatedOllamaIDIsNotRenamedWithoutLegacySentinel() {
        let store = defaults()
        store.set(["ollama"], forKey: "hiddenProviders")
        store.set(["ollama", "codex"], forKey: "providerOrder")
        let preferences = Preferences(defaults: store)
        XCTAssertEqual(preferences.disconnectedProviders, ["ollama"])
        XCTAssertEqual(preferences.providerOrder, ["ollama", "codex"])
        XCTAssertTrue(preferences.isConnected("ollama-local"))
    }
}
