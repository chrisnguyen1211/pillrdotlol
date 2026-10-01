import SQLite3
import XCTest
@testable import LidEffort

final class CodexUsageTests: XCTestCase {
    private func windows(_ json: String) throws -> [LimitWindow] {
        try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBothWindowsAreReadWhenBothArePresent() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800600000}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800}},
         "credits":{"balance":"100"},"model_usage":{"spark":99}}
        """)
        XCTAssertEqual(result.map(\.duration), [18000, 604800])
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_800_001_000))
    }

    /// The reported case: a free-plan account's primary window was 30 days,
    /// not 5 hours or 7 — recorded from a live request. The old parser only
    /// recognised two fixed durations and silently dropped anything else,
    /// which on this exact account meant every window vanished and the ring
    /// reported nothing metered on an account that was genuinely 16% through
    /// a real limit.
    func testAMonthlyPrimaryWindowIsNotDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000,
        "reset_after_seconds":1838382,"reset_at":1790585722},"secondary_window":null},
         "plan_type":"free"}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(CodexUsage.plan(from: Data("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000}},
         "plan_type":"free"}
        """.utf8)), "free")
        XCTAssertEqual(result.first?.label, "Monthly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.16, accuracy: 0.0001)
    }

    func testPaceUsesTheReportedCycleRegardlessOfPlanName() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [18000, 604800, 2592000] {
            let result = try CodexUsage.windows(from: Data("""
            {"rate_limit":{"primary_window":{"used_percent":80,
            "limit_window_seconds":\(seconds),"reset_after_seconds":\(seconds / 2)}}}
            """.utf8), now: now)
            let window = try XCTUnwrap(result.first)
            XCTAssertEqual(window.duration, Double(seconds))
            XCTAssertEqual(try XCTUnwrap(window.usagePace(now: now)).percentagePoints, 30,
                           accuracy: 0.00001)
        }
    }

    /// A duration that is none of the named buckets still gets a usable label
    /// instead of being the thing that makes the fetch fail.
    func testAnUnrecognisedDurationStillGetsALabel() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":259200}}}
        """)
        XCTAssertEqual(result.first?.label, "3d limit")
    }

    // The endpoint can put a weekly-only allowance in primary_window.
    func testANullSecondaryIsDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,
        "reset_after_seconds":604119,"reset_at":1789308033},"secondary_window":null}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_789_308_033))
    }

    func testStillReadsACountdownIfABuildEmitsOne() throws {
        let result = try windows("""
        {"rate_limit":{
        "primary_window":{"used_percent":8,"limit_window_seconds":604800},
        "secondary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":120}}}
        """)
        XCTAssertEqual(result.map(\.duration), [604800, 18000])
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.usedFraction, 0.08)
        XCTAssertNil(result.first?.resetsAt)
        XCTAssertEqual(result.last?.usedFraction, 0)
        XCTAssertEqual(result.last?.resetsAt, Date(timeIntervalSince1970: 1_800_000_120))
    }

    /// The reported symptom: the tooltip showed only the weekly window and the
    /// ring showed a dash. A null `used_percent` on one window threw the whole
    /// fetch away, so a good weekly window was hidden behind the bad hourly
    /// one. One malformed window is skipped, not fatal.
    func testAWindowMissingUsedPercentIsSkippedRatherThanFailing() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":29,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["secondary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.29, accuracy: 0.0001)
    }

    /// A window without a duration still gets a fallback label instead of
    /// failing the decode of the whole response.
    func testAWindowMissingItsDurationStillParses() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":8,"reset_at":1800001000},
          "secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.label, "Current session")
        XCTAssertEqual(result.last?.label, "Weekly limit")
    }

    /// Both windows malformed is still an error, not an empty success — the
    /// store turns it into "waiting", not a silent 0%.
    func testBothWindowsMissingLeavesNothingMetered() {
        XCTAssertThrowsError(try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000},
          "secondary_window":null}}
        """))
    }

    func testDecodesProfileTokenUsageAndBuildsAThirtyDaySeries() throws {
        let json = """
        {"profile":{"display_name":"Test"},
         "stats":{"lifetime_tokens":1200,"peak_daily_tokens":300,
         "longest_running_turn_sec":4020,"current_streak_days":2,"longest_streak_days":11,
         "daily_usage_buckets":[
           {"start_date":"2026-08-12","tokens":100},
           {"start_date":"2026-09-03","tokens":200},
           {"start_date":"2026-09-08","tokens":300}
         ]}}
        """
        let usage = try CodexUsage.profileUsage(from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!

        XCTAssertEqual(usage.last30Days(now: now, calendar: calendar).count, 30)
        XCTAssertEqual(usage.last30Days(now: now, calendar: calendar).first?.startDate,
                       "2026-08-11")
        XCTAssertEqual(usage.usageInLast30Days(now: now, calendar: calendar), 600)
        XCTAssertEqual(usage.peakDailyTokens, 300)
        XCTAssertEqual(usage.summary?.lifetimeTokens, 1200)
        XCTAssertEqual(usage.summary?.peakDailyTokens, 300)
        XCTAssertEqual(usage.summary?.longestRunningTurnSeconds, 4020)
        XCTAssertEqual(usage.summary?.currentStreakDays, 2)
        XCTAssertEqual(usage.summary?.longestStreakDays, 11)
        XCTAssertEqual(usage.usageToday(now: now, calendar: calendar), nil,
                       "a missing current-day bucket should be shown as Pending")
    }

    /// `/wham/rate-limit-reset-credits` reports how many unused resets remain
    /// and when the next one expires. The count is its own field because the
    /// credits array can be truncated.
    func testResetCreditsReadsAvailableCountAndSoonestExpiry() throws {
        let json = """
        {"credits":[
          {"id":"later","reset_type":"rate_limit","status":"available",
           "granted_at":"2026-09-01T12:00:00Z",
           "expires_at":"2026-09-20T12:00:00.250Z",
           "title":"Reset","description":"Unused reset","extra":true},
          {"id":"spent","reset_type":"rate_limit","status":"redeemed",
           "granted_at":"2026-08-01T00:00:00Z",
           "expires_at":"2026-09-12T00:00:00Z"},
          {"id":"sooner","reset_type":"rate_limit","status":"available",
           "granted_at":"2026-09-02T00:00:00Z",
           "expires_at":"2026-09-15T08:00:00Z"}
         ],
         "available_count":2,
         "server_time":"2026-09-10T00:00:00Z"}
        """
        let result = try CodexUsage.resetCredits(from: Data(json.utf8))
        XCTAssertEqual(result.availableCount, 2)
        XCTAssertEqual(result.credits.map(\.id), ["later", "spent", "sooner"])
        XCTAssertEqual(result.available.map(\.id), ["sooner", "later"])
        XCTAssertEqual(result.nextExpiry, ISO8601DateFormatter().date(from: "2026-09-15T08:00:00Z"))

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(result.available.last?.expiresAt,
                       fractional.date(from: "2026-09-20T12:00:00.250Z"))
    }

    func testResetCreditsTrustsAvailableCountWhenTheArrayIsTruncated() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"available_count":3,"credits":[
          {"id":"only","status":"available","expires_at":"2026-09-18T00:00:00Z"}
        ]}
        """.utf8))
        XCTAssertEqual(result.availableCount, 3)
        XCTAssertEqual(result.credits.map(\.id), ["only"])
        XCTAssertEqual(result.available.count, 1)
        XCTAssertEqual(result.nextExpiry, ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z"))
    }

    func testResetCreditsCountsAvailableCreditsWhenThePayloadOmitsTheCount() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"credits":[
          {"id":"a","status":"available","expires_at":"2026-09-18T00:00:00Z"},
          {"id":"b","status":"redeemed","expires_at":"2026-09-10T00:00:00Z"}
        ]}
        """.utf8))
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertEqual(result.available.map(\.id), ["a"])
    }

    /// A non-object entry is skipped; an unreadable date becomes no expiry.
    /// None of that is a reason to fail the usage fetch.
    func testResetCreditsSkipsMalformedCreditsRatherThanFailing() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"credits":[
          "nope",
          {"id":"ok","status":"available","expires_at":null}
        ],"available_count":1}
        """.utf8))
        XCTAssertEqual(result.credits.map(\.id), ["ok"])
        XCTAssertNil(result.credits.first?.expiresAt)
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertNil(result.nextExpiry)
    }

    func testResetCreditsThrowsOnlyOnInvalidJSON() throws {
        XCTAssertThrowsError(try CodexUsage.resetCredits(from: Data("not-json".utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
        XCTAssertEqual(try CodexUsage.resetCredits(from: Data("{}".utf8)).availableCount, 0)
        XCTAssertEqual(try CodexUsage.resetCredits(from: Data("[]".utf8)).credits, [])
    }

    func testAccountUsageCardGetsRoomForTheActivitySection() {
        let plain = NotchLayout.cardHeight(windowCount: 2)
        let withTokens = NotchLayout.cardHeight(windowCount: 2, hasTokenUsage: true)

        XCTAssertGreaterThan(withTokens, plain)
        XCTAssertEqual(
            withTokens - plain,
            NotchLayout.codexUsageTop + NotchLayout.hairline + NotchLayout.blockSpacing
                + NotchLayout.codexMetricTop + NotchLayout.codexMetricHeight
                + NotchLayout.codexMetricBottom
                + NotchLayout.hairline
                + 2 * NotchLayout.cardBodyLineHeight
                + NotchLayout.codexUsageRowGap
                + NotchLayout.codexChartTop + NotchLayout.codexChartHeight,
            accuracy: 0.001
        )
    }

}

/// The activity signal is a heuristic — a rollout written moments ago — so what
/// it will and will not claim is worth pinning down.
@MainActor
final class CodexActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testARolloutWrittenJustNowIsBusy() throws {
        let s = try XCTUnwrap(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-2), staleAfter: 8, now: now
        ))
        XCTAssertEqual(s.state, .busy)
        XCTAssertEqual(s.name, "Codex")
    }

    /// It errs short on purpose: a finished turn must not keep the ring spinning.
    func testAnOlderRolloutIsNotActivity() {
        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-30), staleAfter: 8, now: now
        ))
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertEqual(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-8), staleAfter: 8, now: now
        )?.state, .busy)

        XCTAssertEqual(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-15), staleAfter: 8, now: now
        )?.state, .success)

        XCTAssertEqual(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-20), staleAfter: 8, now: now
        )?.state, .idle)

        XCTAssertNil(CodexActivityMonitor.session(
            id: "codex.x", name: "Codex",
            modified: now.addingTimeInterval(-24), staleAfter: 8, now: now
        ))
    }
}

/// "Codex" is two programs. The CLI and the VS Code extension append to a
/// rollout under `~/.codex/sessions`; the desktop app — ChatGPT.app, which is
/// what most people now mean — writes none of them, keeping its threads in
/// `~/.codex/sqlite/codex-dev.db` instead.
///
/// The activity monitor watched only the rollouts, so it could never see the
/// desktop app working: on this machine every rollout was written by VS Code
/// and the newest was three days old, while the desktop catalogue had been
/// touched seconds ago. The ring simply never span.
final class CodexDesktopActivityTests: XCTestCase {
    private let store = URL(fileURLWithPath: "/tmp/codex-desktop-test.db")

    private func makeCatalogue(rows: [(Double, String)]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-dev-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
            CREATE TABLE local_thread_catalog (
                thread_id TEXT, display_title TEXT NOT NULL,
                source_updated_at REAL NOT NULL, source_kind TEXT);
            """, nil, nil, nil)
        for (at, title) in rows {
            sqlite3_exec(db, """
                INSERT INTO local_thread_catalog
                (thread_id, display_title, source_updated_at, source_kind)
                VALUES ('t', '\(title)', \(at), 'chatgpt');
                """, nil, nil, nil)
        }
        return url
    }

    func testItReadsTheNewestDesktopThread() throws {
        let url = try makeCatalogue(rows: [(1_788_000_000, "Older"),
                                           (1_788_582_173.099, "Deep SaaS Research")])
        defer { try? FileManager.default.removeItem(at: url) }

        let newest = try XCTUnwrap(CodexStore.newestDesktopThread(in: url))
        XCTAssertEqual(newest.title, "Deep SaaS Research")
        // Seconds with a fraction, not the milliseconds the `threads` table
        // next door uses — reading it as milliseconds puts it in 1970.
        XCTAssertEqual(newest.updatedAt.timeIntervalSince1970, 1_788_582_173.099, accuracy: 0.01)
    }

    /// The reported symptom: the desktop app is working now, the rollouts are
    /// days old, and the ring has to spin.
    @MainActor func testDesktopWorkCountsAsActivity() throws {
        let now = Date()
        let url = try makeCatalogue(rows: [(now.addingTimeInterval(-2).timeIntervalSince1970,
                                            "Deep SaaS Research")])
        defer { try? FileManager.default.removeItem(at: url) }

        // No rollout store at all, which is the case for someone who has only
        // ever used the desktop app.
        let sessions = CodexActivityMonitor.read(
            stateStore: URL(fileURLWithPath: "/nonexistent/state.sqlite"),
            desktopStore: url, staleAfter: 8, now: now
        )
        XCTAssertEqual(sessions.count, 1, "the desktop app's work was invisible")
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "Deep SaaS Research",
                       "the thread's own name is more use than \"Codex\"")
    }

    /// And it still errs short: a finished conversation must not keep spinning.
    @MainActor func testAnOldDesktopThreadIsNotActivity() throws {
        let now = Date()
        let url = try makeCatalogue(rows: [(now.addingTimeInterval(-600).timeIntervalSince1970,
                                            "Yesterday's chat")])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(CodexActivityMonitor.read(
            stateStore: URL(fileURLWithPath: "/nonexistent/state.sqlite"),
            desktopStore: url, staleAfter: 8, now: now
        ).isEmpty)
    }

    func testAMissingCatalogueIsNotAnError() {
        XCTAssertNil(CodexStore.newestDesktopThread(
            in: URL(fileURLWithPath: "/nonexistent/codex-dev.db")
        ))
    }
}

final class UsageBlockTests: XCTestCase {
    /// The wording the vendor's own banner uses — a clock time, not a
    /// countdown, because that is the thing you are waiting for.
    func testItReadsAsAClockTime() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        let text = block.summary(now: now)
        XCTAssertTrue(text.hasPrefix("Paused until "), text)
        XCTAssertFalse(text.contains("min"), "a countdown, not the time it lifts")
    }

    /// The clock keeps the locale's hour cycle, as the reset line does: a
    /// 24-hour region reads "Paused until 16:13", not "4:13 PM".
    func testTheClockFollowsTheLocalesHourCycle() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        for id in ["fr_FR", "de_DE", "ja_JP", "en_GB"] {
            let locale = Locale(identifier: id)
            let text = block.summary(now: now, locale: locale)
            let symbols = DateFormatter()
            symbols.locale = locale
            XCTAssertFalse(text.contains(symbols.amSymbol) || text.contains(symbols.pmSymbol),
                           "\(id) got a 12-hour clock: \(text)")
        }
        let american = block.summary(now: now, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(american.contains("AM") || american.contains("PM"),
                      "en_US lost its AM/PM: \(american)")
    }

    /// With no reset time there is nothing to promise, so it says only what it
    /// knows.
    func testWithoutAResetItSaysOnlyTheReason() {
        XCTAssertEqual(UsageBlock(reason: "Paused", resetsAt: nil).summary(), "Paused")
    }

    /// A reset already in the past is not worth showing as a deadline.
    func testAPastResetIsDropped() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let block = UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(-60))
        XCTAssertEqual(block.summary(now: now), "Paused")
    }

    /// The card has to be tall enough for the line, or it is clipped — the same
    /// mistake the status message made.
    func testTheCardMakesRoomForIt() {
        let plain = NotchLayout.cardHeight(windowCount: 1)
        let blocked = NotchLayout.cardHeight(windowCount: 1,
                                             blockMessage: "Paused until 4:13 PM")
        XCTAssertGreaterThan(blocked, plain, "the blocked line has no room to be drawn in")
    }

    /// And a long one gets the room it actually needs.
    func testALongBlockMessageGetsMoreThanOneLine() {
        let long = "Workspace limit reached until Thu 4:13 PM — every seat on this "
                 + "workspace shares one allowance and it is spent"
        XCTAssertGreaterThan(NotchLayout.bodyTextHeight(long),
                             NotchLayout.cardBodyLineHeight)
        XCTAssertGreaterThan(
            NotchLayout.cardHeight(windowCount: 1, blockMessage: long),
            NotchLayout.cardHeight(windowCount: 1, blockMessage: "Paused")
        )
    }
}
