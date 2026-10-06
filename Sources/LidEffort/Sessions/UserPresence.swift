import CoreGraphics
import Foundation

/// Whether someone is at the Mac: the screen unlocked and a key, click or
/// move within the last stretch. What decides that a question can be left
/// to the session's own dialog — someone looking at that session — only
/// counts while they are actually there; a terminal left in front when
/// they walked away is not anyone looking at it.
enum UserPresence {
    /// Input more recent than this is someone here.
    static let activeWithin: TimeInterval = 90

    static var secondsIdle: TimeInterval {
        // Any input event: keys, clicks, moves, scrolls.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    static var isPresent: Bool { isPresent(idle: secondsIdle, locked: screenLocked) }

    static func isPresent(idle: TimeInterval, locked: Bool) -> Bool {
        !locked && idle < activeWithin
    }
}
