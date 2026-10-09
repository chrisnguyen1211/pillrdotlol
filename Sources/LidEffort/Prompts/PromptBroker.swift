import Darwin
import Foundation
import OSLog

/// The app's end of the hook: a Unix socket the hook process connects to,
/// hands a prompt over, and waits on for the answer.
///
/// One connection per prompt, held open until the prompt is answered, the
/// patience runs out (then Claude asks in its own dialog), or the hook goes
/// away (the session was interrupted). Socket work is on a background
/// queue; everything the UI sees is delivered on the main actor.
final class PromptBroker: @unchecked Sendable {
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lid-effort/prompt.sock").path
    }

    let path: String
    /// How long a prompt waits for an answer before Claude is left to ask
    /// for itself. Under the hook's own timeout, so it is always us who
    /// lets go, cleanly.
    let patience: TimeInterval

    /// A prompt arrived. Return `.passThrough` to decline it at once (the
    /// session is in front of the person, who will answer it there), or nil
    /// to hold it for an answer.
    var onPrompt: (@MainActor (PendingPrompt) -> PromptAnswer?)?
    /// A held prompt is gone: answered, timed out, or its hook exited.
    var onGone: (@MainActor (UUID) -> Void)?
    /// An agent's turn-finished hook: that agent's session has just
    /// finished its answer. Nothing is held and nothing is answered.
    var onStop: (@MainActor (AgentStop) -> Void)?

    private let queue = DispatchQueue(label: "lol.pillr.app.prompts")
    private let lock = NSLock()
    private var held: [UUID: (fd: Int32, prompt: PendingPrompt, source: DispatchSourceRead)] = [:]
    private var listener: Int32 = -1
    private let log = Logger(subsystem: "lol.pillr.app", category: "prompts")

    /// Just under the hook's own timeout. Letting go earlier is the app's
    /// call, made only while someone is at the Mac (`UserPresence`).
    init(path: String = PromptBroker.defaultPath,
         patience: TimeInterval = TimeInterval(ClaudeHookInstaller.timeoutSeconds - 60)) {
        self.path = path
        self.patience = patience
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An existing directory keeps the mode it was made with.
        if chmod(directory, 0o700) != 0 {
            log.error("could not restrict \(directory, privacy: .public): errno \(errno, privacy: .public)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = Self.address(path)
        // The socket is created by bind(); a tight umask means it is never
        // reachable by others, not even before the chmod below. The mask is
        // process-wide, so it is held for the bind alone.
        let bound: Int32
        do {
            let previousMask = umask(0o077)
            defer { umask(previousMask) }
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if chmod(path, 0o600) != 0 {
            log.error("could not restrict the prompt socket: errno \(errno, privacy: .public)")
        }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "lol.pillr.app.prompts.accept"
        thread.start()
        log.notice("prompt broker listening at \(self.path, privacy: .public)")
    }

    func stop() {
        if listener >= 0 { close(listener); listener = -1 }
        unlink(path)
        lock.lock(); let all = held; held.removeAll(); lock.unlock()
        for entry in all.values { entry.source.cancel(); close(entry.fd) }
    }

    /// Answer a held prompt. Unknown or already-answered ids are ignored.
    func answer(_ id: UUID, with answer: PromptAnswer) {
        lock.lock(); let entry = held.removeValue(forKey: id); lock.unlock()
        guard let entry else { return }
        entry.source.cancel()
        var reply = PromptResponse.json(for: answer, prompt: entry.prompt)
        reply.append(0x0A)
        reply.withUnsafeBytes { _ = write(entry.fd, $0.baseAddress, $0.count) }
        close(entry.fd)
        log.notice("prompt \(entry.prompt.toolName, privacy: .public) answered: \(String(describing: answer), privacy: .public)")
        ActivityLedger.shared?.answered(agent: "claude", question: entry.prompt.isQuestion, asked: entry.prompt.receivedAt)
        let gone = onGone
        Task { @MainActor in gone?(id) }
    }

    // MARK: - Socket plumbing

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // closed by stop()
            }
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = Self.readLine(fd) else { close(fd); return }
        if let stop = AgentStop(request) {
            close(fd)
            log.notice("stop hook: \(stop.agent, privacy: .public) session \(stop.sessionID ?? "-", privacy: .public) finished its answer")
            let onStop = self.onStop
            Task { @MainActor in onStop?(stop) }
            return
        }
        guard let prompt = PendingPrompt(hookInput: request) else {
            close(fd)
            return
        }
        // Held first, so a client that dies while the main actor decides is
        // still noticed.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            // Readable on a connection whose request is already in means the
            // other end went away: the hook was killed, the session moved on.
            var byte: UInt8 = 0
            if read(fd, &byte, 1) <= 0 { self?.withdraw(prompt.id) }
        }
        lock.lock(); held[prompt.id] = (fd, prompt, source); lock.unlock()
        source.resume()
        log.notice("prompt received: \(prompt.toolName, privacy: .public) for session \(prompt.sessionID ?? "-", privacy: .public)")

        let onPrompt = self.onPrompt
        Task { @MainActor [weak self] in
            // No one listening is a pass-through; a listener's nil holds it.
            guard let onPrompt else { self?.answer(prompt.id, with: .passThrough); return }
            if let immediate = onPrompt(prompt) { self?.answer(prompt.id, with: immediate) }
        }
        queue.asyncAfter(deadline: .now() + patience) { [weak self] in
            self?.answer(prompt.id, with: .passThrough)
        }
    }

    /// Lets go of a held prompt that was answered somewhere else — in the
    /// terminal, in the Claude app — see `PromptSettlement`. The connection
    /// is closed with nothing written: the hook hands back no decision, so
    /// whatever was answered there stands, and if Claude's own dialog is
    /// somehow still up it simply stays up.
    func release(_ id: UUID) {
        withdraw(id, because: "answered elsewhere")
    }

    private func withdraw(_ id: UUID, because reason: String = "its hook went away") {
        lock.lock(); let entry = held.removeValue(forKey: id); lock.unlock()
        guard let entry else { return }
        log.notice("prompt withdrawn: \(reason, privacy: .public)")
        entry.source.cancel()
        close(entry.fd)
        let gone = onGone
        Task { @MainActor in gone?(id) }
    }

    /// The session id of a Claude Code Stop hook's payload — the main
    /// agent's, not a subagent's (SubagentStop is another event).
    static func stoppedSession(_ request: Data) -> String? {
        AgentStop(request).flatMap { $0.agent == "claude" ? $0.sessionID : nil }
    }

    /// One newline-terminated request. The client keeps its end open after
    /// it — the open connection is how we know it is still waiting.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<n])
        }
        return nil
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

/// The hook's end: `LidEffort --prompt-hook`, run by Claude Code with the
/// prompt on stdin. Hands it to the app and prints whatever comes back.
/// Every failure is silent and prints nothing, which leaves Claude to ask
/// in its own dialog — a notch that is not running must never stall it.
enum PromptHookClient {
    /// One line to the app, no answer awaited.
    static func notify(_ request: Data, path: String = PromptBroker.defaultPath) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = PromptBroker.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return }
        var line = request.filter { $0 != 0x0A }
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    static func exchange(_ request: Data, path: String = PromptBroker.defaultPath) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = PromptBroker.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var line = request.filter { $0 != 0x0A }
        line.append(0x0A)
        let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == line.count else { return nil }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(contentsOf: buffer[0..<n])
        }
        return reply
    }

    static func runIfRequested() {
        // Stop: hand the payload over and go — Claude Code waits on a hook,
        // and the end of an answer must never be held up by pillr.
        let arguments = CommandLine.arguments
        if arguments.contains(ClaudeHookInstaller.stopMarker) {
            let agent = arguments.firstIndex(of: "--agent").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "claude"
            let request = FileHandle.standardInput.readDataToEndOfFile()
            notify(AgentStop.envelope(agent: agent, payload: request))
            exit(0)
        }
        // Codex's notify program: the turn's JSON comes as the last argument.
        // Whoever had notify before pillr is called first, exactly as before.
        if let marker = arguments.firstIndex(of: AgentHooks.codexMarker) {
            let rest = Array(arguments[(marker + 1)...])
            let payload = rest.last ?? "{}"
            if let then = rest.firstIndex(of: AgentHooks.thenMarker), rest.indices.contains(then + 1) {
                let program = rest[then + 1]
                let theirs = Array(rest[(then + 2)...].dropLast())
                let process = Process()
                process.executableURL = URL(fileURLWithPath: program)
                process.arguments = theirs + [payload]
                try? process.run()
            }
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               json["type"] as? String == "agent-turn-complete" {
                notify(AgentStop.envelope(agent: "codex", payload: Data(payload.utf8)))
            }
            exit(0)
        }
        guard CommandLine.arguments.contains("--prompt-hook") else { return }
        let request = FileHandle.standardInput.readDataToEndOfFile()
        if let reply = exchange(request) {
            let text = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { print(text) }
        }
        exit(0)
    }
}

/// One agent's "turn finished" as the hooks hand it over: which agent, and
/// whatever it names the session by — Claude's and Grok's session id,
/// Codex's thread id, Cursor's conversation id.
struct AgentStop: Equatable {
    let agent: String
    let sessionID: String?
    let cwd: String?

    /// What the hook client sends: the agent's own payload, tagged.
    static func envelope(agent: String, payload: Data) -> Data {
        var json = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        json["pillr_agent"] = agent
        json["pillr_event"] = "stop"
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    init?(_ request: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else { return nil }
        if let agent = json["pillr_agent"] as? String, json["pillr_event"] as? String == "stop" {
            // A subagent's stop is not the answer's end.
            let event = (json["hook_event_name"] as? String) ?? (json["hookEventName"] as? String) ?? "Stop"
            guard !event.lowercased().hasPrefix("subagent") else { return nil }
            // Antigravity stops between steps too; only a fully idle stop is the end.
            guard json["fullyIdle"] as? Bool != false else { return nil }
            self.agent = agent
        } else if json["hook_event_name"] as? String == "Stop" {
            // From before the hook said which agent it was: Claude Code.
            self.agent = "claude"
        } else {
            return nil
        }
        sessionID = (json["session_id"] as? String) ?? (json["sessionId"] as? String)
            ?? (json["thread-id"] as? String) ?? (json["conversation_id"] as? String)
            ?? (json["conversationId"] as? String)
        cwd = (json["cwd"] as? String) ?? (json["workspace_roots"] as? [String])?.first
            ?? (json["workspacePaths"] as? [String])?.first
    }

    init(agent: String, sessionID: String?, cwd: String?) {
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
    }
}
