import XCTest
@testable import LidEffort

@MainActor
final class UsageResetWatcherTests: XCTestCase {
    private var alerts: [UsageResetEvent] = []
    private var muted: Set<String> = []
    private var watcher: UsageResetWatcher!

    override func setUp() {
        super.setUp()
        alerts = []
        muted = []
        watcher = UsageResetWatcher(
            isMuted: { [weak self] in self?.muted.contains($0) ?? false },
            deliver: { [weak self] in self?.alerts.append($0) }
        )
    }

    private func snapshot(_ id: String, _ name: String, _ fraction: Double,
                          resetsAt: Date? = nil,
                          label: String = "5-hour limit",
                          weekly: Double? = nil) -> ProviderSnapshot {
        var windows = [LimitWindow(id: "session", label: label, usedFraction: fraction, resetsAt: resetsAt)]
        if let weekly {
            windows.append(LimitWindow(id: "weekly", label: "All models", usedFraction: weekly))
        }
        return ProviderSnapshot(
            id: id, displayName: name, glyph: .claude, fidelity: .official, status: .ok,
            windows: windows,
            headlineID: "session",
            weeklyID: weekly == nil ? nil : "weekly"
        )
    }

    // MARK: - A reset inside a spent week

    func testNoCheerWhileTheWeekIsSpent() {
        watcher.observe([snapshot("claude", "Claude", 0.90, weekly: 1.0)])
        watcher.observe([snapshot("claude", "Claude", 0.05, weekly: 1.0)])
        XCTAssertTrue(alerts.isEmpty, "a session back at zero inside a spent week is not usable, so not news")
    }

    func testTheWeekComingBackDoesNotReplayTheOldSessionReset() {
        watcher.observe([snapshot("claude", "Claude", 0.90, weekly: 1.0)])
        watcher.observe([snapshot("claude", "Claude", 0.05, weekly: 1.0)])
        watcher.observe([snapshot("claude", "Claude", 0.05, weekly: 0.10)])
        XCTAssertTrue(alerts.isEmpty, "the silent reset became the baseline; nothing is announced late")
    }

    func testCheersAgainForTheNextResetOnceTheWeekIsBack() {
        watcher.observe([snapshot("claude", "Claude", 0.90, weekly: 1.0)])
        watcher.observe([snapshot("claude", "Claude", 0.05, weekly: 1.0)])
        watcher.observe([snapshot("claude", "Claude", 0.80, weekly: 0.10)])
        watcher.observe([snapshot("claude", "Claude", 0.03, weekly: 0.10)])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].currentFraction, 0.03)
    }

    func testAWeekNearlyButNotQuiteSpentStillCheers() {
        watcher.observe([snapshot("claude", "Claude", 0.90, weekly: 0.97)])
        watcher.observe([snapshot("claude", "Claude", 0.05, weekly: 0.97)])
        XCTAssertEqual(alerts.count, 1)
    }

    func testAProviderWithoutAWeeklyWindowCheersAsBefore() {
        watcher.observe([snapshot("codex", "Codex", 0.90)])
        watcher.observe([snapshot("codex", "Codex", 0.05)])
        XCTAssertEqual(alerts.count, 1)
    }

    func testNoAlertOnInitialObservation() {
        watcher.observe([snapshot("claude", "Claude", 0.85)])
        XCTAssertTrue(alerts.isEmpty, "initial reading records baseline and does not alert")
    }

    func testAlertsWhenUsageDropsSignificantly() {
        watcher.observe([snapshot("claude", "Claude", 0.90)])
        watcher.observe([snapshot("claude", "Claude", 0.05)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].providerID, "claude")
        XCTAssertEqual(alerts[0].providerName, "Claude")
        XCTAssertEqual(alerts[0].windowLabel, "5-hour limit")
        XCTAssertEqual(alerts[0].previousFraction, 0.90)
        XCTAssertEqual(alerts[0].currentFraction, 0.05)
    }

    func testAlertsWhenResetsAtRolledOver() {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 2000)

        watcher.observe([snapshot("claude", "Claude", 0.40, resetsAt: date1)])
        watcher.observe([snapshot("claude", "Claude", 0.05, resetsAt: date2)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].resetsAt, date2)
    }

    func testNoAlertForNegligibleFluctuation() {
        watcher.observe([snapshot("claude", "Claude", 0.05)])
        watcher.observe([snapshot("claude", "Claude", 0.01)])
        XCTAssertTrue(alerts.isEmpty, "negligible low-level fluctuation does not alert")
    }

    func testMutedProviderDoesNotAlert() {
        muted = ["claude"]
        watcher.observe([snapshot("claude", "Claude", 0.95)])
        watcher.observe([snapshot("claude", "Claude", 0.00)])
        XCTAssertTrue(alerts.isEmpty, "muted provider is silent")
    }

    func testMultipleProvidersTrackedIndependently() {
        watcher.observe([
            snapshot("claude", "Claude", 0.80),
            snapshot("cursor", "Cursor", 0.10)
        ])
        watcher.observe([
            snapshot("claude", "Claude", 0.02),
            snapshot("cursor", "Cursor", 0.70)
        ])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].providerID, "claude")

        watcher.observe([
            snapshot("claude", "Claude", 0.05),
            snapshot("cursor", "Cursor", 0.05)
        ])

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[1].providerID, "cursor")
    }
}
