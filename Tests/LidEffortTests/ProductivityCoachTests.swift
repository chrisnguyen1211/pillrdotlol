import XCTest
@testable import LidEffort

/// Records against your own past, nudges on a slow working week, never noise.
final class ProductivityCoachTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()
    /// Thursday 2026-10-08, 16:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_417_600 + 16 * 3600)
    private func day(_ back: Int) -> Date { calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))! }

    func testABestDayIsARecordOnceThereIsAPastToBeat() {
        var figures = ProductivityCoach.Figures()
        for back in 1...10 { figures.busy[day(back)] = 3600 }
        figures.busy[day(0)] = 3 * 3600
        let found = ProductivityCoach.findings(figures, now: now, calendar: calendar) { _ in false }
        XCTAssertTrue(found.contains { $0.kind == .record && $0.metric == .busy && $0.timeframe == .day && $0.previous == 3600 })
    }

    func testNoRecordWithoutEnoughHistoryOrBelowTheFloor() {
        var figures = ProductivityCoach.Figures()
        for back in 1...3 { figures.busy[day(back)] = 600 }
        figures.busy[day(0)] = 5 * 3600
        XCTAssertFalse(ProductivityCoach.findings(figures, now: now, calendar: calendar) { _ in false }
            .contains { $0.timeframe == .day }, "three days is not a past to beat")
        var small = ProductivityCoach.Figures()
        for back in 1...10 { small.commits[day(back)] = 1 }
        small.commits[day(0)] = 2
        XCTAssertFalse(ProductivityCoach.findings(small, now: now, calendar: calendar) { _ in false }
            .contains { $0.metric == .commits && $0.timeframe == .day }, "two commits is under the floor")
    }

    func testARecordAlreadyLoggedIsNotSaidAgain() {
        var figures = ProductivityCoach.Figures()
        for back in 1...10 { figures.finished[day(back)] = 2 }
        figures.finished[day(0)] = 6
        let first = ProductivityCoach.findings(figures, now: now, calendar: calendar) { _ in false }
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(ProductivityCoach.findings(figures, now: now, calendar: calendar) { first.contains($0) }.isEmpty)
    }

    func testASlowWeekGetsANudgeOnAWeekdayAfternoonOnly() {
        var figures = ProductivityCoach.Figures()
        for back in 7...34 { figures.busy[day(back)] = 4 * 3600 }   // four busy weeks
        figures.busy[day(1)] = 1800                                   // and a slow one
        let nudge = ProductivityCoach.nudge(figures, now: now, calendar: calendar)
        XCTAssertEqual(nudge?.kind, .nudge)
        let morning = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        XCTAssertNil(ProductivityCoach.nudge(figures, now: morning, calendar: calendar), "not before 15:00")
        let saturday = calendar.date(byAdding: .day, value: 2, to: now)!
        XCTAssertNil(ProductivityCoach.nudge(figures, now: saturday, calendar: calendar), "never at the weekend")
        var usual = figures
        for back in 1...3 { usual.busy[day(back)] = 4 * 3600 }
        XCTAssertNil(ProductivityCoach.nudge(usual, now: now, calendar: calendar), "a usual week needs no nudge")
    }

    func testTheCardSaysWhatWasBeaten() {
        let note = ProductivityCoach.note(.init(kind: .record, metric: .commits, timeframe: .week, period: day(3),
                                                value: 42, previous: 30))
        XCTAssertTrue(note.good)
        XCTAssertTrue(note.subtitle.contains("42"), note.subtitle)
        XCTAssertTrue(note.subtitle.contains("30"), note.subtitle)
    }

    func testOnlyOneCardADayAndEverythingIsLogged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coach-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let ledger = try XCTUnwrap(ActivityLedger(url: url))
        ledger.log(.init(at: now.addingTimeInterval(-3600), kind: .record, metric: "busy", timeframe: "day", period: day(0),
                         value: 1, previous: nil, shown: true))
        XCTAssertNil(ProductivityCoach.check(ledger: ledger, stores: [], now: now, calendar: calendar),
                     "a card was already shown today")
        XCTAssertEqual(ledger.coachEvents().count, 1)
    }
}
