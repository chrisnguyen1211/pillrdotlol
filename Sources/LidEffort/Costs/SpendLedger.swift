import Foundation
import SQLite3

/// What every API key has spent, kept over time so a day or a week can be
/// told apart from the month.
///
/// Most providers answer with one figure: a balance, or this month's spend.
/// Each reading is written down as it comes, and what a day or a week cost
/// is worked out from how the figure moved. Where a provider already splits
/// its answer into days, or sums a day, a week and a month itself, those
/// figures are kept as they are and preferred.
///
/// Numbers only: the provider's id, when, how much, in what. Never a key,
/// never a URL. Nothing here is sent anywhere.
final class SpendLedger {
    /// The app's own ledger; nil under test, where each test opens its own.
    static let shared: SpendLedger? = Runtime.isUnderTest
        ? nil : SpendLedger(url: CostPaths.directory.appendingPathComponent("spend-ledger.sqlite"))

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "lol.pillr.app.costs.spend-ledger")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// An unchanged figure is written again only this often.
    static let unchangedEvery: TimeInterval = 10 * 60

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else { return nil }
        db = handle
        let ok = queue.sync { () -> Bool in
            exec("PRAGMA journal_mode=WAL;")
            exec("PRAGMA synchronous=NORMAL;")
            return exec("""
                CREATE TABLE IF NOT EXISTS reading(
                  ts INTEGER NOT NULL, provider TEXT NOT NULL, kind TEXT NOT NULL,
                  value REAL NOT NULL, unit TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS ix_reading ON reading(provider, kind, ts);
                CREATE TABLE IF NOT EXISTS period_amount(
                  provider TEXT NOT NULL, period TEXT NOT NULL, start INTEGER NOT NULL,
                  amount REAL NOT NULL, unit TEXT NOT NULL, updated INTEGER NOT NULL,
                  PRIMARY KEY(provider, period, start));
                """)
        }
        guard ok else { sqlite3_close(handle); return nil }
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: Writing

    /// A figure a provider summed over a period of its own: one day of its
    /// daily buckets, or its "today", "this week", "this month".
    struct PeriodAmount: Equatable {
        enum Period: String { case day, week, month }
        let period: Period
        let start: Date
        let amount: Double
        let unit: APIUnit
    }

    /// Writes down one reading of a key, and whatever per-period figures came
    /// with it.
    func record(provider: String, reading: APIReading, periods: [PeriodAmount] = [], at date: Date = Date()) {
        let samples = Self.samples(of: reading)
        queue.async { [self] in
            exec("BEGIN;")
            for sample in samples {
                if let last = lastSample(provider: provider, kind: sample.kind),
                   last.value == sample.value, date.timeIntervalSince(last.at) < Self.unchangedEvery { continue }
                run("INSERT INTO reading(ts, provider, kind, value, unit) VALUES (?1, ?2, ?3, ?4, ?5)",
                    [.int(Int(date.timeIntervalSince1970)), .text(provider), .text(sample.kind),
                     .real(sample.value), .text(Self.code(sample.unit))])
            }
            for amount in periods {
                run("""
                    INSERT INTO period_amount(provider, period, start, amount, unit, updated) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                    ON CONFLICT(provider, period, start) DO UPDATE SET amount = excluded.amount, unit = excluded.unit,
                      updated = excluded.updated
                    """, [.text(provider), .text(amount.period.rawValue), .int(Int(amount.start.timeIntervalSince1970)),
                          .real(amount.amount), .text(Self.code(amount.unit)), .int(Int(date.timeIntervalSince1970))])
            }
            exec("COMMIT;")
        }
    }

    /// Waits for the writes so far; for tests.
    func flush() { queue.sync {} }

    struct Sample: Equatable {
        /// `spent` grows as money is used, `balance` shrinks; the period says
        /// over what a spent figure is summed (`month`, `total`, `billing`).
        let kind: String
        let value: Double
        let unit: APIUnit
    }

    /// The figures in a reading that can be followed over time.
    static func samples(of reading: APIReading) -> [Sample] {
        reading.parts.compactMap { part in
            switch part {
            case .balance(let value, let unit): return Sample(kind: "balance", value: value, unit: unit)
            case .balanceSpent(let remaining, _, let unit): return Sample(kind: "balance", value: remaining, unit: unit)
            case .left(let value, _, let unit, _): return Sample(kind: "balance", value: value, unit: unit)
            case .spend(let value, let unit, let period): return Sample(kind: "spent:\(code(period))", value: value, unit: unit)
            case .count(let value, let unit, let period): return Sample(kind: "spent:\(code(period))", value: value, unit: unit)
            case .used(let value, _, let unit, _): return Sample(kind: "spent:billing", value: value, unit: unit)
            case .keyWorks, .several: return nil
            }
        }
    }

    // MARK: Reading

    /// What a key used between two moments.
    struct Figure: Equatable {
        let amount: Double
        let unit: APIUnit
        /// When the ledger's knowledge starts, where that is after `from`:
        /// the figure is then only "since" that moment.
        let since: Date?
    }

    /// The UTC day, week (from Monday) and month that `date` is in: the
    /// periods providers bill and sum in.
    static func range(_ period: PeriodAmount.Period, containing date: Date) -> (from: Date, to: Date) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let component: Calendar.Component = switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        let interval = calendar.dateInterval(of: component, for: date)!
        return (interval.start, interval.end)
    }

    /// What the key used in the current day, week or month, by the best
    /// evidence there is: the provider's own sum for that period, its days
    /// added up, or how its figure moved.
    func used(provider: String, in period: PeriodAmount.Period, now: Date = Date()) -> Figure? {
        let (from, to) = Self.range(period, containing: now)
        return queue.sync { () -> Figure? in
            if let own = periodRow(provider: provider, period: period, start: from) {
                return Figure(amount: own.amount, unit: own.unit, since: nil)
            }
            // This month's spend, read this month, is the month as it is:
            // better than days that may not reach back to its start.
            if period == .month, let last = samples(provider: provider, kind: "spent:month", from: from, to: to).last {
                return Figure(amount: last.value, unit: last.unit, since: nil)
            }
            if period != .day, let days = dayRows(provider: provider, from: from, to: to), !days.isEmpty {
                let first = days.map(\.start).min()!
                return Figure(amount: days.reduce(0) { $0 + $1.amount }, unit: days[0].unit,
                              since: first > from.addingTimeInterval(86_399) ? first : nil)
            }
            return moved(provider: provider, from: from, to: to)
        }
    }

    /// What a key used between any two moments, for the charts: whole days
    /// the provider summed itself, else how its figure moved.
    func used(provider: String, from: Date, to: Date) -> Figure? {
        queue.sync { () -> Figure? in
            let dayLong = to.timeIntervalSince(from) >= 86_399
            if dayLong, let days = dayRows(provider: provider, from: from, to: to), !days.isEmpty {
                return Figure(amount: days.reduce(0) { $0 + $1.amount }, unit: days[0].unit, since: nil)
            }
            return moved(provider: provider, from: from, to: to, monthIsExact: false)
        }
    }

    /// How far the figure moved: what was spent grows, and a fall in it is a
    /// new period starting from nothing; a balance falls as it is used, and
    /// a rise is money paid in, not spent.
    private func moved(provider: String, from: Date, to: Date, monthIsExact: Bool = true) -> Figure? {
        for kind in ["spent:month", "spent:billing", "spent:total", "spent:last30", "balance"] {
            let rows = samples(provider: provider, kind: kind, from: from, to: to)
            guard let last = rows.last else { continue }
            // This month's spend, read this month, is the month's figure as it is.
            if monthIsExact, kind == "spent:month", from == Self.range(.month, containing: last.at).from {
                return Figure(amount: last.value, unit: last.unit, since: nil)
            }
            let before = sampleBefore(provider: provider, kind: kind, date: from)
            var series = rows
            if let before { series.insert(before, at: 0) }
            guard series.count >= 2 || before == nil else { continue }
            var total = 0.0
            for (previous, next) in zip(series, series.dropFirst()) {
                let step = next.value - previous.value
                if kind == "balance" {
                    if step < 0 { total -= step }
                } else {
                    total += step >= 0 ? step : next.value
                }
            }
            let known = before == nil ? rows.first?.at : nil
            return Figure(amount: total, unit: last.unit, since: known.flatMap { $0 > from ? $0 : nil })
        }
        return nil
    }

    // MARK: Queries (queue-confined)

    private struct Row { let at: Date; let value: Double; let unit: APIUnit }

    private func lastSample(provider: String, kind: String) -> Row? {
        rows("SELECT ts, value, unit FROM reading WHERE provider = ?1 AND kind = ?2 ORDER BY ts DESC LIMIT 1",
             [.text(provider), .text(kind)]).first
    }

    private func sampleBefore(provider: String, kind: String, date: Date) -> Row? {
        rows("SELECT ts, value, unit FROM reading WHERE provider = ?1 AND kind = ?2 AND ts < ?3 ORDER BY ts DESC LIMIT 1",
             [.text(provider), .text(kind), .int(Int(date.timeIntervalSince1970))]).first
    }

    private func samples(provider: String, kind: String, from: Date, to: Date) -> [Row] {
        rows("SELECT ts, value, unit FROM reading WHERE provider = ?1 AND kind = ?2 AND ts >= ?3 AND ts < ?4 ORDER BY ts",
             [.text(provider), .text(kind), .int(Int(from.timeIntervalSince1970)), .int(Int(to.timeIntervalSince1970))])
    }

    private func periodRow(provider: String, period: PeriodAmount.Period, start: Date) -> PeriodAmount? {
        rows("SELECT start, amount, unit FROM period_amount WHERE provider = ?1 AND period = ?2 AND start = ?3",
             [.text(provider), .text(period.rawValue), .int(Int(start.timeIntervalSince1970))])
            .first.map { PeriodAmount(period: period, start: $0.at, amount: $0.value, unit: $0.unit) }
    }

    private func dayRows(provider: String, from: Date, to: Date) -> [PeriodAmount]? {
        rows("SELECT start, amount, unit FROM period_amount WHERE provider = ?1 AND period = 'day' AND start >= ?2 AND start < ?3",
             [.text(provider), .int(Int(from.timeIntervalSince1970)), .int(Int(to.timeIntervalSince1970))])
            .map { PeriodAmount(period: .day, start: $0.at, amount: $0.value, unit: $0.unit) }
    }

    /// Every provider with anything written down, newest first.
    func providers() -> [String] {
        queue.sync {
            var out: [String] = []
            guard let st = prepare("""
                SELECT provider FROM (SELECT provider, max(ts) AS t FROM reading GROUP BY provider
                  UNION ALL SELECT provider, max(updated) FROM period_amount GROUP BY provider)
                GROUP BY provider ORDER BY max(t) DESC
                """) else { return [] }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) } }
            return out
        }
    }

    // MARK: SQLite

    private enum Value { case int(Int), real(Double), text(String) }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK ? st : nil
    }

    private func bind(_ st: OpaquePointer?, _ values: [Value]) {
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(st, i, Int64(v))
            case .real(let v): sqlite3_bind_double(st, i, v)
            case .text(let v): sqlite3_bind_text(st, i, v, -1, Self.transient)
            }
        }
    }

    private func run(_ sql: String, _ values: [Value]) {
        guard let st = prepare(sql) else { return }
        defer { sqlite3_finalize(st) }
        bind(st, values)
        sqlite3_step(st)
    }

    private func rows(_ sql: String, _ values: [Value]) -> [Row] {
        guard let st = prepare(sql) else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, values)
        var out: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let unit = sqlite3_column_text(st, 2).map { Self.unit(String(cString: $0)) } ?? .credits
            out.append(Row(at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                           value: sqlite3_column_double(st, 1), unit: unit))
        }
        return out
    }

    // MARK: Codes

    static func code(_ period: APIPeriod) -> String {
        switch period {
        case .month: return "month"
        case .billingPeriod: return "billing"
        case .total: return "total"
        case .last30Days: return "last30"
        }
    }

    static func code(_ unit: APIUnit) -> String {
        switch unit {
        case .money(let code): return "money:\(code ?? "")"
        case .named(let name): return "named:\(name)"
        default: return "\(unit)"
        }
    }

    static func unit(_ code: String) -> APIUnit {
        if code.hasPrefix("money:") {
            let currency = String(code.dropFirst("money:".count))
            return .money(currency.isEmpty ? nil : currency)
        }
        if code.hasPrefix("named:") { return .named(String(code.dropFirst("named:".count))) }
        let plain: [String: APIUnit] = [
            "credits": .credits, "characters": .characters, "searches": .searches, "tokens": .tokens,
            "points": .points, "minutes": .minutes, "requests": .requests, "emails": .emails,
            "neurons": .neurons, "computeHours": .computeHours,
        ]
        return plain[code] ?? .credits
    }
}
