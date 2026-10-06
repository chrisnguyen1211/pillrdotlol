import Foundation

/// What is changed in a session's working tree, in a few characters —
/// "3 files · +42 −7" — for the card that says the session finished.
/// Everything uncommitted, not only this turn's: git has no way to tell
/// them apart, and the tree is what you are about to review.
enum GitChanges {
    /// Nil when the folder is not a repository, nothing is changed, or git
    /// takes longer than `timeout` (a huge repository is not worth a stall).
    static func summary(cwd: String, timeout: TimeInterval = 2) -> String? {
        guard let stat = run(["diff", "--shortstat", "HEAD"], cwd: cwd, timeout: timeout),
              let status = run(["status", "--porcelain=v1", "--untracked-files=all"], cwd: cwd, timeout: timeout)
        else { return nil }
        let untracked = status.split(separator: "\n").filter { $0.hasPrefix("??") }.count
        return summary(shortstat: stat, untracked: untracked)
    }

    /// " 3 files changed, 42 insertions(+), 7 deletions(-)" and the count of
    /// new, untracked files → "3 files · +42 −7 · 2 new".
    static func summary(shortstat: String, untracked: Int) -> String? {
        func number(before word: String) -> Int {
            guard let range = shortstat.range(of: #"(\d+) \#(word)"#, options: .regularExpression) else { return 0 }
            return Int(shortstat[range].split(separator: " ").first ?? "") ?? 0
        }
        let files = number(before: "file")
        let added = number(before: "insertion")
        let removed = number(before: "deletion")
        guard files > 0 || untracked > 0 else { return nil }
        var parts: [String] = []
        if files > 0 {
            parts.append(files == 1 ? L10n.t("1 file") : L10n.t("\(files) files"))
            parts.append("+\(added) −\(removed)")
        }
        if untracked > 0 { parts.append(L10n.t("\(untracked) new")) }
        return parts.joined(separator: " · ")
    }

    private static func run(_ arguments: [String], cwd: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + arguments
        // Never take the index lock the agent itself may need.
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
