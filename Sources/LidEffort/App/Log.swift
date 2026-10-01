import os

/// An agent app has no window to print into, so anything worth diagnosing has
/// to go somewhere you can read it:
///
///     log stream --predicate 'subsystem == "lol.spyx.app"' --level debug
enum Log {
    static let usage = Logger(subsystem: "lol.spyx.app", category: "usage")
    static let sessions = Logger(subsystem: "lol.spyx.app", category: "sessions")
}
