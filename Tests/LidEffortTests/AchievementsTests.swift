import XCTest
@testable import LidEffort

/// Badges from your own figures, bronze to gold, given once and kept.
final class AchievementsTests: XCTestCase {
    func testEachTierUpToTheOneReachedIsGiven() {
        var stats = Achievements.Stats()
        stats.commitsTotal = 300
        let commits = Achievements.reached(stats).filter { $0.family == "commits" }.map(\.tier)
        XCTAssertEqual(commits, [.bronze, .silver])
    }

    func testFastAnswersAndCheapSessionsAreBetterLow() {
        var stats = Achievements.Stats()
        stats.answered = 25
        stats.medianAnswer = 9
        XCTAssertEqual(Achievements.family("answers")?.reached(stats), .silver)
        stats.answered = 5
        XCTAssertNil(Achievements.family("answers")?.reached(stats), "too few answers to tell")
        stats.finishedThisMonth = 30
        stats.costPerSession = 0.4
        XCTAssertEqual(Achievements.family("thrifty")?.reached(stats), .gold)
    }

    func testTokenMaxxerIsForWhatWasPaidByUse() {
        var stats = Achievements.Stats()
        stats.paidThisMonth = 250
        XCTAssertEqual(Achievements.family("tokenMaxxer")?.reached(stats), .silver)
    }

    func testABadgeIsGivenOnceAndKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "achievements-\(UUID().uuidString)"))
        var stats = Achievements.Stats()
        stats.hoursTotal = 12
        XCTAssertEqual(Achievements.award(stats, defaults: defaults).map(\.id), ["hours.1"])
        XCTAssertTrue(Achievements.award(stats, defaults: defaults).isEmpty, "not given twice")
        stats.hoursTotal = 120
        XCTAssertEqual(Achievements.award(stats, defaults: defaults).map(\.id), ["hours.2"])
        XCTAssertEqual(Set(Achievements.earned(defaults).keys), ["hours.1", "hours.2"])
    }

    func testTheLongestStreakIsFound() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_791_417_600))
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: start)! }
        let busy: [Date: Double] = [day(0): 600, day(1): 600, day(2): 30, day(3): 600, day(4): 600, day(5): 600]
        XCTAssertEqual(Achievements.longestStreak(busy, calendar: calendar), 3, "a 30-second day breaks the run")
    }

    func testEveryBadgeHasANameAndARequirement() {
        for family in Achievements.families {
            for tier in Achievements.Tier.allCases {
                let badge = Achievements.Badge(family: family.id, tier: tier)
                XCTAssertFalse(Achievements.name(badge).isEmpty, badge.id)
                XCTAssertFalse(Achievements.requirement(badge).isEmpty, badge.id)
            }
        }
        XCTAssertGreaterThanOrEqual(Achievements.families.count * 3, 45)
    }

    /// Each badge earned gets its card once; those held before the update
    /// don't all arrive at once.
    func testEveryNewBadgeIsAnnouncedOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "announce-\(UUID().uuidString)"))
        var stats = Achievements.Stats()
        stats.hoursTotal = 12
        _ = Achievements.award(stats, defaults: defaults)
        XCTAssertEqual(Achievements.unannounced(defaults), [], "held before: already told")
        stats.hoursTotal = 120
        stats.bestStreak = 8
        let new = Achievements.award(stats, defaults: defaults)
        XCTAssertEqual(Set(Achievements.unannounced(defaults).map(\.id)), Set(new.map(\.id)))
        XCTAssertTrue(new.map(\.id).contains("hours.2"))
        Achievements.markAnnounced(new, defaults)
        XCTAssertEqual(Achievements.unannounced(defaults), [], "told once")
        let note = Achievements.note(new)
        XCTAssertEqual(note.badges, new)
        XCTAssertTrue(note.good)
    }
}
