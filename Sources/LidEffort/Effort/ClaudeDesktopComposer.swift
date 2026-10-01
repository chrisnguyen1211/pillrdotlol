import AppKit
import ApplicationServices
import OSLog

/// Types a slash command into Claude Desktop's composer, so a session that
/// has no terminal to type into can still take a live `/effort`.
///
/// On unless switched off in Settings: Claude Desktop handles `/effort` in
/// its own composer — the level changes and nothing is sent to Claude —
/// which is the only way into a session whose stdin Claude Desktop holds.
/// Claude Desktop is an Electron app, whose
/// accessibility tree exists only once something asks for it, and whose
/// composer is a text area we have to find rather than a tty we can name.
/// Every guard here is a way of *not* typing: the app must be in front,
/// this process must be trusted for Accessibility, the focused element
/// must be a text area, and it must be empty. Enable with
///
///     defaults write lol.spyx.app effort.axInject -bool true
enum ClaudeDesktopComposer {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let defaultsKey = "effort.axInject"
    private static let log = Logger(subsystem: "lol.spyx.app", category: "effort")

    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
    }

    /// What became of a command: sent, or the one reason it was not — the
    /// card says which, since "nothing happened" in an app you are looking
    /// at reads as a bug.
    enum Outcome: Equatable {
        case sent
        case notFront
        /// spyx is not allowed to use Accessibility.
        case notTrusted
        /// No message box in the window: a settings page, a chat that is
        /// not a Code session.
        case noComposer
        /// The box has text in it — a draft that is not ours to send.
        case draft
        /// The person started typing while the command was going in.
        case userTyping
        /// Typed, Return pressed, and the box never emptied.
        case notSent
    }

    /// Types the command and presses Return, or says why it did not.
    @MainActor
    static func type(command: String, askForTrust: Bool = true) -> Outcome {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleID else {
            log.notice("composer: Claude Desktop is not in front")
            return .notFront
        }
        // Asks the system to show the Accessibility prompt the first time;
        // after that it simply reports.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: askForTrust] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            log.notice("composer: not trusted for Accessibility")
            return .notTrusted
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Electron builds its tree only when told an assistive client wants it.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        // The composer, focused. When the focus is elsewhere in the window
        // — the transcript, a button — find the composer and put the focus
        // there, rather than asking for a click on it before every gesture.
        var focused = element(axApp, kAXFocusedUIElementAttribute)
        if focused.map({ !isComposer($0) }) ?? true {
            guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute),
                  let composer = findComposer(in: window) else {
                log.notice("composer: no message box found in Claude Desktop's window")
                return .noComposer
            }
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(Self.settle)
            focused = composer
        }
        guard let focused else {
            log.notice("composer: nothing focused")
            return .noComposer
        }
        let current = (string(focused, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty else {
            log.notice("composer: the composer is not empty")
            return .draft
        }

        for character in command.utf16 { post(character: character) }
        // Electron updates the composer a beat after the keys land; a
        // Return in the same instant arrived before the text did and was
        // dropped, and the command sat in the box unsent. Typing `/` also
        // opens the command menu, where a first Return can go to the menu
        // instead. So: wait, press Return, and look — until the box is empty.
        usleep(Self.settle)
        for attempt in 1...Self.returnAttempts {
            post(key: 36)   // Return
            usleep(Self.settle)
            let now = (string(focused, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if now.isEmpty {
                log.notice("composer: sent \(command, privacy: .public) (return \(attempt, privacy: .public))")
                return .sent
            }
            // Something other than our command is in the box now: the user
            // is typing. Stop, and leave it alone.
            guard now.hasPrefix("/") else {
                log.notice("composer: the composer changed under us; stopping")
                return .userTyping
            }
            // The menu took the Return and rewrote the command — `/effort `
            // without its level, say. Put the whole command back before the
            // next Return, so the level sent is the one meant.
            if now != command {
                for _ in 0..<(string(focused, kAXValueAttribute) ?? "").count { post(key: 51) }   // Delete
                for character in command.utf16 { post(character: character) }
                usleep(Self.settle)
            }
        }
        // Not sent: take back only what we typed, so no stray command is left.
        let left = (string(focused, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if left.hasPrefix("/"), command.hasPrefix(left) || left.hasPrefix(command) {
            for _ in 0..<(string(focused, kAXValueAttribute) ?? "").count { post(key: 51) }   // Delete
        }
        log.notice("composer: \(command, privacy: .public) was typed but not sent")
        return .notSent
    }

    /// How long Claude Desktop's composer takes to catch up with the keys.
    static let settle: useconds_t = 220_000
    static let returnAttempts = 3

    /// The message box, and only it. Claude Desktop's window has other
    /// inputs — the browser pane's URL field, the terminal pane's input,
    /// both text *fields* — and a Return in the terminal one would run the
    /// command as shell. The composer is the text *area* described "Prompt".
    static let composerDescription = "Prompt"

    private static func isComposer(_ element: AXUIElement) -> Bool {
        guard string(element, kAXRoleAttribute) == kAXTextAreaRole else { return false }
        let description = string(element, kAXDescriptionAttribute) ?? ""
        return description.isEmpty || description == composerDescription
    }

    /// The composer, breadth-first: the text area described "Prompt" if
    /// there is one, else the only kind of text area Claude Desktop has.
    private static func findComposer(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var fallback: AXUIElement?
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let node = queue.removeFirst()
            visited += 1
            if string(node, kAXRoleAttribute) == kAXTextAreaRole {
                if string(node, kAXDescriptionAttribute) == composerDescription { return node }
                if isComposer(node) { fallback = node }
                continue
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return fallback
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func post(character: UInt16) {
        var unit = character
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func post(key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}
