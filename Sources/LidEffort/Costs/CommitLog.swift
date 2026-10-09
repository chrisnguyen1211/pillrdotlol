import Foundation

/// Your commits, day by day, in the repositories your agents worked in —
/// for the dashboard's grid of shipped work.
///
/// Read from git on this Mac: each repository's own `user.email` is who
/// "you" are there, and a commit reached from more than one branch or
/// clone counts once. Nothing is asked of GitHub.
enum CommitLog {
    /// How long a count is reused: git is not asked on every redraw.
    static let reuse: TimeInterval = 10 * 60
    private static let lock = NSLock()
    private static var held: (key: String, at: Date, days: [Date: Int])?

    /// The repositories the folders are in, each once.
    static func roots(of folders: [String], limit: Int = 60) -> [String] {
        var roots: [String] = []
        var seen: Set<String> = []
        for folder in Set(folders).sorted() where FileManager.default.fileExists(atPath: folder) {
            guard let root = git(["rev-parse", "--show-toplevel"], in: folder)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty,
                  seen.insert(root).inserted else { continue }
            roots.append(root)
            if roots.count >= limit { break }
        }
        return roots
    }

    /// Commits per local day since a moment, by each repository's own user.
    static func days(roots: [String], since: Date, calendar: Calendar = .current, now: Date = Date()) -> [Date: Int] {
        let key = roots.joined(separator: "|") + "@\(Int(calendar.startOfDay(for: since).timeIntervalSince1970))"
        if let held = lock.withLock({ held }), held.key == key, now.timeIntervalSince(held.at) < reuse { return held.days }
        var seen: Set<String> = []
        var days: [Date: Int] = [:]
        for root in roots {
            guard let email = git(["config", "user.email"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty,
                  let log = git(["log", "--all", "--no-merges", "--author=\(email)",
                                 "--since=\(Int(since.timeIntervalSince1970))", "--format=%H %ct"], in: root)
            else { continue }
            for line in log.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let seconds = TimeInterval(parts[1]), seen.insert(String(parts[0])).inserted else { continue }
                days[calendar.startOfDay(for: Date(timeIntervalSince1970: seconds)), default: 0] += 1
            }
        }
        lock.withLock { held = (key, now, days) }
        return days
    }

    /// A git command in a folder, or nil when it fails or takes too long.
    static func git(_ arguments: [String], in folder: String, timeout: TimeInterval = 4) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read off to the side, so a git that hangs is stopped, not waited on.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        let data = box.data
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
