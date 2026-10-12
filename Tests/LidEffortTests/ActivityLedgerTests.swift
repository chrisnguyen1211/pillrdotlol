import XCTest
@testable import LidEffort

/// How agents spent their time: kept as changes, read back as a summary.
final class ActivityLedgerTests: XCTestCase {
    private var ledger: ActivityLedger!
    private var url: URL!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString).sqlite")
        ledger = try XCTUnwrap(ActivityLedger(url: url))
    }

    override func tearDown() {
        ledger = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private let day = Date(timeIntervalSince1970: 1_791_417_600)   // 2026-10-08 00:00 UTC
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(9 * 3600 + minutes * 60) }

    private func session(_ id: String, _ state: AgentSession.State, since: Date) -> AgentSession {
        AgentSession(id: id, name: id, detail: "", state: state, waitingFor: nil, since: since)
    }

    private func observe(_ agent: String, _ list: [(String, AgentSession.State)], _ minute: Double) {
        ledger.observe(agent: agent, sessions: list.map { session($0.0, $0.1, since: at(minute)) }, at: at(minute))
    }

    func testBusyWaitingAndParallelTimeAreAddedUp() {
        observe("claude", [("a", .busy)], 0)
        observe("codex", [("b", .busy)], 10)
        observe("claude", [("a", .waiting)], 30)        // a: busy 30 min
        observe("codex", [("b", .success)], 40)         // b: busy 30 min
        observe("claude", [("a", .busy)], 45)           // a waited 15 min
        observe("claude", [], 60)                       // a: busy 15 more, then gone
        ledger.flush()
        let summary = ledger.summary(from: day, to: day.addingTimeInterval(86_400), now: at(120), calendar: calendar)
        XCTAssertEqual(summary.busy, 75 * 60)
        XCTAssertEqual(summary.busyByAgent["claude"], 45 * 60)
        XCTAssertEqual(summary.waiting, 15 * 60)
        XCTAssertEqual(summary.parallel, 20 * 60, "a and b both busy from 10 to 30")
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.busyByHour[9], 75 * 60, "every busy stretch fell between 9 and 10")
        XCTAssertEqual(summary.busyByHour[10], 0)
    }

    func testASessionStillBusyCountsUpToNow() {
        observe("claude", [("a", .busy)], 0)
        ledger.flush()
        XCTAssertEqual(ledger.summary(from: day, to: day.addingTimeInterval(86_400), now: at(20), calendar: calendar).busy, 20 * 60)
    }

    func testLinesCountWhatTheTreeGrewByAndStartAgainAfterACommit() {
        let stats = { (added: Int, removed: Int) in GitChanges.Stats(files: 1, added: added, removed: removed) }
        ledger.completed(agent: "claude", session: "a", blocked: false, folder: "/r", tree: stats(10, 2), at: at(0))
        ledger.completed(agent: "claude", session: "a", blocked: false, folder: "/r", tree: stats(25, 2), at: at(10))
        ledger.completed(agent: "claude", session: "a", blocked: false, folder: "/r", tree: stats(4, 1), at: at(20))  // committed
        ledger.completed(agent: "claude", session: "a", blocked: true, folder: nil, tree: nil, at: at(25))
        ledger.flush()
        let summary = ledger.summary(from: day, to: day.addingTimeInterval(86_400), now: at(60), calendar: calendar)
        XCTAssertEqual(summary.finished, 3)
        XCTAssertEqual(summary.added, 10 + 15 + 4)
        XCTAssertEqual(summary.removed, 2 + 0 + 1)
    }

    func testTheTreeBeforeTheRangeIsTheStartingPoint() {
        let tree = GitChanges.Stats(files: 1, added: 100, removed: 0)
        ledger.completed(agent: "claude", session: "a", blocked: false, folder: "/r", tree: tree, at: day.addingTimeInterval(-3600))
        ledger.completed(agent: "claude", session: "a", blocked: false, folder: "/r",
                         tree: GitChanges.Stats(files: 1, added: 130, removed: 0), at: at(0))
        ledger.flush()
        XCTAssertEqual(ledger.summary(from: day, to: day.addingTimeInterval(86_400), now: at(60), calendar: calendar).added, 30)
    }

    func testAnswerTimesGiveTheirMiddle() {
        for seconds in [5.0, 40, 12] {
            ledger.answered(agent: "claude", question: false, asked: at(0), at: at(0).addingTimeInterval(seconds))
        }
        ledger.flush()
        let summary = ledger.summary(from: day, to: day.addingTimeInterval(86_400), now: at(60), calendar: calendar)
        XCTAssertEqual(summary.answered, 3)
        XCTAssertEqual(summary.medianAnswer, 12)
    }

    func testAStreakCountsDaysInARow() {
        for back in 0..<3 {
            let start = day.addingTimeInterval(Double(-back) * 86_400 + 3600)
            ledger.observe(agent: "claude", sessions: [session("s\(back)", .busy, since: start)], at: start)
            ledger.observe(agent: "claude", sessions: [], at: start.addingTimeInterval(600))
        }
        ledger.flush()
        XCTAssertEqual(ledger.streak(now: day.addingTimeInterval(20 * 3600), calendar: calendar), 3)
    }

    /// A streak and a best run read the whole ledger, not the last 60 or 120 days.
    func testAStreakIsNotCutAtAWindow() {
        // 200 days in a row up to today, and an older run of 130 days before a gap.
        for back in 0..<200 { work(daysBack: back) }
        for back in 210..<340 { work(daysBack: back) }
        ledger.flush()
        let now = day.addingTimeInterval(20 * 3600)
        XCTAssertEqual(ledger.streak(now: now, calendar: calendar), 200)
        XCTAssertEqual(ledger.bestStreak(now: now, calendar: calendar), 200)
    }

    func testTheBestStreakCanBeAnOldOne() {
        for back in 0..<5 { work(daysBack: back) }
        for back in 10..<140 { work(daysBack: back) }
        ledger.flush()
        let now = day.addingTimeInterval(20 * 3600)
        XCTAssertEqual(ledger.streak(now: now, calendar: calendar), 5)
        XCTAssertEqual(ledger.bestStreak(now: now, calendar: calendar), 130)
    }

    private func work(daysBack back: Int) {
        let start = day.addingTimeInterval(Double(-back) * 86_400 + 3600)
        ledger.observe(agent: "claude", sessions: [session("s\(back)", .busy, since: start)], at: start)
        ledger.observe(agent: "claude", sessions: [], at: start.addingTimeInterval(600))
    }

    /// A session busy when pillr quit ended when pillr was last there, not
    /// at every "now" after.
    func testABusyRunLeftOpenByAQuitEndsWherePillrLastWas() throws {
        observe("claude", [("a", .busy)], 0)
        ledger.heartbeat(at: at(30))
        ledger.flush()
        ledger = nil
        // pillr starts again a day later; the session is gone.
        let reopened = try XCTUnwrap(ActivityLedger(url: url))
        reopened.observe(agent: "claude", sessions: [], at: at(24 * 60))
        reopened.flush()
        let summary = reopened.summary(from: day, to: day.addingTimeInterval(2 * 86_400), now: at(48 * 60), calendar: calendar)
        XCTAssertEqual(summary.busy, 30 * 60, "busy until pillr's last sign of life, not for two days")
    }

    /// Sleep is not work: a run open when the Mac sleeps ends then.
    func testSleepEndsTheRunsOpenThen() {
        observe("claude", [("a", .busy)], 0)
        ledger.pause(at: at(20))
        // Waking eight hours on, still busy: a new run from then.
        observe("claude", [("a", .busy)], 8 * 60)
        observe("claude", [("a", .idle)], 8 * 60 + 10)
        ledger.flush()
        let summary = ledger.summary(from: day, to: day.addingTimeInterval(86_400), now: at(9 * 60), calendar: calendar)
        XCTAssertEqual(summary.busy, 30 * 60, "20 minutes before sleep, 10 after waking")
    }
}
