import AppKit
import Foundation

/// Selects the exact tab a session is running in, where the terminal offers
/// a way to name it.
///
/// There is no general mechanism — every terminal is its own answer, and each
/// costs a one-time Automation consent for AppleScript:
///
/// * **cmux** matches a terminal panel by its *working directory* — the
///   session process's own cwd. Its socket CLI would be nicer (it names tabs
///   by tty), but the server refuses any client that is not itself inside a
///   cmux terminal session (manaflow-ai/cmux#3089) — and spyx never is.
/// * **Terminal.app** and **iTerm2** match a tab by tty.
/// * Everything else publishes nothing (Warp, Ghostty), and the caller falls
///   back to raising the app — the honest answer rather than a silent no-op.
enum TerminalTabFocus {
    /// Best effort: true when a tab was selected. Anything going wrong —
    /// no tty, no cwd, no match, a refused prompt — is false, and the caller
    /// still raises the app.
    static func selectTab(bundleID: String?, pid: pid_t, tty: String?, cwd: String?) -> Bool {
        switch bundleID {
        case "com.cmuxterm.app":
            // The exact surface, named by the id the session's own process
            // tree carries in its environment; cwd matching is the fallback
            // for a tree that publishes nothing readable.
            if let surface = cmuxSurfaceID(of: pid) {
                return selectCmuxTerminal(matching: "id of term is \"\(appleScriptEscaped(surface))\"")
            }
            guard let cwd else { return false }
            let condition = cmuxPathCandidates(cwd)
                .map { "working directory of term is \"\(appleScriptEscaped($0))\"" }
                .joined(separator: " or ")
            return selectCmuxTerminal(matching: condition)
        case "com.apple.Terminal":
            guard let tty else { return false }
            return runOsascript("""
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "/dev/\(appleScriptEscaped(tty))" then
                        set selected of t to true
                        set index of w to 1
                        return "found"
                      end if
                    end repeat
                  end repeat
                end tell
                """)
        case "com.googlecode.iterm2":
            guard let tty else { return false }
            return runOsascript("""
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "/dev/\(appleScriptEscaped(tty))" then
                          select s
                          select t
                          select w
                          return "found"
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """)
        default:
            return false
        }
    }

    // MARK: - cmux

    /// The scripting dictionary's `terminal` panels carry an `id`, a
    /// `working directory` and a title but no tty; `select tab` picks the
    /// workspace, and `focus` plus `activate window` finish the job.
    private static func selectCmuxTerminal(matching condition: String) -> Bool {
        return runOsascript("""
            tell application "cmux"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with term in terminals of t
                    if \(condition) then
                      select tab t
                      focus term
                      activate window w
                      return "found"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """)
    }

    /// The session's own process tree knows exactly which surface it lives
    /// in: cmux exports CMUX_SURFACE_ID into every terminal it spawns, and
    /// the agent inherits it. Read up the ancestry until it turns up —
    /// wrappers occasionally scrub it from the agent itself, but the shell
    /// or launcher above still has it.
    static func cmuxSurfaceID(of pid: pid_t) -> String? {
        for candidate in SessionFocus.ancestry(of: pid) {
            for entry in environment(of: candidate) {
                guard entry.hasPrefix("CMUX_SURFACE_ID=") else { continue }
                let value = String(entry.dropFirst("CMUX_SURFACE_ID=".count))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// A process's full argument/environment block as NUL-separated strings.
    /// Same-user reads only — which is all a session's own tree ever needs.
    static func environment(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        var strings: [String] = []
        buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<Int32>.size   // past argc
            while offset < raw.count {
                guard let nul = raw[offset...].firstIndex(of: 0) else { break }
                // Empty runs separate the blocks (path, argv, env) — skip
                // them rather than stop at the first one.
                if nul == offset {
                    offset += 1
                    continue
                }
                if let string = String(bytes: raw[offset..<nul], encoding: .utf8) {
                    strings.append(string)
                }
                offset = nul + 1
            }
        }
        return strings
    }

    /// The same directory, spelled the ways it might appear: the kernel's
    /// report can carry a `/private` prefix the terminal's title never shows,
    /// and symlinks along the path resolve differently on either side.
    static func cmuxPathCandidates(_ cwd: String) -> [String] {
        var candidates = [cwd]
        let resolved = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        if resolved != cwd { candidates.append(resolved) }
        for path in [cwd, resolved] {
            if path.hasPrefix("/private/") {
                candidates.append(String(path.dropFirst("/private".count)))
            } else {
                candidates.append("/private" + path)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// An AppleScript string literal's two dangerous characters, escaped.
    static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Running the tools

    /// A short subprocess with its stdout collected concurrently, so a large
    /// reply cannot fill the pipe and wedge the writer. Nil on any failure.
    static func run(_ launchPath: String, _ arguments: [String],
                    timeout: TimeInterval = 3) -> String? {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            Log.sessions.notice("tab focus: cannot launch \(launchPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let collected = Mutex(Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.withLock { $0 = pipe.fileHandleForReading.readDataToEndOfFile() }
            drained.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        // Process exit and pipe drainage are not the same event: a fast
        // command is often reaped while the reader thread is still unscheduled,
        // and reading before it lands parses an empty string as "no match".
        _ = drained.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            Log.sessions.notice("tab focus: \(arguments.first ?? "", privacy: .public) exited \(process.terminationStatus, privacy: .public): \(stderr.prefix(300), privacy: .public)")
            return nil
        }
        return collected.withLock { String(data: $0, encoding: .utf8) }
    }

    private static func runOsascript(_ script: String) -> Bool {
        run("/usr/bin/osascript", ["-e", script]).map { $0.contains("found") } ?? false
    }

    /// `NSLock` boxed for the reader thread's hand-off.
    private final class Mutex<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()
        init(_ value: Value) { self.value = value }
        func withLock<T>(_ body: (inout Value) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }
}
