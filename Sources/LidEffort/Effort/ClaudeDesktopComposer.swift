import AppKit
import ApplicationServices
import OSLog

/// Puts a slash command into Claude Desktop's composer and sends it, so a session that
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
///     defaults write lol.pillr.app effort.axInject -bool true
enum ClaudeDesktopComposer {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let defaultsKey = "effort.axInject"
    private static let log = Logger(subsystem: "lol.pillr.app", category: "effort")

    static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
    }

    /// What became of a command: sent, or the one reason it was not — the
    /// card says which, since "nothing happened" in an app you are looking
    /// at reads as a bug.
    enum Outcome: Equatable {
        case sent
        case notFront
        /// pillr is not allowed to use Accessibility.
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
        /// The window is showing a different session than the one meant.
        case otherSession
    }

    /// Types the command and presses Return, or says why it did not.
    @MainActor
    static func type(command: String, askForTrust: Bool = true) -> Outcome {
        guard EffortInjector.isEffortCommand(command) else {
            log.error("composer: refused \(command, privacy: .public)")
            return .notSent
        }
        return deliver(command, askForTrust: askForTrust)
    }

    /// A message you wrote in pillr, sent into the Claude app session it is
    /// for — only while the window is showing that very session, into an
    /// empty box, and sent only once the box reads back exactly the message.
    @MainActor
    static func send(message: String, toHostSession id: String) -> Outcome {
        guard let line = SessionCommander.oneLine(message) else { return .notSent }
        guard view() == .session(id) else {
            log.notice("composer: another session is on screen")
            return .otherSession
        }
        // Just brought to the front from pillr's panel: the window may still
        // be redrawing its message box. Once more, from a fresh look, if the
        // first try could not put the message in.
        let first = deliver(line, askForTrust: false)
        guard first == .notSent else { return first }
        usleep(500_000)
        log.notice("composer: second try with a fresh message box")
        return deliver(line, askForTrust: false)
    }

    @MainActor
    private static func deliver(_ command: String, askForTrust: Bool) -> Outcome {
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

        let axApp = prepare(pid: app.processIdentifier)

        // The composer, focused. When the focus is elsewhere in the window
        // — the transcript, a button — find the composer and put the focus
        // there, rather than asking for a click on it before every gesture.
        var focused = element(axApp, kAXFocusedUIElementAttribute)
        if focused.map({ !isComposer($0) }) ?? true {
            // Electron builds the tree a moment after it is first asked
            // for: on the first gesture after either app starts, the window
            // is still empty. Look again for up to a second before saying
            // there is no message box — there plainly is one on screen.
            var found: AXUIElement?
            for attempt in 0...Self.treeAttempts {
                if attempt > 0 { usleep(Self.treeWait) }
                if let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute),
                   let composer = findComposer(in: window) {
                    found = composer
                    break
                }
            }
            guard let composer = found else {
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

        // Put the command in, then read it back: Return is pressed only on
        // the exact command. Keystrokes are not used for the text — an input
        // method rewrites them (Telex makes `/effort low` into `/efort lơ`),
        // and a mangled command was sent as a message.
        guard insert(command, into: focused) else {
            clear(focused, ifItHolds: command)
            log.notice("composer: \(command.count, privacy: .public) chars could not be put in the box intact")
            return .notSent
        }
        // Typing `/` opens the command menu, where a first Return can go to
        // the menu instead. So: press Return, and look — until the box is
        // empty.
        for attempt in 1...Self.returnAttempts {
            post(key: 36)   // Return
            // Sent is the box emptying; give it up to a second to show it.
            var now = value(of: focused)
            for _ in 0..<Self.readBackTries where !now.isEmpty {
                usleep(Self.readBackWait)
                now = value(of: focused)
            }
            if now.isEmpty {
                log.notice("composer: sent \(command.count, privacy: .public) chars (return \(attempt, privacy: .public))")
                return .sent
            }
            // Something other than what we put there is in the box now: the
            // user is typing. Stop, and leave it alone.
            guard Self.isOurs(now, command) || now.hasPrefix("/") else {
                log.notice("composer: the composer changed under us; stopping")
                return .userTyping
            }
            // The menu took the Return and rewrote the command — `/effort `
            // without its level, say. Put the whole command back, checked,
            // before the next Return, so the level sent is the one meant.
            if !Self.holdsExactly(now, command) {
                deleteAll(focused)
                guard insert(command, into: focused) else { break }
            }
        }
        // Not sent: take back only what we put there, so no stray command is left.
        clear(focused, ifItHolds: command)
        log.notice("composer: \(command.count, privacy: .public) chars typed but not sent")
        return .notSent
    }

    /// The box holds the command and nothing else — what Return may send.
    static func holdsExactly(_ value: String, _ command: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == command
    }

    private static func value(of element: AXUIElement) -> String {
        (string(element, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command into the empty box, without keystrokes: first through
    /// Accessibility, inserting it where the caret is; if the box does not
    /// take that, pasted — the clipboard put back as it was. True only when
    /// the box then reads back exactly the command.
    private static func insert(_ command: String, into element: AXUIElement) -> Bool {
        let set = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, command as CFString)
        defer { log.notice("composer: insert \(Self.describe(value(of: element), command), privacy: .public); AX set \(set.rawValue, privacy: .public)") }
        // The box catches up a beat after it is told — longer for a message
        // than for a short command. Reading it once too early took a slow
        // insert for a failed one, pasted again, and left "hihi".
        if waitUntil(element, holds: command) { return true }
        // Whatever is in there now came from us — the box was empty a moment
        // ago — unless it is something else entirely: then someone is typing.
        let now = value(of: element)
        if !now.isEmpty {
            guard isOurs(now, command) else { return false }
            deleteAll(element)
        }
        paste(command)
        return waitUntil(element, holds: command)
    }

    /// Reads the box until it holds exactly `command`, for up to a second.
    private static func waitUntil(_ element: AXUIElement, holds command: String) -> Bool {
        for _ in 0..<Self.readBackTries {
            usleep(Self.readBackWait)
            if holdsExactly(value(of: element), command) { return true }
        }
        return false
    }

    static let readBackTries = 7
    static let readBackWait: useconds_t = 150_000

    /// What the box holds next to what was meant, without its text:
    /// lengths, whether it contains the message, and the code points of
    /// anything extra — what a log may say about someone's message.
    static func describe(_ value: String, _ command: String) -> String {
        var extra = value
        if let range = extra.range(of: command) { extra.removeSubrange(range) }
        let codes = extra.unicodeScalars.prefix(8).map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
        return "len \(value.count)/\(command.count), contains \(value.contains(command)), extra [\(codes)]"
    }

    /// Text pillr put there: the command, part of it, or it twice over.
    static func isOurs(_ text: String, _ command: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return command.hasPrefix(text) || text.hasPrefix(command) || text == command + command
    }

    /// ⌘V with the command on the clipboard, then the clipboard as it was.
    /// Marked transient and concealed, the nspasteboard.org convention, so
    /// clipboard managers leave it out of their history.
    private static func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        post(key: 9, flags: .maskCommand)   // ⌘V
        usleep(Self.settle)
        board.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    /// Deletes what is in the box only when it is (part of) our command —
    /// never a draft of the person's.
    private static func clear(_ element: AXUIElement, ifItHolds command: String) {
        guard isOurs(value(of: element), command) else { return }
        deleteAll(element)
    }

    private static func deleteAll(_ element: AXUIElement) {
        for _ in 0..<(string(element, kAXValueAttribute) ?? "").count { post(key: 51) }   // Delete
        usleep(Self.settle)
    }

    /// What Claude Desktop's window is showing.
    enum View: Equatable {
        /// The window could not be read: not in front, not trusted.
        case unknown
        /// Something other than a Claude Code session — a chat, settings.
        case noSession
        /// The Claude Code session with this id (`local_…`).
        case session(String)
    }

    /// The session on screen, read from the window rather than from
    /// Claude Desktop's records: their "last focused" time is written late,
    /// and named the session you had just left. The page holding a session
    /// has its id in its address — `claude.ai/epitaxy/local_…`.
    @MainActor
    static func view() -> View {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else { return .unknown }
        return view(of: app)
    }

    /// What a Claude app window is showing, in front or not.
    @MainActor
    static func view(of app: NSRunningApplication) -> View {
        guard AXIsProcessTrusted() else { return .unknown }
        let axApp = prepare(pid: app.processIdentifier)
        guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute) else {
            return .unknown
        }
        var stack = [window]
        var visited = 0
        var sawPage = false
        while let node = stack.popLast(), visited < 20_000 {
            visited += 1
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                sawPage = true
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &url) == .success,
                   let address = (url as? URL)?.absoluteString ?? (url as? String),
                   let id = hostSessionID(inAddress: address) {
                    return .session(id)
                }
                continue
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                stack.append(contentsOf: list)
            }
        }
        return sawPage ? .noSession : .unknown
    }

    /// `local_<uuid>` from a Claude Desktop page address, if it names one.
    static func hostSessionID(inAddress address: String) -> String? {
        guard let range = address.range(of: #"local_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
                                        options: .regularExpression) else { return nil }
        return String(address[range])
    }

    // MARK: In the background

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// A message into the session the Claude app's window is showing, with
    /// the app left where it is: the box filled through Accessibility and
    /// its own Send button pressed — no keys, no focus, nothing brought to
    /// the front. `.notSent` (the box put back as it was) when the window
    /// will not take it that way; the caller then brings it forward.
    @MainActor
    static func sendInBackground(message: String, toHostSession id: String) -> Outcome {
        guard let line = SessionCommander.oneLine(message), let app = runningApp else { return .notSent }
        guard AXIsProcessTrusted() else { return .notTrusted }
        let shown = view(of: app)
        guard shown == .session(id) else {
            log.notice("composer (background): window shows \(String(describing: shown), privacy: .public)")
            return .otherSession
        }
        guard let composer = composer(of: app) else {
            log.notice("composer (background): no message box")
            return .noComposer
        }
        guard value(of: composer).isEmpty else {
            log.notice("composer (background): the box has a draft")
            return .draft
        }
        AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, line as CFString)
        guard waitUntil(composer, holds: line) else {
            log.notice("composer (background): \(Self.describe(value(of: composer), line), privacy: .public)")
            clear(composer, ifItHolds: line)
            return .notSent
        }
        guard let send = button(near: composer, matching: Self.sendWords) else {
            log.notice("composer (background): no Send button")
            clear(composer, ifItHolds: line)
            return .notSent
        }
        AXUIElementPerformAction(send, kAXPressAction as CFString)
        var now = value(of: composer)
        for _ in 0..<Self.readBackTries where !now.isEmpty {
            usleep(Self.readBackWait)
            now = value(of: composer)
        }
        if now.isEmpty {
            log.notice("composer (background): sent \(line.count, privacy: .public) chars")
            return .sent
        }
        clear(composer, ifItHolds: line)
        return .notSent
    }

    /// Presses the Claude app's own Stop for the session its window shows,
    /// in the background. False when that is not the session, or there is
    /// no Stop to press (it is not working).
    @MainActor
    static func stopInBackground(hostSession id: String) -> Bool {
        guard let app = runningApp, AXIsProcessTrusted(), view(of: app) == .session(id),
              let composer = composer(of: app),
              let stop = button(near: composer, matching: Self.stopWords) else { return false }
        let pressed = AXUIElementPerformAction(stop, kAXPressAction as CFString) == .success
        log.notice("composer: Stop pressed \(pressed, privacy: .public)")
        return pressed
    }

    @MainActor
    private static func composer(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = prepare(pid: app.processIdentifier)
        guard let window = element(axApp, kAXMainWindowAttribute) ?? element(axApp, kAXFocusedWindowAttribute) else { return nil }
        return findComposer(in: window)
    }

    /// Send and Stop as the Claude app labels them in its languages: the
    /// labels follow the app's language, not the Mac's.
    static let sendWords = ["send", "gửi", "envoyer", "senden", "enviar", "invia", "verzenden", "wyślij", "отправить",
                            "送信", "보내기", "发送", "發送", "kirim", "भेजें", "gönder"]
    static let stopWords = ["stop", "dừng", "arrêter", "stopp", "anhalten", "detener", "parar", "interrompi", "ferma",
                            "zatrzymaj", "остановить", "停止", "중지", "berhenti", "रोकें", "durdur"]

    /// A button in the message box's neighbourhood whose label contains one
    /// of `words` — "Send message", "Stop".
    private static func button(near composer: AXUIElement, matching words: [String]) -> AXUIElement? {
        var box = composer
        for _ in 0..<6 { if let parent = element(box, kAXParentAttribute) { box = parent } }
        var stack = [box]
        var visited = 0
        while let node = stack.popLast(), visited < 3000 {
            visited += 1
            if string(node, kAXRoleAttribute) == kAXButtonRole {
                let label = ((string(node, kAXDescriptionAttribute) ?? "") + " " + (string(node, kAXTitleAttribute) ?? "")).lowercased()
                if words.contains(where: { label.contains($0) }) { return node }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] { stack.append(contentsOf: list) }
        }
        return nil
    }

    /// Asks Claude Desktop for its accessibility tree. Electron builds one
    /// only when told an assistive client wants it, and builds it a beat
    /// later — so this is also called as Claude Desktop comes to the front,
    /// well before a gesture needs the tree.
    @discardableResult
    static func prepare(pid: pid_t) -> AXUIElement {
        let axApp = AXUIElementCreateApplication(pid)
        // A busy Claude app answers late; never wait on it for long.
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return axApp
    }

    /// Waiting for a tree that is still being built: 4 × 250 ms.
    static let treeAttempts = 4
    static let treeWait: useconds_t = 250_000

    /// How long Claude Desktop's composer takes to catch up with the keys.
    static let settle: useconds_t = 220_000
    static let returnAttempts = 3

    /// The message box, and only it. Claude Desktop's window has other
    /// inputs — the browser pane's URL field, the terminal pane's input —
    /// and a Return in the terminal one would run the command as shell.
    /// The composer is the text *area* described "Prompt" in English; in
    /// another language the description is translated ("Câu lệnh" in
    /// Vietnamese), so it is known by its editor instead, ProseMirror,
    /// which no other input in the window is. Anything of xterm's is never
    /// the composer, whatever it is called.
    static let composerDescription = "Prompt"
    static let composerEditorClass = "ProseMirror"

    /// Whether a text input, by what it says of itself, is the composer:
    /// the strict match, or, with nothing said at all, the old fallback.
    static func isComposer(role: String?, description: String?, classes: [String]) -> Bool {
        guard role == kAXTextAreaRole else { return false }
        guard !classes.contains(where: { $0.lowercased().contains("xterm") }) else { return false }
        if isComposerExactly(role: role, description: description, classes: classes) { return true }
        return (description ?? "").isEmpty && classes.isEmpty
    }

    /// The composer for certain: "Prompt", or the ProseMirror editor.
    static func isComposerExactly(role: String?, description: String?, classes: [String]) -> Bool {
        guard role == kAXTextAreaRole, !classes.contains(where: { $0.lowercased().contains("xterm") }) else { return false }
        return description == composerDescription || classes.contains(composerEditorClass)
    }

    private static func classes(_ element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private static func isComposer(_ element: AXUIElement) -> Bool {
        isComposer(role: string(element, kAXRoleAttribute), description: string(element, kAXDescriptionAttribute),
                   classes: classes(element))
    }

    /// The composer, breadth-first: the text area described "Prompt" or
    /// made by ProseMirror if there is one, else a text area that says
    /// nothing of itself.
    private static func findComposer(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var fallback: AXUIElement?
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let node = queue.removeFirst()
            visited += 1
            let role = string(node, kAXRoleAttribute)
            if role == kAXTextAreaRole {
                let description = string(node, kAXDescriptionAttribute)
                let classList = classes(node)
                if isComposerExactly(role: role, description: description, classes: classList) { return node }
                if isComposer(role: role, description: description, classes: classList) { fallback = node }
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

    private static func post(key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
