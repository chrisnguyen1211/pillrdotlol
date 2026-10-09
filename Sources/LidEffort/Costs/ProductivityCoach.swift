import Foundation

/// Says so when you beat your own best day, week or month — agent time,
/// commits, sessions finished — and gives a nudge when a working week runs
/// well under your usual pace. Always against your own record, never anyone
/// else's; at most one card a day, never at the weekend.
enum ProductivityCoach {
    enum Metric: String, CaseIterable { case busy, commits, finished }
    enum Timeframe: String, CaseIterable { case day, week, month }

    /// Each metric's daily figures, by the local day's start.
    struct Figures {
        var busy: [Date: Double] = [:]
        var commits: [Date: Double] = [:]
        var finished: [Date: Double] = [:]

        func series(_ metric: Metric) -> [Date: Double] {
            switch metric {
            case .busy: return busy
            case .commits: return commits
            case .finished: return finished
            }
        }
    }

    struct Finding: Equatable {
        let kind: ActivityLedger.CoachEvent.Kind
        let metric: Metric
        let timeframe: Timeframe
        let period: Date
        let value: Double
        let previous: Double?
    }

    /// Below this, a "record" is noise: a first short day is not news.
    static func floor(_ metric: Metric, _ timeframe: Timeframe) -> Double {
        let scale: Double = timeframe == .day ? 1 : (timeframe == .week ? 4 : 12)
        switch metric {
        case .busy: return 1800 * scale
        case .commits, .finished: return 3 * scale
        }
    }

    /// How many earlier periods with anything in them make a record mean
    /// something.
    static func history(_ timeframe: Timeframe) -> Int {
        switch timeframe {
        case .day: return 7
        case .week: return 3
        case .month: return 2
        }
    }

    static func period(_ timeframe: Timeframe, of date: Date, calendar: Calendar) -> Date {
        switch timeframe {
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!.start
        case .month: return calendar.dateInterval(of: .month, for: date)!.start
        }
    }

    /// Records the current day, week and month have broken, and a nudge when
    /// it is due — those already logged left out.
    static func findings(_ figures: Figures, now: Date, calendar: Calendar = .current,
                         logged: (Finding) -> Bool) -> [Finding] {
        var out: [Finding] = []
        for timeframe in Timeframe.allCases.reversed() {
            for metric in Metric.allCases {
                var totals: [Date: Double] = [:]
                for (day, value) in figures.series(metric) where day <= now {
                    totals[period(timeframe, of: day, calendar: calendar), default: 0] += value
                }
                let current = period(timeframe, of: now, calendar: calendar)
                let value = totals[current] ?? 0
                let earlier = totals.filter { $0.key < current && $0.value > 0 }
                guard earlier.count >= history(timeframe), value >= floor(metric, timeframe),
                      let best = earlier.values.max(), value > best else { continue }
                let finding = Finding(kind: .record, metric: metric, timeframe: timeframe, period: current, value: value, previous: best)
                if !logged(finding) { out.append(finding) }
            }
        }
        if let nudge = nudge(figures, now: now, calendar: calendar), !logged(nudge) { out.append(nudge) }
        return out
    }

    /// A working weekday afternoon, and agent time this week under half of
    /// what the four weeks before would have had by now.
    static func nudge(_ figures: Figures, now: Date, calendar: Calendar) -> Finding? {
        var monday = Calendar(identifier: .iso8601)
        monday.timeZone = calendar.timeZone
        let weekday = monday.component(.weekday, from: now)          // 1 = Sunday
        guard (2...6).contains(weekday), calendar.component(.hour, from: now) >= 15 else { return nil }
        let thisWeek = monday.dateInterval(of: .weekOfYear, for: now)!
        func busy(in interval: DateInterval) -> Double {
            figures.busy.filter { interval.contains($0.key) }.values.reduce(0, +)
        }
        let weeks = (1...4).map { back in
            DateInterval(start: monday.date(byAdding: .weekOfYear, value: -back, to: thisWeek.start)!, duration: thisWeek.duration)
        }.map(busy)
        guard weeks.filter({ $0 > 0 }).count >= 2 else { return nil }
        let usual = weeks.reduce(0, +) / Double(weeks.count)
        let expected = usual * Double(weekday - 1) / 5
        let sofar = busy(in: thisWeek)
        guard expected >= 3600, sofar < expected / 2 else { return nil }
        return Finding(kind: .nudge, metric: .busy, timeframe: .week, period: calendar.startOfDay(for: now),
                       value: sofar, previous: expected)
    }

    // MARK: Words

    static func amount(_ metric: Metric, _ value: Double) -> String {
        switch metric {
        case .busy: return TimelinePane.duration(value)
        case .commits: return L10n.t("\(Int(value)) commits")
        case .finished: return L10n.t("\(Int(value)) sessions")
        }
    }

    static func title(_ finding: Finding) -> String {
        guard finding.kind == .record else { return L10n.t("A quieter week so far") }
        switch (finding.metric, finding.timeframe) {
        case (.busy, .day): return L10n.t("Your agents' best day yet")
        case (.busy, .week): return L10n.t("Your agents' best week yet")
        case (.busy, .month): return L10n.t("Your agents' best month yet")
        case (.commits, .day): return L10n.t("Most commits in a day")
        case (.commits, .week): return L10n.t("Most commits in a week")
        case (.commits, .month): return L10n.t("Most commits in a month")
        case (.finished, .day): return L10n.t("Most sessions finished in a day")
        case (.finished, .week): return L10n.t("Most sessions finished in a week")
        case (.finished, .month): return L10n.t("Most sessions finished in a month")
        }
    }

    static func note(_ finding: Finding) -> CardNote {
        if finding.kind == .nudge {
            return CardNote(title: title(finding),
                            subtitle: L10n.t("\(amount(.busy, finding.value)) of agent work this week, under half your usual pace"),
                            status: L10n.t("One small task shipped still counts"), good: false)
        }
        let past = finding.previous.map { amount(finding.metric, $0) } ?? "—"
        return CardNote(title: title(finding),
                        subtitle: L10n.t("\(amount(finding.metric, finding.value)), past your best of \(past)"),
                        status: L10n.t("New record · keep it going"), good: true)
    }
}

extension ProductivityCoach {
    /// How far back records are looked for.
    static let lookback: TimeInterval = 120 * 86_400

    /// Every daily figure the coach and the dashboard use: agent time and
    /// finishes from the activity ledger, commits from git in the folders the
    /// agents worked in.
    static func gather(ledger: ActivityLedger, stores: [CostStore], now: Date = Date(),
                       calendar: Calendar = .current) -> Figures {
        let since = calendar.startOfDay(for: now.addingTimeInterval(-lookback))
        let summary = ledger.summary(from: since, to: now, now: now, calendar: calendar)
        var figures = Figures()
        figures.busy = summary.busyByDay
        figures.finished = summary.finishedByDay.mapValues(Double.init)
        let folders = ledger.folders(since: since) + stores.flatMap { $0.folders(since: Int(since.timeIntervalSince1970)) }
        figures.commits = CommitLog.days(roots: CommitLog.roots(of: folders), since: since, calendar: calendar, now: now)
            .mapValues(Double.init)
        return figures
    }

    /// Whether a finding is already in the log.
    static func isLogged(_ finding: Finding, in events: [ActivityLedger.CoachEvent]) -> Bool {
        events.contains {
            $0.kind == finding.kind && $0.metric == finding.metric.rawValue && $0.timeframe == finding.timeframe.rawValue
                && abs($0.period.timeIntervalSince(finding.period)) < 1
        }
    }

    /// Looks, logs what it finds, and returns the one card to show, if a card
    /// has not been shown today already.
    static func check(ledger: ActivityLedger, stores: [CostStore], now: Date = Date(), calendar: Calendar = .current) -> Finding? {
        let figures = gather(ledger: ledger, stores: stores, now: now, calendar: calendar)
        let events = ledger.coachEvents(limit: 500)
        let found = findings(figures, now: now, calendar: calendar) { isLogged($0, in: events) }
        let shownToday = events.contains { $0.shown && calendar.isDate($0.at, inSameDayAs: now) }
        let pick = shownToday ? nil : found.first
        for finding in found {
            ledger.log(.init(at: now, kind: finding.kind, metric: finding.metric.rawValue, timeframe: finding.timeframe.rawValue,
                             period: finding.period, value: finding.value, previous: finding.previous, shown: finding == pick))
        }
        return pick
    }
}
