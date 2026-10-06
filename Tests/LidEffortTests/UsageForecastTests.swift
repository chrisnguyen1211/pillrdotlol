import XCTest
@testable import LidEffort

/// When a limit runs out at the rate it is going — said only when that is
/// before it resets — and Auto-eco, which acts on it once per reset.
@MainActor
final class UsageForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func window(_ used: Double, resetsIn: TimeInterval, duration: TimeInterval = 5 * 3600, id: String = "session") -> LimitWindow {
        LimitWindow(id: id, label: "Session", usedFraction: used,
                    resetsAt: now.addingTimeInterval(resetsIn), duration: duration)
    }

    private func snapshot(_ provider: String, _ windows: [LimitWindow]) -> ProviderSnapshot {
        ProviderSnapshot(id: provider, displayName: provider.capitalized, glyph: .claude, fidelity: .official,
                         status: .ok, windows: windows)
    }

    func testTheRecentRateDecides() throws {
        // 40% → 60% in the last 20 minutes: 1%/min, 40 minutes left, reset in 3 h.
        let samples = [(at: now.addingTimeInterval(-20 * 60), used: 0.4), (at: now, used: 0.6)]
        let forecast = try XCTUnwrap(UsageForecast.forecast(used: 0.6, resetsAt: now.addingTimeInterval(3 * 3600),
                                                            duration: 5 * 3600, samples: samples, now: now))
        XCTAssertEqual(forecast.runsOutAt.timeIntervalSince(now), 40 * 60, accuracy: 1)
        XCTAssertEqual(forecast.text(now: now), "out in 40 min")
    }

    func testNothingIsSaidWhenItLastsUntilTheReset() {
        let slow = [(at: now.addingTimeInterval(-30 * 60), used: 0.30), (at: now, used: 0.31)]
        XCTAssertNil(UsageForecast.forecast(used: 0.31, resetsAt: now.addingTimeInterval(3600),
                                            duration: 5 * 3600, samples: slow, now: now))
        let flat = [(at: now.addingTimeInterval(-30 * 60), used: 0.5), (at: now, used: 0.5)]
        XCTAssertNil(UsageForecast.forecast(used: 0.5, resetsAt: now.addingTimeInterval(3600),
                                            duration: 5 * 3600, samples: flat, now: now))
        XCTAssertNil(UsageForecast.forecast(used: 1.0, resetsAt: now.addingTimeInterval(3600),
                                            duration: 5 * 3600, samples: [], now: now), "already spent")
    }

    func testWithoutHistoryTheWindowsAverageIsUsed() throws {
        // 80% used 2 h into a 5 h window: 40%/h, half an hour left, reset in 3 h.
        let forecast = try XCTUnwrap(UsageForecast.forecast(used: 0.8, resetsAt: now.addingTimeInterval(3 * 3600),
                                                            duration: 5 * 3600, samples: [], now: now))
        XCTAssertEqual(forecast.runsOutAt.timeIntervalSince(now), 30 * 60, accuracy: 1)
    }

    func testAResetForgetsTheOldReadings() {
        let forecaster = UsageForecaster()
        forecaster.observe([snapshot("claude", [window(0.9, resetsIn: 600)])], now: now.addingTimeInterval(-600))
        forecaster.observe([snapshot("claude", [window(0.05, resetsIn: 5 * 3600 - 60)])], now: now)
        XCTAssertNil(forecaster.forecast(providerID: "claude", window: window(0.05, resetsIn: 5 * 3600 - 60), now: now))
    }

    func testAutoEcoActsOncePerResetAndOnlyWhenOn() {
        let defaults = UserDefaults(suiteName: "AutoEco-\(UUID().uuidString)")!
        let eco = AutoEco(defaults: defaults)
        let near = [snapshot("claude", [window(0.92, resetsIn: 3600)])]
        XCTAssertNil(eco.trigger(near, forecaster: UsageForecaster(), now: now), "off by default")
        defaults.set(true, forKey: AutoEco.defaultsKey)
        XCTAssertEqual(eco.trigger(near, forecaster: UsageForecaster(), now: now)?.providerID, "claude")
        XCTAssertNil(eco.trigger(near, forecaster: UsageForecaster(), now: now), "once per reset")
        let nextCycle = [snapshot("claude", [window(0.95, resetsIn: 5 * 3600 + 3600)])]
        XCTAssertEqual(eco.trigger(nextCycle, forecaster: UsageForecaster(), now: now)?.providerID, "claude")
        XCTAssertNil(eco.trigger([snapshot("cursor", [window(0.99, resetsIn: 3600)])], forecaster: UsageForecaster(), now: now),
                     "only agents whose effort the lid sets")
    }

    func testAutoEcoActsOnAForecastBeforeTheThreshold() {
        let defaults = UserDefaults(suiteName: "AutoEco-\(UUID().uuidString)")!
        defaults.set(true, forKey: AutoEco.defaultsKey)
        let eco = AutoEco(defaults: defaults)
        let forecaster = UsageForecaster()
        forecaster.observe([snapshot("codex", [window(0.5, resetsIn: 3 * 3600)])], now: now.addingTimeInterval(-15 * 60))
        let hot = [snapshot("codex", [window(0.7, resetsIn: 3 * 3600)])]
        forecaster.observe(hot, now: now)
        // 20% in 15 min → out in 22.5 min, inside the 45-minute warning.
        XCTAssertEqual(eco.trigger(hot, forecaster: forecaster, now: now)?.providerID, "codex")
    }
}
