import AppKit
import ApplicationServices
import OSLog

/// A reply written in pillr, sent into a thread of the Codex app — the
/// desktop app OpenAI ships as ChatGPT.app, bundle `com.openai.codex`.
///
/// What was learnt from the app's own bundle (`Contents/Resources/app.asar`):
///
/// - `codex://threads/<id>` opens a thread: the main process takes the
///   link, checks the thread exists, and moves its window there. The id is
///   the thread's UUID (Codex writes v7), checked by the same pattern here.
/// - The window does not say which thread it shows in its address: the
///   page is `app://-/index.html` and its router keeps the route in memory.
///   What does say it is the sidebar: the row of the thread on screen is
///   marked `aria-current="page"` and labelled with the thread's title. So
///   the thread on screen is the one whose title that row carries, when no
///   other thread has the same title; anything else is not sure, and not
///   sure is never written into.
/// - The message box is a ProseMirror editor (`role="textbox"`,
///   `aria-multiline`), labelled with its placeholder, which changes with
///   the mode and the language — so it is known by its editor, as in the
///   Claude app. The terminal pane's input is xterm's and never matches.
/// - Its submit button is labelled Send, or Stop while a turn runs (Steer
///   or Queue with text in the box). Those labels follow the app's
///   language; the lists below are the app's own translations of them.
///
/// Every route here fills the box through Accessibility and presses the
/// app's own Send. Keys are posted only while the Codex app is in front
/// with that very box focused — a key posted otherwise lands in whatever
/// app has the keyboard.
enum CodexDesktopComposer {
    static let bundleID = "com.openai.codex"
    private static let log = Logger(subsystem: "lol.pillr.app", category: "sessions")

    /// What became of a message, or the one reason it was not sent.
    enum Outcome: Equatable {
        case sent
        /// The Codex app is not running.
        case notRunning
        case notFront
        /// pillr is not allowed to use Accessibility.
        case notTrusted
        /// No message box in the window.
        case noComposer
        /// The box held a draft that wouldn't come out to make room.
        case draft
        /// Something else went into the box while the message was going in.
        case userTyping
        /// Put in, Send pressed, and the box never emptied.
        case notSent
        /// The window shows a different thread.
        case otherThread
        /// Which thread the window shows can't be told for sure.
        case unconfirmed
        /// The thread is mid-turn: its button reads Stop.
        case working
    }

    /// What the Codex app's window shows, as far as it can be told.
    enum View: Equatable {
        case unknown
        /// Something other than the thread meant.
        case other
        case thread(String)
    }

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: Links

    /// The app's own link to a thread: `codex://threads/<id>`.
    static func link(toThread id: String) -> URL? {
        guard CodexAppThread.isThreadID(id) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    /// The thread a `codex://threads/<id>` link opens, as the app reads it:
    /// the first path segment, a UUID; `codex://threads/new` opens none.
    static func threadID(inLink address: String) -> String? {
        guard let url = URL(string: address), url.scheme?.lowercased() == "codex", url.host == "threads",
              let first = url.pathComponents.first(where: { $0 != "/" }), CodexAppThread.isThreadID(first) else { return nil }
        return first
    }

    /// Opens the thread in the Codex app by its link, the app brought
    /// forward with it (started if need be), and waits until the window is
    /// seen to show it. Answers what the window was last seen to show.
    @MainActor
    static func open(thread id: String) async -> View {
        guard let url = link(toThread: id) else { return .unknown }
        let wasRunning = runningApp != nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard (try? await NSWorkspace.shared.open(url, configuration: configuration)) != nil else { return .unknown }
        guard AXIsProcessTrusted() else { return .unknown }
        let titles = CodexAppThread.titles()
        var seen = View.unknown
        // A cold start takes longer to come up than a window to move.
        for _ in 0..<(wasRunning ? 24 : 60) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let app = runningApp else { continue }
            seen = view(of: app, thread: id, titles: titles)
            if seen == .thread(id) {
                log.notice("codex: opened the thread by its link")
                return seen
            }
        }
        log.notice("codex: the thread's link left the window on \(String(describing: seen), privacy: .public)")
        return seen
    }

    // MARK: What the window shows

    /// A title as compared: ends trimmed, every run of white space one space.
    static func normalized(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The thread on screen from the labels of what the window marks
    /// current — the sidebar row of the thread it shows, among them:
    /// `thread` when that row carries one of the thread's titles and no
    /// other thread is called the same; `other` when it carries another
    /// title, or none a thread of Codex's has; `unknown` when nothing is
    /// marked, or a title is not enough to tell (none known for the thread,
    /// two threads sharing it, two rows marked with different ones).
    static func view(shownTitles: [String], thread: String, titles: [String: [String]]) -> View {
        let shown = Set(shownTitles.map(normalized).filter { !$0.isEmpty })
        guard !shown.isEmpty else { return .unknown }
        let mine = Set((titles[thread] ?? []).map(normalized).filter { !$0.isEmpty })
        guard !mine.isEmpty else { return .unknown }
        // Only labels that are some thread's title say which thread is on
        // screen; anything else marked current (a picker's choice) does not.
        let known = Set(titles.values.flatMap { $0 }.map(normalized))
        let threadTitles = shown.intersection(known)
        guard threadTitles.count <= 1 else { return .unknown }
        guard let title = threadTitles.first, mine.contains(title) else { return .other }
        let shared = titles.contains { id, names in
            id.lowercased() != thread.lowercased() && names.contains { normalized($0) == title }
        }
        return shared ? .unknown : .thread(thread)
    }

    /// What a Codex app window shows, in front or not.
    @MainActor
    static func view(of app: NSRunningApplication, thread: String, titles: [String: [String]]) -> View {
        guard AXIsProcessTrusted(), let window = window(of: app) else { return .unknown }
        return view(shownTitles: currentRowTitles(in: window), thread: thread, titles: titles)
    }

    /// The app's main window — where its links open a thread — read for
    /// what it shows and written into, the same one for both.
    @MainActor
    private static func window(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = prepare(pid: app.processIdentifier)
        return element(axApp, kAXMainWindowAttribute) ?? element(axApp, kAXFocusedWindowAttribute)
    }

    /// The labels of the elements marked current (`aria-current`) in the
    /// window — the sidebar's row for the thread on screen.
    private static func currentRowTitles(in window: AXUIElement) -> [String] {
        let wanted = [kAXRoleAttribute, kAXChildrenAttribute, "AXARIACurrent"] as CFArray
        var stack = [window]
        var visited = 0
        var titles: [String] = []
        while let node = stack.popLast(), visited < 20_000 {
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, wanted, [], &values) == .success,
                  let list = values as? [Any], list.count == 3 else { continue }
            if let current = list[2] as? String, isCurrent(current) {
                if let title = label(of: node) { titles.append(title) }
                continue
            }
            if let children = list[1] as? [AXUIElement] { stack.append(contentsOf: children) }
        }
        return titles
    }

    /// `aria-current` set to anything but false: "page", "true", "location".
    static func isCurrent(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        return !value.isEmpty && value != "false"
    }

    /// What an element is called: its label, else the text inside it.
    private static func label(of node: AXUIElement) -> String? {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let text = string(node, attribute), !normalized(text).isEmpty { return text }
        }
        var texts: [String] = []
        var stack = [node]
        var visited = 0
        while let next = stack.popLast(), visited < 60 {
            visited += 1
            if string(next, kAXRoleAttribute) == kAXStaticTextRole, let text = string(next, kAXValueAttribute) {
                texts.append(text)
            }
            if let children = children(of: next) { stack.append(contentsOf: children.reversed()) }
        }
        let joined = normalized(texts.joined(separator: " "))
        return joined.isEmpty ? nil : joined
    }

    // MARK: The message box and its button

    static let composerEditorClass = "ProseMirror"

    /// The message box, by what it says of itself: a text area made by
    /// ProseMirror, never anything of xterm's.
    static func isComposer(role: String?, classes: [String]) -> Bool {
        guard role == kAXTextAreaRole else { return false }
        guard !classes.contains(where: { $0.lowercased().contains("xterm") }) else { return false }
        return classes.contains(composerEditorClass)
    }

    /// The submit button's labels in the Codex app's languages, from the
    /// app's own catalogue (`composer.submitButtonTooltip.send` / `.stop`).
    static let sendLabels: Set<String> = [
        "send", "ላክ", "إرسال", "изпращане", "পাঠান", "pošalji", "envia", "odeslat", "senden", "αποστολή", "enviar",
        "saada", "ارسال", "lähetä", "envoyer", "મોકલો", "भेजें", "küldés", "ուղարկել", "kirim", "senda", "invia", "送信",
        "გაგზავნა", "жіберу", "ಕಳುಹಿಸಿ", "보내기", "siųsti", "sūtīt", "испрати", "അയയ്ക്കുക", "илгээх", "पाठवा", "hantar",
        "ပို့မည်", "verzenden", "ਭੇਜੋ", "wyślij", "trimite", "отправить", "odoslať", "pošlji", "dir", "dërgo", "пошаљи",
        "skicka", "tuma", "அனுப்பு", "పంపు", "ส่ง", "mag-send", "gönder", "надіслати", "بھیجیں", "gửi", "发送", "傳送",
    ]
    static let stopLabels: Set<String> = [
        "stop", "አቁም", "إيقاف", "спиране", "বন্ধ করুন", "zaustavi", "atura", "zastavit", "stoppen", "διακοπή", "detener",
        "peata", "توقف", "pysäytä", "arrêter", "બંધ કરો", "रोकें", "leállítás", "դադարեցնել", "hentikan", "stöðva",
        "interrompi", "停止", "გაჩერება", "тоқтату", "ನಿಲ್ಲಿಸಿ", "중지", "sustabdyti", "apturēt", "запри", "നിർത്തുക",
        "зогсоох", "थांबवा", "berhenti", "ရပ်ရန်", "stopp", "ਰੋਕੋ", "zatrzymaj", "parar", "oprește", "остановить",
        "zastaviť", "ustavi", "jooji", "ndalo", "заустави", "stoppa", "simamisha", "நிறுத்து", "నిలిపివేయి", "หยุด",
        "itigil", "durdur", "зупинити", "روکیں", "ngừng",
    ]

    enum ButtonKind: Equatable { case send, stop }

    /// The submit button by its whole label — "Send", never "Send to cloud"
    /// or "Stop dictation", which only contain the word.
    static func buttonKind(label: String) -> ButtonKind? {
        let label = normalized(label).lowercased()
        if sendLabels.contains(label) { return .send }
        if stopLabels.contains(label) { return .stop }
        return nil
    }

    private static func findComposer(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var head = 0
        while head < queue.count, head < 8000 {
            let node = queue[head]
            head += 1
            let role = string(node, kAXRoleAttribute)
            if role == kAXTextAreaRole {
                if isComposer(role: role, classes: classes(node)) { return node }
                continue
            }
            if let list = children(of: node) { queue.append(contentsOf: list) }
        }
        return nil
    }

    @MainActor
    private static func composer(of app: NSRunningApplication) -> AXUIElement? {
        for attempt in 0...Self.treeAttempts {
            // Electron builds the tree a beat after it is first asked for.
            if attempt > 0 { usleep(Self.treeWait) }
            if let window = window(of: app), let box = findComposer(in: window) {
                return box
            }
        }
        return nil
    }

    /// The box's own submit button: the nearest Send or Stop around it,
    /// looked for in ever wider circles so another box's never comes first.
    private static func submitButton(near composer: AXUIElement) -> (button: AXUIElement, kind: ButtonKind)? {
        var box = composer
        for _ in 0..<10 {
            guard let parent = element(box, kAXParentAttribute) else { break }
            box = parent
            var stack = [box]
            var visited = 0
            while let node = stack.popLast(), visited < 3000 {
                visited += 1
                if string(node, kAXRoleAttribute) == kAXButtonRole {
                    let label = string(node, kAXDescriptionAttribute) ?? string(node, kAXTitleAttribute) ?? ""
                    if let kind = buttonKind(label: label) { return (node, kind) }
                    continue
                }
                if let list = children(of: node) { stack.append(contentsOf: list) }
            }
        }
        return nil
    }

    /// The button once the box is empty: Stop says the thread is working.
    /// Read a few times, as the button catches up with the box a beat later.
    private static func emptyBoxButton(near composer: AXUIElement) -> ButtonKind? {
        var kind = submitButton(near: composer)?.kind
        for _ in 0..<3 where kind == nil {
            usleep(Self.readBackWait)
            kind = submitButton(near: composer)?.kind
        }
        return kind
    }

    // MARK: Sending

    /// A message into the thread the Codex app's window is showing, with
    /// the app left where it is: the box filled through Accessibility, its
    /// own Send pressed, no keys, nothing brought forward. A draft in the
    /// box is set aside and put back after.
    @MainActor
    static func sendInBackground(message: String, toThread id: String) -> Outcome {
        guard let line = SessionCommander.oneLine(message) else { return .notSent }
        guard let app = runningApp else { return .notRunning }
        guard AXIsProcessTrusted() else { return .notTrusted }
        let shown = view(of: app, thread: id, titles: CodexAppThread.titles())
        guard shown == .thread(id) else {
            log.notice("codex (background): window shows \(String(describing: shown), privacy: .public)")
            return .otherThread
        }
        guard let composer = composer(of: app) else {
            log.notice("codex (background): no message box")
            return .noComposer
        }
        return fillAndSend(line, composer: composer, mayType: false)
    }

    /// The same with the app in front, after the thread was opened by its
    /// link: only while the window is seen to show that very thread. Keys
    /// are a last resort, and only into that box with the focus on it.
    @MainActor
    static func send(message: String, toThread id: String) -> Outcome {
        guard let line = SessionCommander.oneLine(message) else { return .notSent }
        guard let app = runningApp else { return .notRunning }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return .notFront }
        guard AXIsProcessTrusted() else { return .notTrusted }
        let shown = view(of: app, thread: id, titles: CodexAppThread.titles())
        switch shown {
        case .thread(id): break
        case .unknown: return .unconfirmed
        default: return .otherThread
        }
        guard let composer = composer(of: app) else { return .noComposer }
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(Self.settle)
        let first = fillAndSend(line, composer: composer, mayType: true)
        guard first == .notSent else { return first }
        // Just brought forward: the box may still be redrawing. Once more.
        usleep(500_000)
        guard let fresh = self.composer(of: app) else { return .noComposer }
        AXUIElementSetAttributeValue(fresh, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(Self.settle)
        log.notice("codex: second try with a fresh message box")
        return fillAndSend(line, composer: fresh, mayType: true)
    }

    /// Draft aside, the line in and read back, the app's own Send pressed,
    /// the box seen to empty. `mayType` allows ⌘V and Return as fallbacks,
    /// each still only while the box has the focus in the app in front.
    private static func fillAndSend(_ line: String, composer: AXUIElement, mayType: Bool) -> Outcome {
        var draft: String?
        if !value(of: composer).isEmpty {
            guard let taken = takeDraft(from: composer) else {
                log.notice("codex: the box has a draft that wouldn't move")
                return .draft
            }
            draft = taken
        }
        defer { if let draft { putBack(draft, into: composer) } }

        if emptyBoxButton(near: composer) == .stop {
            log.notice("codex: the thread is working")
            return .working
        }

        AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, line as CFString)
        if !waitUntil(composer, holds: line) {
            let now = value(of: composer)
            if !now.isEmpty, !ClaudeDesktopComposer.isOurs(now, line) {
                log.notice("codex: the box changed under us; stopping")
                return .userTyping
            }
            clear(composer, ifItHolds: line)
            guard mayType, canType(into: composer) else {
                log.notice("codex: \(ClaudeDesktopComposer.describe(value(of: composer), line), privacy: .public)")
                return .notSent
            }
            paste(line)
            guard waitUntil(composer, holds: line) else {
                clear(composer, ifItHolds: line)
                return .notSent
            }
        }

        if let send = submitButton(near: composer), send.kind == .send {
            AXUIElementPerformAction(send.button, kAXPressAction as CFString)
        } else if mayType, canType(into: composer) {
            post(key: 36)   // Return: the box's own submit
        } else {
            log.notice("codex: no Send button")
            clear(composer, ifItHolds: line)
            return .notSent
        }
        var now = value(of: composer)
        for _ in 0..<Self.readBackTries where !now.isEmpty {
            usleep(Self.readBackWait)
            now = value(of: composer)
        }
        if now.isEmpty {
            log.notice("codex: sent \(line.count, privacy: .public) chars")
            return .sent
        }
        clear(composer, ifItHolds: line)
        return .notSent
    }

    /// Presses the Codex app's own Stop for the thread its window shows,
    /// in the background. False when that is not the thread, or nothing
    /// is running to stop.
    @MainActor
    static func stopInBackground(thread id: String) -> Bool {
        guard let app = runningApp, AXIsProcessTrusted(),
              view(of: app, thread: id, titles: CodexAppThread.titles()) == .thread(id),
              let composer = composer(of: app), value(of: composer).isEmpty,
              let stop = submitButton(near: composer), stop.kind == .stop else { return false }
        let pressed = AXUIElementPerformAction(stop.button, kAXPressAction as CFString) == .success
        log.notice("codex: Stop pressed \(pressed, privacy: .public)")
        return pressed
    }

    // MARK: The box

    /// Keys go only to this box: the Codex app in front, the box focused.
    private static func canType(into composer: AXUIElement) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleID,
              let focused = element(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedUIElementAttribute)
        else { return false }
        return CFEqual(focused, composer)
    }

    private static func value(of element: AXUIElement) -> String {
        (string(element, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func waitUntil(_ element: AXUIElement, holds line: String) -> Bool {
        for _ in 0..<Self.readBackTries {
            usleep(Self.readBackWait)
            if ClaudeDesktopComposer.holdsExactly(value(of: element), line) { return true }
        }
        return false
    }

    /// Takes out what pillr put in, never a draft of the person's: through
    /// Accessibility, or by Delete only into the focused box in front.
    private static func clear(_ element: AXUIElement, ifItHolds line: String) {
        guard ClaudeDesktopComposer.isOurs(value(of: element), line) else { return }
        if clearByAccessibility(element) { return }
        guard canType(into: element) else {
            log.notice("codex: left our text in the box rather than type into another app")
            return
        }
        for _ in 0..<(string(element, kAXValueAttribute) ?? "").count { post(key: 51) }   // Delete
        usleep(Self.settle)
    }

    private static func clearByAccessibility(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFString)
        for _ in 0..<Self.readBackTries {
            if value(of: element).isEmpty { return true }
            usleep(Self.readBackWait)
        }
        return value(of: element).isEmpty
    }

    /// The person's draft, out of the box until the reply is sent; nil, and
    /// the box as it was, when it won't come out.
    private static func takeDraft(from element: AXUIElement) -> String? {
        let draft = string(element, kAXValueAttribute) ?? ""
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if clearByAccessibility(element) {
            log.notice("codex: draft of \(draft.count, privacy: .public) chars set aside")
            return draft
        }
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, draft as CFString)
        return nil
    }

    /// The draft back in the box; on the clipboard should the box not take
    /// it. A draft is never lost.
    private static func putBack(_ draft: String, into element: AXUIElement) {
        let wanted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value(of: element).isEmpty, value(of: element) != wanted { _ = clearByAccessibility(element) }
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, draft as CFString)
        for _ in 0..<Self.readBackTries {
            if value(of: element) == wanted {
                log.notice("codex: draft put back")
                return
            }
            usleep(Self.readBackWait)
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(draft, forType: .string)
        log.notice("codex: the draft wouldn't go back in; it is on the clipboard")
    }

    /// ⌘V with the line, the clipboard put back after; marked transient and
    /// concealed so clipboard managers keep it out of their history.
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

    // MARK: Accessibility

    /// Asks the Codex app for its tree: Electron builds one only once an
    /// assistive client says it wants it. A busy app answers late; never
    /// wait on it long.
    @discardableResult
    static func prepare(pid: pid_t) -> AXUIElement {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return axApp
    }

    static let treeAttempts = 4
    static let treeWait: useconds_t = 250_000
    static let settle: useconds_t = 220_000
    static let readBackTries = 7
    static let readBackWait: useconds_t = 150_000

    private static func classes(_ element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
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
