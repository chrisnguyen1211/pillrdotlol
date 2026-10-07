import Foundation

/// How many tokens a session has gone through, read from its transcript —
/// tokens, not dollars: the models are newer than any price table pillr
/// could ship, and a wrong price is worse than none.
struct TokenCount: Equatable {
    var total: Int = 0
    /// Of the input, how much was read from the prompt cache.
    var cached: Int = 0
    /// The model the newest turn ran on, and its effort where the
    /// transcript says — read in the same pass as the tokens.
    var model: String? = nil
    var effort: String? = nil

    /// "1.2M tokens", "84k tokens" — two significant figures, so the row
    /// does not change on every message.
    var text: String { L10n.t("\(Self.compact(total)) tokens") }

    static func compact(_ value: Int) -> String {
        func two(_ v: Double, _ unit: String) -> String {
            let rounded = v >= 10 ? v.rounded() : (v * 10).rounded() / 10
            let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return number + unit
        }
        switch value {
        case 1_000_000...: return two(Double(value) / 1_000_000, "M")
        case 1_000...: return two(Double(value) / 1_000, "k")
        default: return "\(value)"
        }
    }
}

/// Reads each transcript once, then only what has been appended since —
/// a tick costs a `stat` when nothing changed, and never more than a few
/// megabytes when a long transcript is first seen.
enum TokenTally {
    enum Format { case claude, codex, grok }

    private struct State {
        var offset: UInt64 = 0
        var count = TokenCount()
        /// Claude writes one line per content block of a message, each
        /// carrying the message's usage: counted once per message id.
        var seen: Set<String> = []
        var partial = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]
    /// The most read in one go; a long transcript catches up over ticks.
    static let chunk: UInt64 = 4 * 1024 * 1024

    static func count(_ url: URL, format: Format) -> TokenCount? {
        read(url, format: format).flatMap { $0.total > 0 ? $0 : nil }
    }

    /// Everything read so far — the model even before a token is counted.
    static func read(_ url: URL, format: Format) -> TokenCount? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        lock.lock()
        var state = states[url.path] ?? State()
        lock.unlock()
        if end < state.offset { state = State() }   // rewritten: start over
        if end > state.offset {
            try? handle.seek(toOffset: state.offset)
            let data = (try? handle.read(upToCount: Int(min(end - state.offset, chunk)))) ?? Data()
            state.offset += UInt64(data.count)
            var buffer = state.partial + data
            if let last = buffer.lastIndex(of: 0x0A) {
                let complete = buffer[buffer.startIndex...last]
                state.partial = Data(buffer[buffer.index(after: last)...])
                buffer = Data(complete)
                for line in buffer.split(separator: 0x0A) { add(line, format: format, to: &state) }
            } else {
                state.partial = buffer
            }
        }
        lock.lock()
        if states.count > 300 { states.removeAll() }
        states[url.path] = state
        lock.unlock()
        return state.count
    }

    private static func add(_ line: Data, format: Format, to state: inout State) {
        guard line.first == UInt8(ascii: "{"),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        switch format {
        case .claude:
            guard json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any] else { return }
            if let model = message["model"] as? String, model.hasPrefix("claude") { state.count.model = model }
            guard let usage = message["usage"] as? [String: Any] else { return }
            let id = (message["id"] as? String) ?? UUID().uuidString
            guard state.seen.insert(id).inserted else { return }
            let cached = int(usage["cache_read_input_tokens"])
            state.count.total += int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"])
                + cached + int(usage["output_tokens"])
            state.count.cached += cached
        case .codex:
            guard let payload = json["payload"] as? [String: Any] else { return }
            if payload["type"] as? String == "turn_context" {
                if let model = payload["model"] as? String { state.count.model = model }
                if let effort = payload["effort"] as? String { state.count.effort = effort }
                return
            }
            // Running totals: the latest replaces what came before.
            guard payload["type"] as? String == "token_count",
                  let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
            state.count.total = int(total["total_tokens"])
            state.count.cached = int(total["cached_input_tokens"])
        case .grok:
            guard let update = (json["params"] as? [String: Any])?["update"] as? [String: Any] else { return }
            if let model = (update["_meta"] as? [String: Any])?["modelId"] as? String { state.count.model = model }
            guard update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any] else { return }
            state.count.total += int(usage["totalTokens"])
            state.count.cached += int(usage["cachedReadTokens"])
        }
    }
}
