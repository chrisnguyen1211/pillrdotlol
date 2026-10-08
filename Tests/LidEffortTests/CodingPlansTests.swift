import XCTest
@testable import LidEffort

/// Plan names as each agent reports them, brought to one spelling, priced
/// by agent, and shared out over a day, a week or a month.
final class CodingPlansTests: XCTestCase {
    func testPlanNamesComeToOneSpelling() {
        XCTAssertEqual(CodingPlans.key("LEVEL_ADVANCED", agent: "kimi"), "advanced")
        XCTAssertEqual(CodingPlans.key("KIRO PRO+", agent: "kiro"), "pro_plus")
        XCTAssertEqual(CodingPlans.key("Kiro Pro Max", agent: "kiro"), "pro_max")
        XCTAssertEqual(CodingPlans.key("pro_plus", agent: "cursor"), "pro_plus")
        XCTAssertEqual(CodingPlans.key("Max 5x", agent: "claude"), "max_5x")
        XCTAssertEqual(CodingPlans.key("default_claude_max_20x", agent: "claude"), "max_20x")
        XCTAssertEqual(CodingPlans.key("Kilo Pro", agent: "kilo"), "pro")
        XCTAssertEqual(CodingPlans.key("individual_pro", agent: "copilot"), "individual_pro")
    }

    func testAProviderIDBelongsToItsAgent() {
        XCTAssertEqual(CodingPlans.agent(of: "claude-work"), "claude")
        XCTAssertEqual(CodingPlans.agent(of: "codex-2"), "codex")
        XCTAssertEqual(CodingPlans.agent(of: "cursor"), "cursor")
        XCTAssertEqual(CodingPlans.agent(of: "gemini-api"), "gemini-api")
    }

    func testAPlanIsSharedOutOverTheRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let october = Date(timeIntervalSince1970: 1_791_417_600)   // 31 days
        XCTAssertEqual(CodingPlans.share(of: .today, now: october, calendar: calendar), 1 / 31)
        XCTAssertEqual(CodingPlans.share(of: .week, now: october, calendar: calendar), 7 / 31)
        XCTAssertEqual(CodingPlans.share(of: .month, now: october, calendar: calendar), 1)
    }

    /// The names pillr's providers actually report, from their own fixtures.
    func testReportedPlansFindTheirListPrice() {
        let cases: [(String, String, Double?)] = [
            ("claude", "default_claude_max_5x", 100), ("claude-work", "default_claude_max_20x", 200),
            ("claude", "max", nil),                                 // 5x or 20x: not said
            ("codex", "plus", 20), ("codex-2", "prolite", 100), ("codex", "pro", 200),
            ("cursor", "pro_plus", 60), ("cursor", "free", 0), ("cursor", "ultra", 200),
            ("copilot", "individual", 10), ("copilot", "individual_pro", 39),
            ("kimi", "Advanced", 99), ("kimi", "Basic", 19),
            ("glm", "lite", 18), ("glm", "pro", 80),
            ("minimax", "Token Plan Plus", 22), ("minimax", "Max", 55),
            ("kiro", "Kiro Pro+", 40), ("kiro", "Kiro Pro Max", 100), ("kiro", "Kiro Free", 0),
            ("commandcode", "GOAT", 10), ("commandcode", "individual-pro-v1", 20),
            ("amp", "Megawatt", 20), ("amp", "Gigawatt", 200),
            ("opencode", "Go", 10),
            ("kilo", "Kilo Pro", nil),                              // not a Kilo plan
        ]
        for (provider, plan, usd) in cases {
            XCTAssertEqual(CodingPlans.price(providerID: provider, plan: plan)?.usd, usd, "\(provider) \(plan)")
        }
    }

    func testTheSameNameIsPricedByItsAgent() {
        // Every agent's plan is looked up under that agent, never across them.
        for (agent, plans) in CodingPlans.table {
            for (key, price) in plans {
                XCTAssertGreaterThanOrEqual(price.usd, 0, "\(agent):\(key)")
                XCTAssertEqual(CodingPlans.price(providerID: agent, plan: key), price, "\(agent):\(key)")
            }
        }
    }
}
