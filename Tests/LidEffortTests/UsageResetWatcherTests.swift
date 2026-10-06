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

        // Watched up to the reset, and read again just after it.
        watcher.observe([snapshot("claude", "Claude", 0.40, resetsAt: date1)], now: date1.addingTimeInterval(-300))
        watcher.observe([snapshot("claude", "Claude", 0.05, resetsAt: date2)], now: date1.addingTimeInterval(30))

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].resetsAt, date2)
    }

    // MARK: - What is not a reset

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testAResetTimeThatOnlyDriftsIsTheSameWindow() {
        let end = t0.addingTimeInterval(3 * 3600)
        watcher.observe([snapshot("claude", "Claude", 0.60, resetsAt: end)], now: t0)
        watcher.observe([snapshot("claude", "Claude", 0.62, resetsAt: end.addingTimeInterval(120))], now: t0.addingTimeInterval(300))
        watcher.observe([snapshot("claude", "Claude", 0.63, resetsAt: end.addingTimeInterval(240))], now: t0.addingTimeInterval(600))
        XCTAssertTrue(alerts.isEmpty, "a rolling window's reset time creeping later is not a reset")
    }

    func testADropLongBeforeTheResetIsAnotherSourceNotAReset() {
        let end = t0.addingTimeInterval(3 * 3600)
        watcher.observe([snapshot("claude", "Claude", 0.80, resetsAt: end)], now: t0)
        watcher.observe([snapshot("claude", "Claude", 0.10, resetsAt: end)], now: t0.addingTimeInterval(120))
        XCTAssertTrue(alerts.isEmpty, "three hours before its reset time the window cannot have reset")
        // And the glitch's low number is not later taken for a recovery.
        watcher.observe([snapshot("claude", "Claude", 0.81, resetsAt: end)], now: t0.addingTimeInterval(240))
        XCTAssertTrue(alerts.isEmpty)
    }

    func testAResetFoundLateIsNotAnnounced() {
        // Last read at 80% before the login dropped; the window reset at
        // 21:00; the login came back at 23:29.
        let end = t0.addingTimeInterval(3600)
        watcher.observe([snapshot("claude", "Claude", 0.80, resetsAt: end)], now: t0)
        watcher.observe([snapshot("claude", "Claude", 0.05, resetsAt: end.addingTimeInterval(5 * 3600))],
                        now: end.addingTimeInterval(2.5 * 3600))
        XCTAssertTrue(alerts.isEmpty, "Claude came back hours ago; saying so now is wrong")
    }

    func testAResetSeenAsItHappensIsAnnounced() {
        let end = t0.addingTimeInterval(3600)
        watcher.observe([snapshot("claude", "Claude", 0.80, resetsAt: end)], now: end.addingTimeInterval(-240))
        watcher.observe([snapshot("claude", "Claude", 0.02, resetsAt: end.addingTimeInterval(5 * 3600))],
                        now: end.addingTimeInterval(60))
        XCTAssertEqual(alerts.count, 1)
    }

    func testStaleReadingsAreNeitherComparedNorABaseline() {
        let end = t0.addingTimeInterval(3600)
        watcher.observe([snapshot("claude", "Claude", 0.80, resetsAt: end)], now: end.addingTimeInterval(-300))
        var stale = snapshot("claude", "Claude", 0.00, resetsAt: end)
        stale.status = .stale(since: t0)
        watcher.observe([stale], now: end.addingTimeInterval(-200))
        watcher.observe([snapshot("claude", "Claude", 0.81, resetsAt: end)], now: end.addingTimeInterval(-100))
        XCTAssertTrue(alerts.isEmpty)
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
