import XCTest
@testable import LidEffort

@MainActor
final class UsageLimitWatcherTests: XCTestCase {
    private var alerts: [UsageAlertEvent] = []
    private var muted: Set<String> = []
    private var watcher: UsageLimitWatcher!

    override func setUp() {
        super.setUp()
        alerts = []
        muted = []
        watcher = UsageLimitWatcher(
            isMuted: { [weak self] in self?.muted.contains($0) ?? false },
            deliver: { [weak self] in self?.alerts.append($0) }
        )
    }

    private func snapshot(
        _ id: String,
        _ name: String,
        sessionFraction: Double,
        weeklyFraction: Double = 0.50,
        sessionResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil,
        block: UsageBlock? = nil
    ) -> ProviderSnapshot {
        var windows = [
            LimitWindow(id: "session", label: "5-hour limit", usedFraction: sessionFraction, resetsAt: sessionResetsAt)
        ]
        if weeklyFraction > 0 {
            windows.append(
                LimitWindow(id: "weekly", label: "Weekly limit", usedFraction: weeklyFraction, resetsAt: weeklyResetsAt)
            )
        }
        return ProviderSnapshot(
            id: id,
            displayName: name,
            glyph: .claude,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: "session",
            weeklyID: weeklyFraction > 0 ? "weekly" : nil,
            block: block
        )
    }

    func testNoAlertOnInitialObservation() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.0, weeklyFraction: 1.0)])
        XCTAssertTrue(alerts.isEmpty, "baseline observation records state and does not trigger false alerts on launch")
    }

    func testAlertsWhenSessionLimitReached() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .sessionLimitReached)
        XCTAssertEqual(alerts[0].providerID, "claude")
        XCTAssertEqual(alerts[0].providerName, "Claude")
        XCTAssertEqual(alerts[0].currentFraction, 1.00)
    }

    func testAlertsWhenWeeklyLimitReached() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, weeklyFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, weeklyFraction: 1.00)])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .weeklyLimitReached)
        XCTAssertEqual(alerts[0].providerID, "claude")
        XCTAssertEqual(alerts[0].currentFraction, 1.00)
    }

    func testAlertsWhenBlocked() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.50, block: UsageBlock(reason: "Rate limited", resetsAt: nil))])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].kind, .sessionLimitReached)
    }

    func testNoRepeatAlertWhileExhausted() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertEqual(alerts.count, 1)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.02)])
        XCTAssertEqual(alerts.count, 1, "does not spam repeated alerts while remaining exhausted")
    }

    func testReArmsWhenUsageDropsBelowThreshold() {
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertEqual(alerts.count, 1)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.90)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertEqual(alerts.count, 2, "re-arms alert when usage drops and reaches limit again")
    }

    func testReArmsWhenResetsAtRollsOver() {
        let date1 = Date(timeIntervalSince1970: 1000)
        let date2 = Date(timeIntervalSince1970: 5000)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80, sessionResetsAt: date1)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00, sessionResetsAt: date1)])
        XCTAssertEqual(alerts.count, 1)

        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00, sessionResetsAt: date2)])
        XCTAssertEqual(alerts.count, 2, "re-arms when window rolls over to new resetsAt")
    }

    func testMutedProviderDoesNotAlert() {
        muted = ["claude"]
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 0.80)])
        watcher.observe([snapshot("claude", "Claude", sessionFraction: 1.00)])
        XCTAssertTrue(alerts.isEmpty, "muted provider delivers no limit alerts")
    }

    func testTracksMultipleProvidersIndependently() {
        watcher.observe([
            snapshot("claude", "Claude", sessionFraction: 0.50),
            snapshot("cursor", "Cursor", sessionFraction: 0.50)
        ])

        watcher.observe([
            snapshot("claude", "Claude", sessionFraction: 1.00),
            snapshot("cursor", "Cursor", sessionFraction: 0.60)
        ])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].providerID, "claude")

        watcher.observe([
            snapshot("claude", "Claude", sessionFraction: 1.00),
            snapshot("cursor", "Cursor", sessionFraction: 1.00)
        ])
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts[1].providerID, "cursor")
    }
}
