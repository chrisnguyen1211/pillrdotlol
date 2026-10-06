import Darwin
import Foundation

/// Whether a Claude Code process still has work running in the background.
///
/// Claude Code runs each Bash command in a shell of its own, a child of the
/// session's process; a foreground command's shell is gone when it returns.
/// A shell still alive while the session says it is idle is a background
/// command — a server, a watcher, a long job — that will wake the session
/// again when it finishes. The turn ended; the work did not.
enum BackgroundShells {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish"]

    /// Shells running under `pid`, from the kernel's own list of its children.
    static func count(under pid: pid_t) -> Int {
        var children = [pid_t](repeating: 0, count: 256)
        let found = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return 0 }
        // The call answers in PIDs on current macOS (bytes on old ones): never read past the buffer.
        let total = min(Int(found), children.count)
        return children.prefix(total).filter { child in
            guard child > 0 else { return false }
            var name = [CChar](repeating: 0, count: 64)
            proc_name(child, &name, UInt32(name.count))
            return shells.contains(String(cString: name))
        }.count
    }
}
