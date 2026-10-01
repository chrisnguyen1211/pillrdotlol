import XCTest
@testable import LidEffort

final class ResetCheerTests: XCTestCase {
    private func event(id: String = "claude", name: String = "Claude",
                       window: String = "Current session",
                       resetsAt: Date? = Date(timeIntervalSince1970: 1_800_000_000)) -> UsageResetEvent {
        UsageResetEvent(providerID: id, providerName: name, windowLabel: window, glyph: .claude,
                        previousFraction: 0.9, currentFraction: 0.0, resetsAt: resetsAt)
    }

    func testTheSameEventAlwaysGetsTheSameLine() {
        let one = ResetCheer.line(for: event())
        let again = ResetCheer.line(for: event())
        XCTAssertEqual(one, again, "a card that redraws must not change its mind")
    }

    func testAWeekOfFiveHourResetsReadsFromMostOfTheScript() {
        // Claude resets every five hours. A plain modulo of that cadence
        // landed on two lines out of eight and never left them.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let count = ResetCheer.lines(provider: "Claude", window: "Current session").count
        let seen = Set((0..<(24 * 7 / 5)).map {
            ResetCheer.index(for: event(resetsAt: base.addingTimeInterval(Double($0) * 5 * 3600)), count: count)
        })
        XCTAssertGreaterThanOrEqual(seen.count, count - 2, "\(seen.sorted()) of \(count)")
    }

    func testNoTwoNeighbouringResetsSayTheSameThingTooOften() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let count = ResetCheer.lines(provider: "Claude", window: "Current session").count
        let indices = (0..<200).map {
            ResetCheer.index(for: event(resetsAt: base.addingTimeInterval(Double($0) * 5 * 3600)), count: count)
        }
        let repeats = zip(indices, indices.dropFirst()).filter { $0 == $1 }.count
        // Chance alone repeats one in eight; anything past a quarter means
        // the mixing is not doing its job.
        XCTAssertLessThan(repeats, indices.count / 4, "\(repeats) back-to-back repeats")
    }

    func testTwoAgentsOnTheSameScheduleReadDifferentScripts() {
        let claude = ResetCheer.line(for: event(id: "claude", name: "Claude"))
        let codex = ResetCheer.line(for: event(id: "codex", name: "Codex"))
        XCTAssertNotEqual(claude.title.replacingOccurrences(of: "Claude", with: "X"),
                          codex.title.replacingOccurrences(of: "Codex", with: "X"))
    }

    func testAResetWithoutADateStillGetsALine() {
        let line = ResetCheer.line(for: event(resetsAt: nil))
        XCTAssertFalse(line.title.isEmpty)
    }

    func testEveryLineNamesTheProviderAndSaysTheLimitReset() {
        for line in ResetCheer.lines(provider: "Claude", window: "Current session") {
            let copy = line.title + " " + line.subtitle
            XCTAssertTrue(copy.contains("Claude"), copy)
            XCTAssertTrue(copy.lowercased().contains("limit"), copy)
            XCTAssertTrue(copy.lowercased().contains("reset"), copy)
        }
    }

    func testASessionWindowIsCalledTheSessionLimit() {
        XCTAssertEqual(ResetCheer.limitPhrase("Current session"), "Session limit")
        XCTAssertEqual(ResetCheer.limitPhrase("5-hour"), "5-hour limit")
        XCTAssertEqual(ResetCheer.limitPhrase("All models"), "All models limit")
    }

    func testMidSentenceThePhraseIsLoweredOnlyWhenItIsAnOrdinaryWord() {
        let session = ResetCheer.lines(provider: "Claude", window: "Current session")[2].subtitle
        XCTAssertTrue(session.contains("Claude's session limit"), session)
        let hours = ResetCheer.lines(provider: "Codex", window: "5-hour")[2].subtitle
        XCTAssertTrue(hours.contains("Codex's 5-hour limit"), hours)
        let api = ResetCheer.lines(provider: "Cursor", window: "API usage")[2].subtitle
        XCTAssertTrue(api.contains("Cursor's API usage limit"), api)
    }

    func testLinesFitTheCardForTheAgentsTheLidDrives() {
        // The card is one fixed width and the subtitle is one line; a cheer
        // that gets cut off is worse than the receipt it replaced. The
        // ceilings are what the rendered card (`reset-cards.png`) showed
        // fitting beside the glyph and the close button.
        for (provider, window) in [("Claude", "Current session"), ("Codex", "5-hour"), ("Grok", "Current session")] {
            for line in ResetCheer.lines(provider: provider, window: window) {
                XCTAssertLessThanOrEqual(line.title.count, 24, line.title)
                XCTAssertLessThanOrEqual(line.subtitle.count, 36, line.subtitle)
            }
        }
    }
}
