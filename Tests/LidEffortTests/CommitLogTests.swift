import XCTest
@testable import LidEffort

/// Commits are read from git, and the last read is reused for any window
/// inside it: the year asked for badges also answers the 120 days records ask.
final class CommitLogTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("commitlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q")
        try git("config", "user.email", "me@example.com")
        try git("config", "user.name", "Me")
        try git("config", "commit.gpgsign", "false")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func git(_ arguments: String..., date: Date? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        if let date {
            environment["GIT_AUTHOR_DATE"] = "@\(Int(date.timeIntervalSince1970)) +0000"
            environment["GIT_COMMITTER_DATE"] = "@\(Int(date.timeIntervalSince1970)) +0000"
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    private func commit(daysAgo: Double, now: Date) throws {
        try git("commit", "-q", "--allow-empty", "-m", "c\(daysAgo)", date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func testAShorterWindowIsCutFromTheLastRead() throws {
        let now = Date()
        try commit(daysAgo: 300, now: now)
        try commit(daysAgo: 30, now: now)
        let roots = [repo.path]
        XCTAssertEqual(CommitLog.times(roots: roots, since: now.addingTimeInterval(-365 * 86_400), now: now).count, 2)

        // A commit made after the read: a reused count doesn't see it, so
        // seeing only the two old ones shows git was not asked again.
        try commit(daysAgo: 0.01, now: now)
        let recent = CommitLog.times(roots: roots, since: now.addingTimeInterval(-120 * 86_400), now: now.addingTimeInterval(60))
        XCTAssertEqual(recent.count, 1, "the 120 days cut from the year's read")

        // Ten minutes on, git is asked again.
        let later = CommitLog.times(roots: roots, since: now.addingTimeInterval(-120 * 86_400),
                                    now: now.addingTimeInterval(CommitLog.reuse + 1))
        XCTAssertEqual(later.count, 2)
    }
}
