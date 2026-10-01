import XCTest
@testable import LidEffort

/// Lines as LM Studio 0.4.24 wrote them on 2026-09-10, one block per endpoint
/// family, with the reply text shortened. The reply is there on purpose: the
/// parser has to prove it never keeps it.
enum LMStudioLogFixtures {
    static let zone = TimeZone(identifier: "Europe/Warsaw")!

    static let startup = """
    [2026-09-10 00:18:22][INFO] Server stopped.
    [2026-09-10 00:18:28][INFO][LM STUDIO SERVER] Success! HTTP server listening on port 1234
    [2026-09-10 00:18:28][WARN][LM STUDIO SERVER] Server accepting connections from the local network. Only use this if you know what you are doing!
    [2026-09-10 00:18:28][INFO][LM STUDIO SERVER]    ->  GET  http://10.238.1.89:1234/api/v1/models
    [2026-09-10 00:20:38][ERROR] Unexpected endpoint or method. (GET /api/ps). Returning 200 anyway
    [2026-09-10 00:32:34][INFO][LMSAuthenticator][Client=lms-cli][Endpoint=listLoaded] Listing loaded models

    """

    /// `/api/v0/chat/completions`: OpenAI shape plus LM Studio's clock.
    static let nativeV0 = """
    [2026-09-10 00:35:38][INFO][qwen3.8-27b] Running chat completion on conversation with 1 messages.
    [2026-09-10 00:35:38][INFO][qwen3.8-27b] Prompt processing progress: 0.0%
    [2026-09-10 00:35:39][INFO][qwen3.8-27b] Prompt processing progress: 100.0%
    [2026-09-10 00:35:56][INFO][qwen3.8-27b] Model generated tool calls: []
    [2026-09-10 00:35:56][INFO][qwen3.8-27b] Generated prediction: {
      "id": "chatcmpl-kn6hm5jne9izrlj13nxf4c",
      "object": "chat.completion",
      "created": 1788993356,
      "model": "qwen3.8-27b",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "The lighthouse keeper SECRET-REPLY watched the sea.",
            "reasoning_content": "We need to respond SECRET-REASONING carefully.",
            "tool_calls": []
          },
          "logprobs": null,
          "finish_reason": "length"
        }
      ],
      "usage": {
        "prompt_tokens": 66,
        "completion_tokens": 300,
        "total_tokens": 366,
        "completion_tokens_details": {
          "reasoning_tokens": 300
        },
        "total_draft_tokens_count": 492,
        "accepted_draft_tokens_count": 176,
        "rejected_draft_tokens_count": 316
      },
      "stats": {
        "tokens_per_second": 17.92897117267284,
        "time_to_first_token": 1.162136,
        "generation_time": 17.839055000000002,
        "stop_reason": "maxPredictedTokensReached"
      },
      "model_info": {
        "arch": "qwen35",
        "quant": "Q8_K_XL",
        "format": "gguf",
        "context_length": 262144
      },
      "runtime": {
        "name": "llama.cpp-mac-arm64-apple-metal-advsimd",
        "version": "2.34.0",
        "supported_formats": [
          "gguf"
        ]
      }
    }

    """

    /// `/api/v1/chat`: everything under `stats`, no `usage`.
    static let nativeV1 = """
    [2026-09-10 00:33:57][INFO][qwen3.8-27b] Running chat completion on conversation with 1 messages.
    [2026-09-10 00:33:57][INFO][qwen3.8-27b] Prompt processing progress: 100.0%
    [2026-09-10 00:33:57][INFO][qwen3.8-27b] Generated prediction: {
      "model_instance_id": "qwen3.8-27b",
      "output": [
        {
          "type": "reasoning",
          "content": "We need to respond SECRET-V1 with pong"
        }
      ],
      "stats": {
        "input_tokens": 59,
        "total_output_tokens": 24,
        "reasoning_output_tokens": 24,
        "tokens_per_second": 32.95893889412729,
        "time_to_first_token_seconds": 0.11697
      },
      "response_id": "resp_8f37949f46a7c5c28698fcf7b54c58b64d828cece6c0d717"
    }

    """

    /// `/v1/chat/completions`: counts, draft statistics, and no clock at all.
    static let openAI = """
    [2026-09-02 16:12:22][INFO][flash-next-test] Running chat completion on conversation with 1 messages.
    [2026-09-02 16:12:22][INFO][flash-next-test] Prompt processing progress: 0.0%
    [2026-09-02 16:12:24][INFO][flash-next-test] Prompt processing progress: 100.0%
    [2026-09-02 16:12:28][INFO][flash-next-test] Model generated tool calls: []
    [2026-09-02 16:12:28][INFO][flash-next-test] Generated prediction: {
      "id": "chatcmpl-gca30mkkmy6dggz0j8qamv",
      "object": "chat.completion",
      "created": 1788358342,
      "model": "flash-next-test",
      "choices": [
        {
          "index": 0,
          "message": {
            "role": "assistant",
            "content": "CREATE OR REPLACE FUNCTION SECRET-SQL(p_od DATE) RETURN NUMBER IS\\n  \\"usage\\": {\\nBEGIN\\nEND;",
            "reasoning_content": "",
            "tool_calls": []
          },
          "logprobs": null,
          "finish_reason": "stop"
        }
      ],
      "usage": {
        "prompt_tokens": 109,
        "completion_tokens": 171,
        "total_tokens": 280,
        "completion_tokens_details": {
          "reasoning_tokens": 0
        }
      },
      "stats": {
        "total_draft_tokens_count": 20,
        "accepted_draft_tokens_count": 17,
        "rejected_draft_tokens_count": 3
      },
      "system_fingerprint": "flash-next-test"
    }

    """

    /// The oldest OpenAI shape: `"stats": {}` on one line.
    static let openAIWithoutDrafts = """
    [2026-09-02 16:27:30][INFO][flash-next-test] Generated prediction: {
      "id": "chatcmpl-gzx3iwh8csefxo2exs1yfv",
      "usage": {
        "prompt_tokens": 109,
        "completion_tokens": 171,
        "total_tokens": 280,
        "completion_tokens_details": {
          "reasoning_tokens": 0
        }
      },
      "stats": {},
      "system_fingerprint": "flash-next-test"
    }

    """

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }
}

final class LMStudioServerLogTests: XCTestCase {
    private func events(_ text: String, chunk: Int? = nil) -> [LMStudioServerLog.Event] {
        var parser = LMStudioServerLog(timeZone: LMStudioLogFixtures.zone)
        let data = Data(text.utf8)
        guard let chunk else { return parser.append(data) + parser.finish() }
        var collected: [LMStudioServerLog.Event] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            collected += parser.append(data[offset..<end])
            offset = end
        }
        return collected + parser.finish()
    }

    private func predictions(_ text: String, chunk: Int? = nil) -> [LocalPrediction] {
        events(text, chunk: chunk).compactMap { if case .prediction(let p) = $0 { return p } else { return nil } }
    }

    func testTheNativeResponseCarriesCountsAndTheRuntimesClock() throws {
        let all = events(LMStudioLogFixtures.nativeV0)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0], .requestStarted(instance: "qwen3.8-27b", at: LMStudioLogFixtures.date(2026, 9, 10, 0, 35, 38)))
        XCTAssertEqual(all[1], .promptProcessed(instance: "qwen3.8-27b", at: LMStudioLogFixtures.date(2026, 9, 10, 0, 35, 39)))
        guard case .prediction(let p) = all[2] else { return XCTFail("no prediction") }
        XCTAssertEqual(p.instance, "qwen3.8-27b")
        XCTAssertEqual(p.at, LMStudioLogFixtures.date(2026, 9, 10, 0, 35, 56))
        XCTAssertEqual(p.inputTokens, 66)
        XCTAssertEqual(p.outputTokens, 300)
        XCTAssertEqual(p.reasoningTokens, 300)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 17.929, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p.timeToFirstToken), 1.162136, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(p.generationSeconds), 17.839055, accuracy: 0.000001)
        XCTAssertEqual(p.draftTokens, 492)
        XCTAssertEqual(p.acceptedDraftTokens, 176)
    }

    func testTheV1ResponseKeepsEverythingUnderStats() throws {
        let p = try XCTUnwrap(predictions(LMStudioLogFixtures.nativeV1).first)
        XCTAssertEqual(p.inputTokens, 59)
        XCTAssertEqual(p.outputTokens, 24)
        XCTAssertEqual(p.reasoningTokens, 24)
        XCTAssertEqual(try XCTUnwrap(p.tokensPerSecond), 32.959, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(p.timeToFirstToken), 0.11697, accuracy: 0.00001)
        XCTAssertNil(p.generationSeconds)
        XCTAssertNil(p.draftTokens)
    }

    func testTheOpenAIResponseHasCountsAndDraftsButNoClock() throws {
        let p = try XCTUnwrap(predictions(LMStudioLogFixtures.openAI).first)
        XCTAssertEqual(p.at, LMStudioLogFixtures.date(2026, 9, 2, 16, 12, 28))
        XCTAssertEqual(p.instance, "flash-next-test")
        XCTAssertEqual(p.inputTokens, 109)
        XCTAssertEqual(p.outputTokens, 171)
        XCTAssertEqual(p.reasoningTokens, 0)
        XCTAssertNil(p.tokensPerSecond)
        XCTAssertNil(p.generationSeconds)
        XCTAssertEqual(p.draftTokens, 20)
        XCTAssertEqual(p.acceptedDraftTokens, 17)
        let bare = try XCTUnwrap(predictions(LMStudioLogFixtures.openAIWithoutDrafts).first)
        XCTAssertEqual(bare.outputTokens, 171)
        XCTAssertNil(bare.draftTokens)
    }

    func testNothingOfTheReplyOrPromptSurvivesParsing() {
        let text = LMStudioLogFixtures.nativeV0 + LMStudioLogFixtures.nativeV1 + LMStudioLogFixtures.openAI
        let described = String(describing: events(text))
        for secret in ["SECRET-REPLY", "SECRET-REASONING", "SECRET-V1", "SECRET-SQL", "lighthouse", "chatcmpl"] {
            XCTAssertFalse(described.contains(secret), "\(secret) leaked into an event")
        }
        // A reply that quotes the marker itself, as the recorded SQL reply does
        // with its embedded `"usage": {`, is inside a string on a deeper line
        // and never opens a block.
        XCTAssertEqual(predictions(LMStudioLogFixtures.openAI).map(\.outputTokens), [171])
    }

    func testBytesArrivingInAnyPiecesGiveTheSameEvents() {
        let text = LMStudioLogFixtures.startup + LMStudioLogFixtures.nativeV0 + LMStudioLogFixtures.openAI
            + LMStudioLogFixtures.nativeV1
        let whole = events(text)
        XCTAssertEqual(whole.filter { if case .prediction = $0 { return true } else { return false } }.count, 3)
        for chunk in [1, 7, 64, 1000] {
            XCTAssertEqual(events(text, chunk: chunk), whole, "chunk \(chunk)")
        }
        XCTAssertEqual(events(text.replacingOccurrences(of: "\n", with: "\r\n")), whole, "CRLF")
    }

    func testAnUnfinishedBlockStillCountsWhenTheNextLineArrives() throws {
        // The file was cut mid-block by a restart; the counts already written
        // are true, and the line that follows is not lost either.
        let cut = LMStudioLogFixtures.nativeV0.components(separatedBy: "  \"model_info\": {")[0]
            + "[2026-09-10 00:36:00][INFO][qwen3.8-27b] Running chat completion on conversation with 2 messages.\n"
        let all = events(cut)
        XCTAssertEqual(all.count, 4)
        guard case .prediction(let p) = all[2] else { return XCTFail("the cut block was dropped") }
        XCTAssertEqual(p.outputTokens, 300)
        XCTAssertEqual(all[3], .requestStarted(instance: "qwen3.8-27b", at: LMStudioLogFixtures.date(2026, 9, 10, 0, 36, 0)))

        var parser = LMStudioServerLog(timeZone: LMStudioLogFixtures.zone)
        let open = LMStudioLogFixtures.nativeV1.components(separatedBy: "  \"response_id\"")[0]
        XCTAssertEqual(parser.append(Data(open.utf8)).count, 2, "the block is still open")
        XCTAssertEqual(parser.finish().compactMap { if case .prediction(let p) = $0 { return p.outputTokens } else { return nil } }, [24])
    }

    func testABlockWithoutCountsIsNotAPrediction() {
        let text = """
        [2026-09-10 00:40:00][INFO][qwen3.8-27b] Generated prediction: {
          "id": "x",
          "stats": {
            "stop_reason": "eosFound"
          }
        }

        """
        XCTAssertTrue(predictions(text).isEmpty)
        XCTAssertTrue(events("garbage\n\n[not a stamp][INFO] Generated prediction: {\n}\n").isEmpty)
        XCTAssertTrue(predictions(text.replacingOccurrences(of: "\"stop_reason\": \"eosFound\"",
            with: "\"total_output_tokens\": true")).isEmpty, "a boolean is not a count")
        XCTAssertEqual(predictions(text.replacingOccurrences(of: "\"stop_reason\": \"eosFound\"",
            with: "\"total_output_tokens\": 12.0,\n    \"tokens_per_second\": -3")).map { ($0.outputTokens, $0.tokensPerSecond) }
            .map { "\($0.0 ?? -1) \($0.1 ?? -1)" }, ["12 -1.0"], "a negative rate is no rate")
    }

    func testHeadersAreReadWithTheMacsOwnZone() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = LMStudioLogFixtures.zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = try XCTUnwrap(LMStudioServerLog.header(
            of: "[2026-09-10 00:33:54][INFO][qwen3.8-27b] Running chat completion on conversation with 1 messages.",
            formatter: formatter))
        XCTAssertEqual(header.at, LMStudioLogFixtures.date(2026, 9, 10, 0, 33, 54))
        XCTAssertEqual(header.level, "INFO")
        XCTAssertEqual(header.instance, "qwen3.8-27b")
        XCTAssertEqual(header.message, "Running chat completion on conversation with 1 messages.")
        let untagged = try XCTUnwrap(LMStudioServerLog.header(of: "[2026-09-10 00:18:22][INFO] Server stopped.", formatter: formatter))
        XCTAssertEqual(untagged.instance, "")
        XCTAssertEqual(untagged.message, "Server stopped.")
        XCTAssertNil(LMStudioServerLog.header(of: "[2026-09-10][INFO] short stamp", formatter: formatter))
        XCTAssertNil(LMStudioServerLog.header(of: "  \"usage\": {", formatter: formatter))
    }
}

final class LMStudioLogTailTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LMStudioLogTailTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("2026-08"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("2026-09"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func append(_ text: String, to name: String) throws {
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testFilesAreReadOldestFirstWithNumericIndexes() throws {
        for name in ["2026-09/2026-09-10.10.log", "2026-09/2026-09-10.9.log", "2026-09/2026-09-02.1.log",
                     "2026-08/2026-08-31.1.log", "2026-09/notes.txt"] {
            try write("", to: name)
        }
        XCTAssertEqual(LMStudioLogTail.logFiles(in: directory).map { $0.lastPathComponent },
                       ["2026-08-31.1.log", "2026-09-02.1.log", "2026-09-10.9.log", "2026-09-10.10.log"])
        XCTAssertTrue(LMStudioLogTail.logFiles(in: directory.appendingPathComponent("missing")).isEmpty)
    }

    func testHistoryThenOnlyWhatWasAppended() throws {
        try write(LMStudioLogFixtures.openAI, to: "2026-09/2026-09-02.1.log")
        let partial = LMStudioLogFixtures.nativeV0.components(separatedBy: "  \"stats\": {")[0]
        try write(LMStudioLogFixtures.startup + partial, to: "2026-09/2026-09-10.1.log")
        let tail = LMStudioLogTail(directory: directory, timeZone: LMStudioLogFixtures.zone)
        let history = tail.loadHistory()
        XCTAssertEqual(history.compactMap { if case .prediction(let p) = $0 { return p.instance } else { return nil } },
                       ["flash-next-test"], "the block still being written is not a prediction yet")
        XCTAssertEqual(tail.file?.lastPathComponent, "2026-09-10.1.log")
        XCTAssertTrue(tail.poll().isEmpty, "nothing was appended")

        let rest = "  \"stats\": {" + LMStudioLogFixtures.nativeV0.components(separatedBy: "  \"stats\": {")[1]
        try append(rest, to: "2026-09/2026-09-10.1.log")
        let live = tail.poll()
        XCTAssertEqual(live.compactMap { if case .prediction(let p) = $0 { return p.outputTokens } else { return nil } }, [300],
                       "the half-written block was completed across the two reads")
        XCTAssertTrue(tail.poll().isEmpty)

        // A new day, a new file: the tail moves without re-reading the old one.
        try write(LMStudioLogFixtures.nativeV1, to: "2026-09/2026-09-11.1.log")
        let next = tail.poll()
        XCTAssertEqual(tail.file?.lastPathComponent, "2026-09-11.1.log")
        XCTAssertEqual(next.compactMap { if case .prediction(let p) = $0 { return p.outputTokens } else { return nil } }, [24])

        // Truncated and rewritten: read again from the start.
        try write(LMStudioLogFixtures.nativeV1, to: "2026-09/2026-09-11.1.log")
        XCTAssertTrue(tail.poll().isEmpty, "the same bytes are not new")
        try write("", to: "2026-09/2026-09-11.1.log")
        try append(LMStudioLogFixtures.openAIWithoutDrafts, to: "2026-09/2026-09-11.1.log")
        XCTAssertEqual(tail.poll().compactMap { if case .prediction(let p) = $0 { return p.outputTokens } else { return nil } }, [171])
    }
}
