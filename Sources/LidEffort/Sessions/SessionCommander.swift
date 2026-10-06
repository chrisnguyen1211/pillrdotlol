import AppKit
import ApplicationServices
import LidEffortCore
import OSLog

/// Talking back to a session from the notch: a reply you write, or Stop.
///
/// Each host is reached the way it can be reached *safely*. Return is only
/// pressed where spyx can confirm the text went into the right session —
/// Terminal.app (the tab is found by its tty, and the prompt must be idle),
/// the Claude app (the window must be showing that session, and the box must
/// read back the message exactly), Superset (its own host service). Anywhere
/// else the session is brought to the front with the text pasted and left
/// for you to send. Stop is Esc, pressed only once the session's own tab is
/// confirmed in front.
@MainActor
enum SessionCommander {
    enum Reach: Equatable {
        /// Typed in the background into its Terminal.app tab.
        case terminal(tty: String)
        /// Written in the background into its iTerm2 session.
        case iterm(tty: String)
        /// A Superset pane on the new terminal stack.
        case superset
        /// A Claude app session.
        case claudeApp(hostSessionID: String)
        /// Brought to the front with the text pasted, unsent.
        case pasteInto(app: String)
        case none
    }

    enum ReplyOutcome: Equatable {
        case sent
        /// The prompt is not idle: the session is still working.
        case busy
        /// Pasted into the app in front; Return is yours to press.
        case pasted(app: String)
        /// The app is in front but spyx could not be sure which of its tabs
        /// is the session's, so the message is on the clipboard instead.
        case copied(app: String)
        /// The Claude app is showing a different session.
        case otherSession
        /// Not sent, and why — said on the card.
        case failed(String)
    }

    private static let log = Logger(subsystem: "lol.spyx.app", category: "sessions")

    static func reach(_ session: AgentSession) -> Reach {
        guard let pid = session.processID else { return .none }
        if let cached = reaches[pid], cached.until > Date() { return cached.reach }
        let reach = computeReach(pid: pid)
        reaches[pid] = (reach, Date().addingTimeInterval(30))
        return reach
    }

    private static var reaches: [pid_t: (reach: Reach, until: Date)] = [:]

    private static func computeReach(pid: pid_t) -> Reach {
        if let place = Superset.place(of: pid), case .v2 = place.stack { return .superset }
        let app = SessionFocus.owningApp(of: pid)
        switch app?.bundleIdentifier {
        case "com.apple.Terminal":
            if let tty = SessionFocus.tty(of: pid) { return .terminal(tty: tty) }
        case "com.googlecode.iterm2":
            if let tty = SessionFocus.tty(of: pid) { return .iterm(tty: tty) }
        case ClaudeDesktopComposer.bundleID:
            if let host = SessionModels.desktop(pid: pid)?.hostSessionID, !host.isEmpty {
                return .claudeApp(hostSessionID: host)
            }
        default:
            break
        }
        if let name = app?.localizedName { return .pasteInto(app: name) }
        return .none
    }

    /// Stop is offered where the session's own tab can be put in front and
    /// confirmed: Terminal.app and iTerm2, which find a tab by its tty.
    static func canStop(_ session: AgentSession) -> Bool {
        guard session.state == .busy, let pid = session.processID else { return false }
        // The Claude app's own Stop button, pressed in the background.
        if case .claudeApp = reach(session) { return true }
        guard SessionFocus.tty(of: pid) != nil else { return false }
        let bundle = SessionFocus.owningApp(of: pid)?.bundleIdentifier
        return bundle == "com.apple.Terminal" || bundle == "com.googlecode.iterm2"
    }

    // MARK: Reply

    /// `stepAside` is called before anything is brought to the front — the
    /// reply panel must give up the keyboard then, and only then.
    static func reply(_ text: String, to session: AgentSession,
                      stepAside: () -> Void = {}) async -> ReplyOutcome {
        let outcome = await deliver(text, to: session, stepAside: stepAside)
        log.notice("reply to \(session.name, privacy: .private): \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private static func deliver(_ text: String, to session: AgentSession,
                                stepAside: () -> Void) async -> ReplyOutcome {
        guard let line = oneLine(text) else { return .failed(L10n.t("The message is empty")) }
        guard let pid = session.processID else { return .failed(L10n.t("This session has no process to write to")) }
        let reach = reach(session)
        log.notice("reply: \(String(describing: reach), privacy: .public)")
        switch reach {
        case .iterm(let tty):
            guard EffortInjector.itermAllowed else {
                return .failed(L10n.t("iTerm2 hasn't allowed spyx yet — allow it in Settings → General → Run Setup Again… → Terminals"))
            }
            return outcome(ITermWriter.write(line, tty: tty), host: "iTerm2")
        case .terminal(let tty):
            guard EffortInjector.terminalAllowed else {
                return .failed(L10n.t("Terminal hasn't allowed spyx yet — allow it in Settings → General → Run Setup Again… → Terminals"))
            }
            return outcome(EffortInjector.typeMessage(line, tty: tty), host: "Terminal")
        case .superset:
            guard let place = Superset.place(of: pid) else { return .failed(L10n.t("Superset no longer has this pane")) }
            return await Superset.send(line, to: place) == .sent ? .sent : .failed(L10n.t("Superset refused the message"))
        case .claudeApp(let host):
            // In the background first: the window stays where it is.
            let background = ClaudeDesktopComposer.sendInBackground(message: line, toHostSession: host)
            log.notice("reply: background \(String(describing: background), privacy: .public)")
            switch background {
            case .sent: return .sent
            case .otherSession: return .otherSession
            case .draft, .userTyping: return .busy
            case .notTrusted: return .failed(accessibilityOff())
            default: break
            }
            stepAside()
            guard await SessionFocus.focus(pid: pid) else { return .failed(L10n.t("The Claude app did not come forward")) }
            try? await Task.sleep(nanoseconds: 450_000_000)
            let front = ClaudeDesktopComposer.send(message: line, toHostSession: host)
            log.notice("reply: in front \(String(describing: front), privacy: .public)")
            switch front {
            case .sent: return .sent
            case .otherSession: return .otherSession
            case .draft, .userTyping: return .busy
            case .notTrusted: return .failed(accessibilityOff())
            case .noComposer, .notFront: return .failed(L10n.t("No message box found in the Claude app"))
            case .notSent: return .failed(L10n.t("The Claude app didn't take the text"))
            }
        case .pasteInto(let app):
            // Asked before anything moves: a refusal after the app has been
            // brought forward would leave you switched away for nothing.
            guard AXIsProcessTrusted() else { return .failed(accessibilityOff()) }
            stepAside()
            guard let place = await SessionFocus.focusTab(pid: pid), place.activated || place.tabSelected else {
                return .failed(L10n.t("\(app) did not come forward"))
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier == SessionFocus.owningApp(of: pid)?.processIdentifier else {
                return .failed(L10n.t("\(app) did not come forward"))
            }
            // ⌘V lands in whichever tab is in front. Pasted only where that
            // is surely the session's; otherwise the message waits on the
            // clipboard for you to put where it belongs.
            let window = PasteTarget.frontWindow(of: front.processIdentifier)
            let hints = PasteTarget.hints(session: session, cwd: SessionFocus.currentDirectory(of: pid))
            guard PasteTarget.isSure(tabSelected: place.tabSelected, window: window, hints: hints) else {
                copy(line)
                log.notice("reply copied for \(app, privacy: .public): the tab in front may not be the session's")
                return .copied(app: app)
            }
            paste(line)
            log.notice("reply pasted into \(app, privacy: .public), left unsent")
            return .pasted(app: app)
        case .none:
            return .failed(L10n.t("This session can't be written to from here"))
        }
    }

    /// Says where to turn it on — and opens the way there, so the next try
    /// can work.
    private static func accessibilityOff() -> String {
        AccessibilityAccess.request()
        return L10n.t("Accessibility is off for spyx — switch it on in System Settings → Privacy & Security → Accessibility")
    }

    private static func outcome(_ result: EffortInjector.Outcome, host: String) -> ReplyOutcome {
        switch result {
        case .sent: return .sent
        case .promptNotIdle: return .busy
        case .tabNotFound: return .failed(L10n.t("Its \(host) tab wasn't found"))
        case .contentUnreadable: return .failed(L10n.t("\(host) wouldn't let spyx read the tab"))
        case .appleScriptError: return .failed(L10n.t("\(host) refused the message — check spyx is allowed under Automation"))
        case .noTTY, .hostedBy: return .failed(L10n.t("This session has no terminal to write to"))
        }
    }

    // MARK: Stop

    /// Brings the session's tab to the front and presses Esc there — the key
    /// Claude Code and Grok take as "stop what you are doing". Not pressed
    /// unless the tab in front is the session's own.
    static func stop(_ session: AgentSession) async -> Bool {
        if case .claudeApp(let host) = reach(session) {
            return ClaudeDesktopComposer.stopInBackground(hostSession: host)
        }
        guard canStop(session), let pid = session.processID, let tty = SessionFocus.tty(of: pid),
              let app = SessionFocus.owningApp(of: pid), AXIsProcessTrusted() else { return false }
        guard await SessionFocus.focus(pid: pid) else { return false }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            log.notice("stop: \(app.localizedName ?? "?", privacy: .public) did not come to the front")
            return false
        }
        if app.bundleIdentifier == "com.apple.Terminal" {
            guard EffortInjector.focus().focusedTTY == EffortInjector.normalizeTTY(tty) else {
                log.notice("stop: another Terminal tab is in front")
                return false
            }
        }
        post(key: 53)   // Esc
        log.notice("stop: Esc -> pid \(pid, privacy: .public)")
        return true
    }

    // MARK: Text

    /// The message as one line: trimmed, line breaks as spaces, control
    /// characters out, at most 4000 characters. Nil when nothing is left.
    nonisolated static func oneLine(_ text: String) -> String? {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x09, 0x2028, 0x2029: out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F: continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        let line = out.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(4000))
    }

    /// The text as an AppleScript string literal: backslashes and quotes
    /// escaped, so nothing in it can end the string.
    nonisolated static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// ⌘V with the text, the clipboard put back after — marked transient so
    /// clipboard managers keep it out of their history.
    private static func paste(_ text: String) {
        let board = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = board.changeCount
        post(key: 9, flags: .maskCommand)
        // Long enough for a busy app to have read it — put back sooner and
        // a slow ⌘V pastes what was there before instead of the message.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            restore(saved, to: board, ifStill: ours)
        }
    }

    /// Puts the clipboard back as it was — unless something has been copied
    /// since, which is yours and stays.
    @discardableResult
    static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to board: NSPasteboard,
                        ifStill changeCount: Int) -> Bool {
        guard board.changeCount == changeCount else { return false }
        board.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
        return true
    }

    /// The message on the clipboard to stay, for you to paste where it goes.
    private static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
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

/// iTerm2's own scripting: write a line into the session on a tty, without
/// bringing iTerm2 forward — only at an idle prompt, like Terminal.app.
enum ITermWriter {
    /// `run` answers nil when the script itself failed — no permission, or
    /// iTerm2 gone — which is a refusal, not a missing tab.
    static func write(_ line: String, tty: String,
                      run: (String) -> String? = ITermWriter.run) -> EffortInjector.Outcome {
        guard tty.range(of: #"^ttys?[0-9]+$"#, options: .regularExpression) != nil else { return .noTTY }
        let device = "/dev/" + tty
        let read = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then return contents of s
                    end repeat
                end repeat
            end repeat
            return (ASCII character 3)
        end tell
        """
        guard let screen = run(read) else { return .appleScriptError("read") }
        guard screen != "\u{3}" else { return .tabNotFound }
        guard PromptIdleDetector.isIdle(screenText: screen) else { return .promptNotIdle }
        let write = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            tell s to write text \(SessionCommander.appleScriptLiteral(line))
                            return "sent"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not-found"
        end tell
        """
        switch run(write) {
        case "sent": return .sent
        case "not-found": return .tabNotFound
        default: return .appleScriptError("write")
        }
    }

    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }
}

/// Whether ⌘V in the app in front is sure to land in the session's own tab.
///
/// Only Terminal, iTerm2 and cmux can be told which tab to show; Ghostty,
/// Warp, VS Code and the rest are only brought forward, with whatever tab
/// they last had. So the paste goes ahead where nothing else could be in
/// front — one window, no tabs in it — or where the window in front names
/// the session's folder or the session itself.
enum PasteTarget {
    struct Window: Equatable {
        let count: Int
        let hasTabs: Bool
        let title: String?
    }

    static func isSure(tabSelected: Bool, window: Window?, hints: [String]) -> Bool {
        if tabSelected { return true }
        guard let window else { return false }
        if window.count == 1 && !window.hasTabs { return true }
        guard let title = window.title?.lowercased(), !title.isEmpty else { return false }
        return hints.contains { hint in hint.count >= 3 && title.contains(hint.lowercased()) }
    }

    /// What the session's window is likely to be titled after: its folder
    /// and its own name.
    static func hints(session: AgentSession, cwd: String?) -> [String] {
        var hints: [String] = []
        if let cwd, !cwd.isEmpty, cwd != "/" { hints.append((cwd as NSString).lastPathComponent) }
        let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, !hints.contains(name) { hints.append(name) }
        return hints
    }

    /// The app's windows as Accessibility sees them: how many, whether the
    /// focused one has a tab bar, and its title.
    static func frontWindow(of pid: pid_t) -> Window? {
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        let count = (windows as? [AXUIElement])?.count ?? 0
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return count > 0 ? Window(count: count, hasTabs: true, title: nil) : nil
        }
        let element = window as! AXUIElement
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        return Window(count: count, hasTabs: hasTabGroup(element), title: title as? String)
    }

    private static func hasTabGroup(_ window: AXUIElement) -> Bool {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return false }
        return list.contains { child in
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            return (role as? String) == (kAXTabGroupRole as String)
        }
    }
}
