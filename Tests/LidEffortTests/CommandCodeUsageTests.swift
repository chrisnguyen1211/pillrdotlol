import XCTest
@testable import LidEffort

/// Pinned to the `/alpha` documents the Command Code desktop app reads.
/// Numbers are round; no live secrets.
final class CommandCodeUsageTests: XCTestCase {
    private let summary = #"{"totalCost":50.5,"totalCount":10,"totalTokensIn":0,"totalTokensOut":0}"#
    private let credits = """
    {"credits":{"monthlyCredits":19.5,"belowThreshold":false},\
    "windowLimits":{\
    "fiveHour":{"used":0,"cap":14,"resetAt":0,"exceeded":false},\
    "weekly":{"used":22.45,"cap":35,"resetAt":1787857355088,"exceeded":false}}}
    """
    private let subscription = """
    {"data":{"planId":"individual-goat",\
    "currentPeriodStart":"2026-08-13T15:21:27.000Z",\
    "currentPeriodEnd":"2026-09-13T15:21:27.000Z"}}
    """

    private func windows() throws -> [LimitWindow] {
        try CommandCodeUsage.windows(
            summaryJSON: summary,
            creditsJSON: credits,
            subscriptionJSON: subscription
        )
    }

    func testTheRingIsMonthlySpendOverCap() throws {
        let monthly = try XCTUnwrap(windows().first { $0.id == "monthly" })
        XCTAssertEqual(monthly.label, "Monthly limit")
        XCTAssertEqual(monthly.usedFraction ?? -1, 50.5 / 70.0, accuracy: 0.0001)
        let reset = try XCTUnwrap(monthly.resetsAt)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.component(.day, from: reset), 13)
        XCTAssertEqual(utc.component(.month, from: reset), 9)
    }

    func testFiveHourResetOfZeroIsAbsence() throws {
        let five = try XCTUnwrap(windows().first { $0.id == "fiveHour" })
        XCTAssertEqual(five.usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(five.resetsAt)
    }

    func testWeeklyWindowUsesMillisecondReset() throws {
        let weekly = try XCTUnwrap(windows().first { $0.id == "weekly" })
        XCTAssertEqual(weekly.usedFraction ?? -1, 22.45 / 35.0, accuracy: 0.0001)
        XCTAssertNotNil(weekly.resetsAt)
    }

    func testHeadlineIsMonthly() throws {
        let snap = ProviderSnapshot(
            id: "commandcode", displayName: "Command Code", glyph: .commandcode,
            fidelity: .official, status: .ok, windows: try windows(),
            headlineID: "monthly"
        )
        XCTAssertEqual(snap.headline?.id, "monthly")
    }

    func testTheSignInPromptNamesTheApp() {
        let snapshot = ProviderSnapshot(
            id: "commandcode", displayName: "Command Code", glyph: .commandcode,
            fidelity: .official, status: .needsAuth, windows: []
        )
        XCTAssertEqual(snapshot.statusMessage,
                       "Sign in with the Command Code app to read your usage")
    }

    func testEmptyCreditsAreNotAReading() {
        XCTAssertThrowsError(try CommandCodeUsage.windows(
            summaryJSON: #"{"totalCost":0}"#,
            creditsJSON: #"{"credits":{}}"#,
            subscriptionJSON: "{}"
        )) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    func testGarbageIsABadResponse() {
        XCTAssertThrowsError(try CommandCodeUsage.windows(
            summaryJSON: "not json",
            creditsJSON: "{}",
            subscriptionJSON: "{}"
        )) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testIndividualGoatIsGOAT() {
        XCTAssertEqual(CommandCodeUsage.planName("individual-goat"), "GOAT")
    }

    func testOrgIdComesFromWhoami() {
        let json = #"{"user":{"id":"u1"},"org":{"id":"org-9"}}"#
        XCTAssertEqual(CommandCodeUsage.orgId(whoamiJSON: json), "org-9")
    }
}

final class CommandCodeCredentialsTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("commandcode-auth-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsTheDesktopAuthFile() throws {
        let url = try file(#"{"apiKey":"user_testkey","userName":"tester"}"#)
        let loaded = try CommandCodeCredentials.load(from: url, environment: [:])
        XCTAssertEqual(loaded.apiKey, "user_testkey")
        XCTAssertEqual(loaded.userName, "tester")
    }

    func testEnvWinsOverTheFile() throws {
        let url = try file(#"{"apiKey":"user_file"}"#)
        let loaded = try CommandCodeCredentials.load(
            from: url,
            environment: ["COMMAND_CODE_API_KEY": "user_env"]
        )
        XCTAssertEqual(loaded.apiKey, "user_env")
    }

    func testHermesNamedKeyIsIgnored() throws {
        let url = try file(#"{"apiKey":"user_file"}"#)
        let loaded = try CommandCodeCredentials.load(
            from: url,
            environment: ["COMMANDCODE_API_KEY": "user_hermes"]
        )
        XCTAssertEqual(loaded.apiKey, "user_file")
    }

    func testAMissingFileIsNeedsAuth() {
        XCTAssertThrowsError(try CommandCodeCredentials.load(
            from: URL(fileURLWithPath: "/tmp/missing-commandcode-auth.json"),
            environment: [:]
        )) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }
}

/// The mark is geometric rather than traced, so its boxes are pinned: four
/// corner loops and a cross, all inside the unit box, reading as ⌘.
final class CommandCodeGlyphTests: XCTestCase {
    func testTheOutlineIsSixLoopsInsideTheUnitBox() {
        let outline = GlyphOutline.commandcode
        XCTAssertEqual(outline.count, 6)
        XCTAssertEqual(ProviderGlyph.commandcode.outline, outline)
        XCTAssertEqual(ProviderGlyph.commandcode.rawValue, "commandcode")
        for loop in outline {
            XCTAssertEqual(loop.count, 4)
            for point in loop {
                XCTAssertTrue((0...1).contains(point.x), "x \(point.x) outside the unit box")
                XCTAssertTrue((0...1).contains(point.y), "y \(point.y) outside the unit box")
            }
        }
    }
}
