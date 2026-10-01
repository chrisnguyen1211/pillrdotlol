import Foundation

/// Reads LM Studio's own server log for the numbers each request left behind.
///
/// `~/.lmstudio/server-logs/<YYYY-MM>/<YYYY-MM-DD>.<N>.log`, one line per
/// event, each prefixed `[2026-09-10 00:33:54][INFO][qwen3.8-27b]` — the third
/// bracket is the model instance a client addressed. Recorded from 0.4.24:
///
///     [2026-09-10 00:35:38][INFO][qwen3.8-27b] Running chat completion on conversation with 1 messages.
///     [2026-09-10 00:35:39][INFO][qwen3.8-27b] Prompt processing progress: 100.0%
///     [2026-09-10 00:35:56][INFO][qwen3.8-27b] Generated prediction: {
///       "id": "chatcmpl-…",
///       …
///       "usage": {
///         "prompt_tokens": 66,
///         "completion_tokens": 300,
///         "total_tokens": 366,
///         "completion_tokens_details": {
///           "reasoning_tokens": 300
///         },
///         "total_draft_tokens_count": 492,
///         "accepted_draft_tokens_count": 176,
///         "rejected_draft_tokens_count": 316
///       },
///       "stats": {
///         "tokens_per_second": 17.92897117267284,
///         "time_to_first_token": 1.162136,
///         "generation_time": 17.839055000000002,
///         "stop_reason": "maxPredictedTokensReached"
///       },
///       …
///     }
///
/// Three response shapes turn up, one per endpoint family: the OpenAI one
/// (`usage` with counts, `stats` holding draft counts or `{}`), LM Studio's
/// `/api/v0` (the same `usage`, plus `stats` with the clock), and `/api/v1`
/// (everything under `stats`: `input_tokens`, `total_output_tokens`,
/// `reasoning_output_tokens`, `tokens_per_second`, `time_to_first_token_seconds`).
///
/// The pretty-printed response carries the reply itself and, with "log
/// sensitive data" on, everything the model was asked. None of that is wanted
/// here: the scanner keeps only the two top-level `"usage"` and `"stats"`
/// blocks, recognised by their two-space indentation, and lets every other
/// line go the moment it has been read.
///
/// It works on bytes and decodes a line only once it is known to matter. The
/// log on the Mac this was written against held fifteen million lines, nearly
/// all of them the server noting an API call, and a date parse per line would
/// have taken minutes; a glance at the first byte of the message takes none.
struct LMStudioServerLog {
    enum Event: Equatable {
        /// A request reached the model: `Running chat completion on …`.
        case requestStarted(instance: String, at: Date)
        /// `Prompt processing progress: 100.0%` — generation begins here.
        case promptProcessed(instance: String, at: Date)
        case prediction(LocalPrediction)
    }

    struct Header: Equatable {
        let at: Date
        let level: String
        /// The bracketed tag: a model instance, or the server's own name.
        let instance: String
        let message: String
    }

    /// A `Generated prediction` block being read, with only its two numeric
    /// blocks collected.
    private struct Capture {
        enum Block { case usage, stats }
        let instance: String
        let at: Date
        var usage = ""
        var stats = ""
        var block: Block?
    }

    private var pending = Data()
    private var capture: Capture?
    private let formatter: DateFormatter
    /// A line this long is not a log line; give up on it rather than grow.
    private let limit = 4 * 1024 * 1024

    private static let usageOpen = Data("  \"usage\": {".utf8)
    private static let statsOpen = Data("  \"stats\": {".utf8)
    private static let blockClose = Data("  }".utf8)

    init(timeZone: TimeZone = .current) {
        // LM Studio stamps lines in the Mac's own zone, with no offset written.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = formatter
    }

    /// Feed bytes as they arrive; a line split across two reads is held until
    /// its newline comes. One pass over the buffer: nothing is shifted per line.
    mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        let buffer = pending.isEmpty ? data : pending + data
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart..<buffer.endIndex].firstIndex(of: 10) {
            events += consume(buffer[lineStart..<newline])
            lineStart = newline + 1
        }
        pending = lineStart < buffer.endIndex ? Data(buffer[lineStart..<buffer.endIndex]) : Data()
        if pending.count > limit {
            pending.removeAll()
            capture = nil
        }
        return events
    }

    /// The end of a file: whatever is buffered is a whole line, and an open
    /// block is as complete as it will get.
    mutating func finish() -> [Event] {
        var events: [Event] = []
        if !pending.isEmpty {
            let line = pending
            pending = Data()
            events += consume(line)
        }
        if let done = capture.flatMap(Self.prediction) { events.append(.prediction(done)) }
        capture = nil
        return events
    }

    private mutating func consume(_ rawLine: Data) -> [Event] {
        let line = rawLine.last == 13 ? rawLine.dropLast() : rawLine
        if capture != nil {
            guard Self.isHeaderShaped(line) else { return consumeCaptured(line) }
            // A new log line inside an unfinished block: the block is over, and
            // whatever it had collected still counts.
            let done = capture.flatMap(Self.prediction).map(Event.prediction)
            capture = nil
            return (done.map { [$0] } ?? []) + consumeHeader(line)
        }
        guard Self.isHeaderShaped(line) else { return [] }
        return consumeHeader(line)
    }

    private mutating func consumeHeader(_ line: Data) -> [Event] {
        // Only three messages matter, and each starts with its own letter:
        // that one byte rejects the server's chatter before anything is decoded.
        guard let split = Self.split(line), let first = split.message.first,
              first == 0x52 || first == 0x50 || first == 0x47,   // R, P, G
              let header = Self.header(split, formatter: formatter)
        else { return [] }
        let message = header.message
        if message.hasPrefix("Generated prediction: {") {
            capture = Capture(instance: header.instance, at: header.at)
            return []
        }
        if message.hasPrefix("Running "), message.contains("completion") {
            return [.requestStarted(instance: header.instance, at: header.at)]
        }
        if message.hasPrefix("Prompt processing progress: 100") {
            return [.promptProcessed(instance: header.instance, at: header.at)]
        }
        return []
    }

    private mutating func consumeCaptured(_ line: Data) -> [Event] {
        guard let current = capture else { return [] }
        if line.count == 1, line.first == 0x7D {   // }
            capture = nil
            return Self.prediction(current).map { [.prediction($0)] } ?? []
        }
        if let block = current.block {
            // Two spaces and a brace close a top-level block; the nested
            // `completion_tokens_details` closes deeper in and stays inside.
            if line.starts(with: Self.blockClose) {
                capture?.block = nil
            } else {
                let text = String(decoding: line, as: UTF8.self) + "\n"
                switch block {
                case .usage: capture?.usage += text
                case .stats: capture?.stats += text
                }
            }
            return []
        }
        if line.starts(with: Self.usageOpen) {
            if !String(decoding: line, as: UTF8.self).contains("{}") { capture?.block = .usage }
        } else if line.starts(with: Self.statsOpen) {
            if !String(decoding: line, as: UTF8.self).contains("{}") { capture?.block = .stats }
        }
        return []
    }

    // MARK: - Lines

    /// `[YYYY-MM-DD HH:MM:SS]` at the start, checked by shape alone.
    private static func isHeaderShaped(_ line: Data) -> Bool {
        let s = line.startIndex
        guard line.count >= 21, line[s] == 0x5B, line[s + 20] == 0x5D,
              line[s + 5] == 0x2D, line[s + 8] == 0x2D, line[s + 11] == 0x20,
              line[s + 14] == 0x3A, line[s + 17] == 0x3A else { return false }
        return true
    }

    private struct Split {
        let stamp: Data
        let level: Data
        let instance: Data
        let message: Data
    }

    /// The bracketed parts and the message, as byte slices — no decoding yet.
    private static func split(_ line: Data) -> Split? {
        let s = line.startIndex, e = line.endIndex
        let stamp = line[(s + 1)..<(s + 20)]
        var i = s + 21
        guard i < e, line[i] == 0x5B, let levelEnd = line[i..<e].firstIndex(of: 0x5D) else { return nil }
        let level = line[(i + 1)..<levelEnd]
        i = levelEnd + 1
        var instance = line[i..<i]
        if i < e, line[i] == 0x5B, let tagEnd = line[i..<e].firstIndex(of: 0x5D) {
            instance = line[(i + 1)..<tagEnd]
            i = tagEnd + 1
        }
        while i < e, line[i] == 0x20 { i += 1 }
        return Split(stamp: stamp, level: level, instance: instance, message: line[i..<e])
    }

    private static func header(_ split: Split, formatter: DateFormatter) -> Header? {
        guard let at = formatter.date(from: String(decoding: split.stamp, as: UTF8.self)) else { return nil }
        return Header(at: at, level: String(decoding: split.level, as: UTF8.self),
                      instance: String(decoding: split.instance, as: UTF8.self),
                      message: String(decoding: split.message, as: UTF8.self))
    }

    /// `[2026-09-10 00:33:54][INFO][qwen3.8-27b] Running …` → its parts.
    /// Lines from the server itself (`[LM STUDIO SERVER]`, `[LMSAuthenticator]`)
    /// carry a tag too; they are filtered by what they say, not who says it.
    static func header(of line: String, formatter: DateFormatter) -> Header? {
        let data = Data(line.utf8)
        guard isHeaderShaped(data), let split = split(data) else { return nil }
        return header(split, formatter: formatter)
    }

    // MARK: - Blocks

    private static func prediction(_ capture: Capture) -> LocalPrediction? {
        let usage = object(from: capture.usage)
        let stats = object(from: capture.stats)
        let details = usage["completion_tokens_details"] as? [String: Any] ?? [:]
        let input = integer(usage["prompt_tokens"]) ?? integer(stats["input_tokens"])
        let output = integer(usage["completion_tokens"]) ?? integer(stats["total_output_tokens"])
        guard input != nil || output != nil else { return nil }
        return LocalPrediction(
            instance: capture.instance, at: capture.at,
            inputTokens: input, outputTokens: output,
            reasoningTokens: integer(details["reasoning_tokens"]) ?? integer(stats["reasoning_output_tokens"]),
            tokensPerSecond: positive(stats["tokens_per_second"]),
            timeToFirstToken: positive(stats["time_to_first_token"])
                ?? positive(stats["time_to_first_token_seconds"]),
            generationSeconds: positive(stats["generation_time"]),
            draftTokens: integer(usage["total_draft_tokens_count"])
                ?? integer(stats["total_draft_tokens_count"]),
            acceptedDraftTokens: integer(usage["accepted_draft_tokens_count"])
                ?? integer(stats["accepted_draft_tokens_count"])
        )
    }

    private static func object(from body: String) -> [String: Any] {
        guard !body.isEmpty else { return [:] }
        let json = Data(("{\n" + body + "}").utf8)
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0 else { return nil }
        return integer
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite && double > 0 ? double : nil
    }
}

/// The server log as one stream: every file that exists, then whatever the
/// newest one grows by. LM Studio opens a new file each day and a new index
/// when it restarts, so "the newest file" is re-found on every poll.
final class LMStudioLogTail {
    private let directory: URL
    private let timeZone: TimeZone
    private var parser: LMStudioServerLog
    private(set) var file: URL?
    private(set) var offset: UInt64 = 0
    /// Read in slices this size, so a half-gigabyte of history never sits in
    /// memory at once and a night's worth of new lines is read in a few steps.
    private let chunk = 4 << 20

    init(directory: URL, timeZone: TimeZone = .current) {
        self.directory = directory
        self.timeZone = timeZone
        parser = LMStudioServerLog(timeZone: timeZone)
    }

    /// Oldest first: month directories sort as written, and within a day the
    /// index is a number, so `.10.log` follows `.9.log` rather than `.1.log`.
    static func logFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        let months = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        return months.flatMap { month -> [URL] in
            let folder = directory.appendingPathComponent(month)
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".log") }
            return names.sorted { a, b in
                let (da, ia) = split(a), (db, ib) = split(b)
                return da == db ? ia < ib : da < db
            }.map { folder.appendingPathComponent($0) }
        }
    }

    private static func split(_ name: String) -> (String, Int) {
        let parts = name.dropLast(".log".count).split(separator: ".", maxSplits: 1)
        return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
    }

    /// Everything logged so far. Leaves the tail at the end of the newest
    /// file, so `poll` continues from there.
    func loadHistory() -> [LMStudioServerLog.Event] {
        var events: [LMStudioServerLog.Event] = []
        let files = Self.logFiles(in: directory)
        for (index, url) in files.enumerated() {
            var fileParser = LMStudioServerLog(timeZone: timeZone)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let read = Self.read(handle, from: 0, chunk: chunk) { events += fileParser.append($0) }
            try? handle.close()
            if index == files.count - 1 {
                // The newest file stays open in the sense that matters: its
                // parser keeps any half-written block for the next poll.
                parser = fileParser
                file = url
                offset = read
            } else {
                events += fileParser.finish()
            }
        }
        return events
    }

    /// Whatever was written since the last look.
    func poll() -> [LMStudioServerLog.Event] {
        var events: [LMStudioServerLog.Event] = []
        guard let newest = Self.logFiles(in: directory).last else { return events }
        if newest != file {
            events += parser.finish()
            parser = LMStudioServerLog(timeZone: timeZone)
            file = newest
            offset = 0
        }
        guard let handle = try? FileHandle(forReadingFrom: newest) else { return events }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }   // rewritten from the start
        guard size > offset else { return events }
        offset += Self.read(handle, from: offset, chunk: chunk) { events += parser.append($0) }
        return events
    }

    /// Bytes from `start` to the end, a chunk at a time. Returns how many.
    private static func read(_ handle: FileHandle, from start: UInt64, chunk: Int,
                             _ body: (Data) -> Void) -> UInt64 {
        guard (try? handle.seek(toOffset: start)) != nil else { return 0 }
        var total: UInt64 = 0
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            body(data)
            total += UInt64(data.count)
        }
        return total
    }
}
