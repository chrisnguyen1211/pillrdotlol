import XCTest
@testable import LidEffort

/// The done card's changes, tokens per session, the hand-off brief and the
/// day's recap.
final class PillInsightsTests: XCTestCase {
    private func lines(_ objects: [[String: Any]]) -> String {
        objects.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }
    private func temp(_ text: String, name: String = "t.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Changes

    func testShortstatReadsAsALine() {
        XCTAssertEqual(GitChanges.summary(shortstat: " 3 files changed, 42 insertions(+), 7 deletions(-)\n", untracked: 2),
                       "3 files · +42 −7 · 2 new")
        XCTAssertEqual(GitChanges.summary(shortstat: " 1 file changed, 1 insertion(+)\n", untracked: 0), "1 file · +1 −0")
        XCTAssertNil(GitChanges.summary(shortstat: "", untracked: 0), "a clean tree says nothing")
    }

    func testARealRepositoryAnswersQuickly() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let git = { (args: [String]) in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        git(["init", "-q"])
        try "a\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-qm", "one"])
        try "a\nb\nc\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitChanges.summary(cwd: repo), "1 file · +2 −0 · 1 new")
        XCTAssertNil(GitChanges.summary(cwd: FileManager.default.temporaryDirectory.path + "/not-a-repo-\(UUID())"))
    }

    // MARK: Tokens

    func testClaudeTokensCountEachMessageOnce() throws {
        let usage: [String: Any] = ["input_tokens": 10, "cache_creation_input_tokens": 100,
                                    "cache_read_input_tokens": 1000, "output_tokens": 50]
        let block = { (kind: String) -> [String: Any] in
            ["type": "assistant", "message": ["id": "m1", "usage": usage, "content": [["type": kind]]]]
        }
        let url = try temp(lines([block("thinking"), block("text"), block("tool_use")]))
        let count = try XCTUnwrap(TokenTally.count(url, format: .claude))
        XCTAssertEqual(count.total, 1160, "three blocks of one message are one message")
        XCTAssertEqual(count.cached, 1000)
        // Appended later: only the new part is read, and added.
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(lines([["type": "assistant", "message": ["id": "m2", "usage": ["output_tokens": 40]]]]).utf8))
        try handle.close()
        XCTAssertEqual(TokenTally.count(url, format: .claude)?.total, 1200)
    }

    func testCodexTakesTheLatestRunningTotalAndGrokAddsTurns() throws {
        let codex = try temp(lines([
            ["payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 500, "cached_input_tokens": 100]]]],
            ["payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 900, "cached_input_tokens": 300]]]],
        ]))
        XCTAssertEqual(TokenTally.count(codex, format: .codex), TokenCount(total: 900, cached: 300))
        let turn = { (n: Int) -> [String: Any] in
            ["params": ["update": ["sessionUpdate": "turn_completed", "usage": ["totalTokens": n, "cachedReadTokens": 1]]]]
        }
        let grok = try temp(lines([turn(300), turn(700)]))
        XCTAssertEqual(TokenTally.count(grok, format: .grok)?.total, 1000)
    }

    func testTokensReadInTwoFigures() {
        XCTAssertEqual(TokenCount.compact(1_234_567), "1.2M")
        XCTAssertEqual(TokenCount.compact(44_400_000), "44M")
        XCTAssertEqual(TokenCount.compact(84_321), "84k")
        XCTAssertEqual(TokenCount.compact(950), "950")
    }

    // MARK: Hand-off

    func testTheBriefSaysWhereAndWhat() {
        let brief = Handoff.compose(from: "Claude Code", folder: "spyx", branch: "main",
                                    ask: "Add a forecast to the rings", lead: "Forecast is in; tests pass.")
        XCTAssertTrue(brief.hasPrefix("I'm picking up work Claude Code was doing in spyx, on branch main."), brief)
        XCTAssertTrue(brief.contains("“Add a forecast to the rings”"))
        XCTAssertTrue(brief.hasSuffix("then carry on from there."))
    }

    func testTheBriefIsNeverRunAsShell() throws {
        let nasty = #"it's done; $(touch /tmp/spyx-handoff-pwned) `id` "quoted" \ end"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "printf %s " + Handoff.shellQuote(nasty)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), nasty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/spyx-handoff-pwned"))
    }

    // MARK: Recap

    func testTheRecapCountsOnlyToday() throws {
        let today = ISO8601DateFormatter().string(from: Date())
        let yesterday = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-36 * 3600))
        let url = try temp(lines([
            ["type": "assistant", "timestamp": yesterday,
             "message": ["id": "old", "usage": ["output_tokens": 999], "content": [["type": "tool_use"]]]],
            ["type": "assistant", "timestamp": today,
             "message": ["id": "new", "usage": ["output_tokens": 40], "content": [["type": "tool_use"], ["type": "tool_use"]]]],
        ]))
        let agent = DailyRecap.tally(files: [url], name: "Claude Code",
                                     since: Calendar.current.startOfDay(for: Date()), format: .claude)
        XCTAssertEqual(agent.sessions, 1)
        XCTAssertEqual(agent.toolCalls, 2)
        XCTAssertEqual(agent.tokens, 40)
    }

    func testTheRecapIsDueOnceADayAfterSix() {
        let calendar = Calendar.current
        let five = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        let seven = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: Date())!
        XCTAssertFalse(DailyRecapScheduler.isDue(now: five, enabled: true, lastShown: nil))
        XCTAssertTrue(DailyRecapScheduler.isDue(now: seven, enabled: true, lastShown: nil))
        XCTAssertFalse(DailyRecapScheduler.isDue(now: seven, enabled: true, lastShown: seven.addingTimeInterval(-60)))
        XCTAssertTrue(DailyRecapScheduler.isDue(now: seven, enabled: true, lastShown: seven.addingTimeInterval(-86_400)))
        XCTAssertFalse(DailyRecapScheduler.isDue(now: seven, enabled: false, lastShown: nil))
    }

    /// This Mac's day, read-only: `SPYX_LIVE=1 swift test --filter PillInsightsTests`.
    func testLiveRecap() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPYX_LIVE"] == "1")
        let started = Date()
        let recap = DailyRecap.read()
        print("RECAP \(recap.title) | \(recap.subtitle) | \(recap.status) | \(String(format: "%.1fs", Date().timeIntervalSince(started)))")
        for agent in recap.agents { print("RECAP   \(agent.name): \(agent.sessions) sessions, \(agent.toolCalls) calls, \(agent.tokens) tokens") }
    }
}
