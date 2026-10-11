import Darwin
import Foundation
import LidEffortCore

/// One run of an outside tool, as pillr asks for it: an absolute path and
/// its arguments as a list. Never a shell: the reply's text is an argument
/// or the tool's stdin, and nothing between pillr and the tool reads it.
struct HostCommand: Equatable, Sendable {
    let tool: String
    let arguments: [String]
    /// Added to pillr's own environment for this run only.
    var environment: [String: String] = [:]
    /// Written to the tool's stdin, then closed. Nil: stdin is empty.
    var input: String? = nil
    var timeout: TimeInterval = 3

    struct Result: Equatable, Sendable {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs a command. Nil when it could not be started or ran past its
    /// timeout (and was ended).
    typealias Runner = @Sendable (HostCommand) -> Result?

    static let live: Runner = { command in command.run() }

    func run() -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, ours in ours }
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read and write off this thread: a tool that answers a lot (a
        // screen's worth) or reads slowly must not wedge the pipe.
        let collected = Box()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if let inPipe, let input {
            let data = Data(input.utf8)
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        _ = drained.wait(timeout: .now() + 1)
        return Result(status: process.terminationStatus, output: String(decoding: collected.data, as: UTF8.self))
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}

/// Finding the outside tools pillr talks to, and only trusting a binary that
/// is what it looks like: an absolute path to a regular executable file that
/// nobody but its owner can rewrite, owned by you or by root.
enum HostTools {
    /// Where package managers put command-line tools on a Mac: pillr runs
    /// with launchd's PATH, which has none of them.
    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                "/run/current-system/sw/bin", home + "/.nix-profile/bin", home + "/.local/bin", "/usr/bin"]
    }

    /// The first safe candidate: the preferred paths (a running server's own
    /// binary, an app bundle's), then `name` in the usual places.
    static func resolve(_ name: String, preferring preferred: [String] = [],
                        isSafe: (String) -> Bool = HostTools.isSafeExecutable) -> String? {
        let candidates = preferred + searchDirectories.map { $0 + "/" + name }
        return candidates.first { isSafe($0) }
    }

    static func isSafeExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(resolved, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        guard info.st_uid == 0 || info.st_uid == getuid() else { return false }
        return access(resolved, X_OK) == 0
    }

    /// A binary inside an app bundle, when the bundle has it.
    static func inBundle(_ bundleURL: URL?, _ relative: String) -> String? {
        guard let bundleURL else { return nil }
        return bundleURL.appendingPathComponent(relative).path
    }
}

/// What pillr can learn about a process from the kernel, injectable so
/// the matching can be tested against made-up process trees.
struct ProcessFacts: Sendable {
    /// The process and its parents, nearest first.
    var ancestry: @Sendable (pid_t) -> [pid_t]
    /// Its argument and environment strings (`KEY=VALUE` among them).
    var environment: @Sendable (pid_t) -> [String]
    /// The path of the binary it runs.
    var executablePath: @Sendable (pid_t) -> String?
    /// Its controlling terminal as ps names it (`ttys014`).
    var tty: @Sendable (pid_t) -> String?

    static let live = ProcessFacts(
        ancestry: { SessionFocus.ancestry(of: $0, limit: 12) },
        environment: { TerminalTabFocus.environment(of: $0) },
        executablePath: { ProcessFacts.executablePath(of: $0) },
        tty: { SessionFocus.tty(of: $0) }
    )

    /// A variable as the process sees it, or as the nearest parent that
    /// still has it does: wrappers sometimes scrub what the shell above
    /// them was given. With the pid it was read from.
    func inherited(_ key: String, from pid: pid_t) -> (value: String, pid: pid_t)? {
        let prefix = key + "="
        for candidate in ancestry(pid) {
            for entry in environment(candidate) where entry.hasPrefix(prefix) {
                let value = String(entry.dropFirst(prefix.count))
                if !value.isEmpty { return (value, candidate) }
            }
        }
        return nil
    }

    /// The nearest parent whose binary is named `name` (`tmux`, `zellij`).
    func ancestor(named name: String, of pid: pid_t) -> (pid: pid_t, path: String)? {
        for candidate in ancestry(pid).dropFirst() {
            guard let path = executablePath(candidate) else { continue }
            if (path as NSString).lastPathComponent == name { return (candidate, path) }
        }
        return nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Writing one line into a pane through a tool that can read the pane's
/// screen and type into it: tmux, Zellij, kitty, WezTerm. The same rule as
/// Terminal.app and iTerm2: the screen is read first, and the line goes in
/// only at an idle prompt, or over a draft the agent can stash itself.
enum PaneWriter {
    enum Key: Equatable, Sendable {
        case enter
        case escape
        /// A control character: Claude Code's Ctrl+S stash is `\u{13}`.
        case control(Character)
    }

    enum Outcome: Equatable, Sendable {
        case sent
        /// A turn running, a menu open, or someone's draft with no stash.
        case busy
        /// The pane is gone.
        case notFound
        /// The screen could not be read, so nothing was typed.
        case unreadable
        /// The tool refused to type, or failed halfway.
        case refused
    }

    struct IO: Sendable {
        /// The visible screen; nil when it could not be read.
        let read: @Sendable () -> String?
        /// Types text as typed, no Return.
        let type: @Sendable (String) -> Bool
        let press: @Sendable (Key) -> Bool
    }

    /// `pause` sits between the text and Return: an agent's TUI takes text
    /// that arrives at once with a Return in it as a paste, and keeps the
    /// Return in the box instead of sending.
    static func write(_ line: String, stashKey: Character?, io: IO,
                      pause: @Sendable () -> Void = { Thread.sleep(forTimeInterval: 0.15) }) -> Outcome {
        guard let screen = io.read() else { return .unreadable }
        switch PromptIdleDetector.state(screenText: screen) {
        case .idle: break
        case .draft:
            guard let stashKey else { return .busy }
            guard io.press(.control(stashKey)) else { return .refused }
            pause()
        case .busy: return .busy
        }
        guard io.type(line) else { return .refused }
        pause()
        return io.press(.enter) ? .sent : .refused
    }

    /// The byte a key is, for tools that take raw bytes.
    static func byte(_ key: Key) -> UInt8 {
        switch key {
        case .enter: return 13
        case .escape: return 27
        case .control(let character): return character.asciiValue ?? 19
        }
    }
}

