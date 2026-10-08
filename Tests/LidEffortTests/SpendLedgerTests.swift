import XCTest
@testable import LidEffort

/// What each key spent, by day, week and month, from readings kept over time.
final class SpendLedgerTests: XCTestCase {
    private var ledger: SpendLedger!
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).sqlite")
        ledger = try XCTUnwrap(SpendLedger(url: url))
    }

    override func tearDown() {
        ledger = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// 2026-10-08 is a Thursday; its UTC week began Monday the 5th.
    private func at(_ day: Int, _ hour: Int = 12) -> Date {
        var parts = DateComponents(year: 2026, month: 10, day: day, hour: hour)
        parts.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    func testAProvidersOwnPeriodSumsAreTakenAsTheyAre() {
        let usd = APIUnit.money("USD")
        ledger.record(provider: "or", reading: .spend(40, usd, .month), periods: [
            .init(period: .day, start: SpendLedger.range(.day, containing: at(8)).from, amount: 1.5, unit: usd),
            .init(period: .week, start: SpendLedger.range(.week, containing: at(8)).from, amount: 9, unit: usd),
        ], at: at(8))
        ledger.flush()
        XCTAssertEqual(ledger.used(provider: "or", in: .day, now: at(8, 18)), .init(amount: 1.5, unit: usd, since: nil))
        XCTAssertEqual(ledger.used(provider: "or", in: .week, now: at(8, 18)), .init(amount: 9, unit: usd, since: nil))
        XCTAssertEqual(ledger.used(provider: "or", in: .month, now: at(8, 18)), .init(amount: 40, unit: usd, since: nil),
                       "this month's spend, read this month, is the month")
    }

    func testDailyBucketsAddUpToTheWeek() {
        let usd = APIUnit.money("USD")
        let days = (1...8).map { SpendLedger.PeriodAmount(period: .day, start: SpendLedger.range(.day, containing: at($0)).from,
                                                          amount: Double($0), unit: usd) }
        ledger.record(provider: "oa", reading: .spend(36, usd, .month), periods: days, at: at(8))
        ledger.flush()
        XCTAssertEqual(ledger.used(provider: "oa", in: .week, now: at(8))?.amount, 5 + 6 + 7 + 8)
        XCTAssertEqual(ledger.used(provider: "oa", in: .day, now: at(8))?.amount, 8)
    }

    func testABalanceCountsWhatFellAndNotWhatWasPaidIn() {
        let usd = APIUnit.money("USD")
        for (hour, left) in [(1, 10.0), (5, 8.0), (9, 12.0), (13, 11.0)] {
            ledger.record(provider: "ds", reading: .balance(left, usd), at: at(8, hour))
        }
        ledger.flush()
        let today = ledger.used(provider: "ds", in: .day, now: at(8, 20))
        XCTAssertEqual(today?.amount, 3, "2 used, 4 paid in, 1 used")
        XCTAssertEqual(today?.since, at(8, 1), "the ledger knows only from its first reading")
    }

    func testAMonthlyCounterThatResetsStartsAgainFromNothing() {
        let usd = APIUnit.money("USD")
        ledger.record(provider: "x", reading: .spend(30, usd, .month), at: at(4))
        ledger.record(provider: "x", reading: .spend(31, usd, .month), at: at(5, 1))
        ledger.record(provider: "x", reading: .spend(33, usd, .month), at: at(6))
        ledger.flush()
        XCTAssertEqual(ledger.used(provider: "x", in: .week, now: at(8))?.amount, 3, "from the reading before Monday")
        XCTAssertNil(ledger.used(provider: "x", in: .week, now: at(8))?.since)
    }

    func testAnUnchangedFigureIsNotWrittenAgainAndAgain() {
        let usd = APIUnit.money("USD")
        for minute in 0..<6 { ledger.record(provider: "q", reading: .balance(5, usd), at: at(8).addingTimeInterval(Double(minute * 60))) }
        ledger.record(provider: "q", reading: .balance(4, usd), at: at(8).addingTimeInterval(400))
        ledger.flush()
        XCTAssertEqual(ledger.used(provider: "q", in: .day, now: at(8, 20))?.amount, 1)
        XCTAssertEqual(ledger.providers(), ["q"])
    }

    func testOpenAIAndAnthropicDailyBucketsAreRead() throws {
        let openAI = try JSONSerialization.jsonObject(with: Data(#"""
            {"data":[{"start_time":1791417600,"results":[{"amount":{"value":1.25}},{"amount":{"value":0.75}}]},
                     {"start_time":1791504000,"results":[]}]}
            """#.utf8))
        let days = APIPeriodFigures(buckets: .init(list: "data", start: "start_time", amount: "results[*].amount.value"),
                                    unit: .money("USD")).read(openAI, now: at(8))
        XCTAssertEqual(days.first { $0.amount > 0 }?.amount, 2)
        let anthropic = try JSONSerialization.jsonObject(with: Data(#"""
            {"data":[{"starting_at":"2026-10-08T00:00:00Z","results":[{"amount":"250"},{"amount":"50"}]}]}
            """#.utf8))
        let cents = APIPeriodFigures(buckets: .init(list: "data", start: "starting_at", amount: "results[*].amount", scale: 0.01),
                                     unit: .money("USD")).read(anthropic, now: at(8))
        XCTAssertEqual(cents, [.init(period: .day, start: at(8, 0), amount: 3, unit: .money("USD"))])
    }

    func testOpenRoutersOwnSumsAreRead() throws {
        let json = try JSONSerialization.jsonObject(with: Data(#"{"data":{"usage_daily":0.4,"usage_weekly":2.1,"usage_monthly":7}}"#.utf8))
        let figures = APIPeriodFigures(root: "data", day: "usage_daily", week: "usage_weekly", month: "usage_monthly",
                                       unit: .money("USD")).read(json, now: at(8))
        XCTAssertEqual(figures.map(\.amount), [0.4, 2.1, 7])
        XCTAssertEqual(figures[1].start, SpendLedger.range(.week, containing: at(8)).from)
    }
}
