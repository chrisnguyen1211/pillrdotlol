import XCTest
@testable import LidEffort

/// A prompt answered in the terminal or the Claude app instead of the notch.
///
/// Claude Code shows its own dialog while the hook runs and keeps whichever
/// answer comes first; when the dialog wins, the hook is not stopped, so its
/// connection stays open and the broker never hears that the prompt is over.
/// These are the signs the app reads instead.
final class PromptSettlementTests: XCTestCase {
    private let received = Date(timeIntervalSince1970: 1_800_000_000)

    private func bash(_ command: String = "npm test", at date: Date? = nil) throws -> PendingPrompt {
        let json = #"{"session_id":"s-1","cwd":"/Users/me/app","transcript_path":"/tmp/none.jsonl","tool_name":"Bash","tool_input":{"command":"\#(command)","description":"Run tests","timeout":120000}}"#
        return try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8), now: date ?? received))
    }

    private func question() throws -> PendingPrompt {
        try XCTUnwrap(PendingPrompt(hookInput: Data(PendingPromptTests.question.utf8), now: received))
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One transcript line, as Claude Code writes it.
    private func toolUse(_ id: String, _ name: String = "Bash", input: String = #"{"command":"npm test","description":"Run tests"}"#,
                         at date: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(Self.iso.string(from: date))","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func toolResult(_ id: String, at date: Date) -> String {
        #"{"type":"user","timestamp":"\#(Self.iso.string(from: date))","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"ok"}]}}"#
    }

    // MARK: The transcript

    func testATranscriptStillWaitingOnTheCallIsPending() throws {
        let prompt = try bash()
        let tail = toolUse("toolu_1", at: received.addingTimeInterval(-2))
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: nil, in: tail), .pending(toolUseID: "toolu_1"))
    }

    func testTheCallsResultAfterThePromptArrivedIsAnAnswer() throws {
        let prompt = try bash()
        let tail = [toolUse("toolu_1", at: received.addingTimeInterval(-2)),
                    toolResult("toolu_1", at: received.addingTimeInterval(8))].joined(separator: "\n")
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: nil, in: tail), .answered)
    }

    func testAnEarlierRunOfTheSameCommandIsNotTheAnswer() throws {
        // `npm test` ran and finished an hour ago; this prompt's own call is
        // not in the transcript yet.
        let prompt = try bash()
        let tail = [toolUse("toolu_old", at: received.addingTimeInterval(-3600)),
                    toolResult("toolu_old", at: received.addingTimeInterval(-3590))].joined(separator: "\n")
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: nil, in: tail), .unknown)
    }

    func testAnotherCommandsResultIsNotTheAnswer() throws {
        let prompt = try bash()
        let tail = [toolUse("toolu_1", at: received.addingTimeInterval(-2)),
                    toolUse("toolu_2", input: #"{"command":"ls"}"#, at: received.addingTimeInterval(-1)),
                    toolResult("toolu_2", at: received.addingTimeInterval(5))].joined(separator: "\n")
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: nil, in: tail), .pending(toolUseID: "toolu_1"))
    }

    func testAKnownCallIsAnsweredByItsResultAloneEvenWhenTheCallHasScrolledOut() throws {
        let prompt = try bash()
        // A long output pushed the call itself out of the tail read.
        let tail = #"t":"partial line of a huge result"}"# + "\n" + toolResult("toolu_1", at: received.addingTimeInterval(30))
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: "toolu_1", in: tail), .answered)
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: "toolu_9", in: tail), .pending(toolUseID: "toolu_9"))
    }

    func testAQuestionIsMatchedByWhatItAsks() throws {
        let prompt = try question()
        let input = #"{"questions":[{"question":"Which colour?","options":[{"label":"Red"}]},{"question":"Which sides?","options":[]}]}"#
        let other = #"{"questions":[{"question":"Which size?","options":[]}]}"#
        let tail = [toolUse("toolu_q", "AskUserQuestion", input: input, at: received.addingTimeInterval(-1)),
                    toolUse("toolu_x", "AskUserQuestion", input: other, at: received.addingTimeInterval(-1)),
                    toolResult("toolu_x", at: received.addingTimeInterval(3))].joined(separator: "\n")
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: nil, in: tail), .pending(toolUseID: "toolu_q"))
        let answered = tail + "\n" + toolResult("toolu_q", at: received.addingTimeInterval(9))
        XCTAssertEqual(PromptTranscript.find(prompt, knownToolUseID: nil, in: answered), .answered)
    }

    // MARK: The decision

    func testAPromptAnsweredInTheTerminalIsSettledByItsTranscript() throws {
        var settlement = PromptSettlement()
        let prompt = try bash()
        // While the dialog waits: the call, no result.
        XCTAssertFalse(settlement.isSettled(prompt, seeing: .init(
            processAlive: true, status: .unknown, transcriptTail: toolUse("toolu_1", at: received))))
        // Answered there: the command ran and its result is written.
        XCTAssertTrue(settlement.isSettled(prompt, seeing: .init(
            processAlive: true, status: .unknown, transcriptTail: toolResult("toolu_1", at: received.addingTimeInterval(4)))),
            "the call was remembered, so its result alone settles it")
    }

    func testASessionThatStopsWaitingSettlesThePrompt() throws {
        var settlement = PromptSettlement()
        let prompt = try bash()
        XCTAssertFalse(settlement.isSettled(prompt, seeing: .init(processAlive: true, status: .waiting)))
        XCTAssertFalse(settlement.isSettled(prompt, seeing: .init(processAlive: true, status: .waiting)))
        XCTAssertTrue(settlement.isSettled(prompt, seeing: .init(processAlive: true, status: .movedOn)))
    }

    func testABusySessionNotYetSeenWaitingDoesNotSettleIt() throws {
        // The hook can reach the app before Claude Code has written down that
        // its dialog is up: "busy" then is from before the prompt.
        var settlement = PromptSettlement()
        let prompt = try bash()
        XCTAssertFalse(settlement.isSettled(prompt, seeing: .init(processAlive: true, status: .movedOn)))
        XCTAssertFalse(settlement.isSettled(prompt, seeing: .init(processAlive: true, status: .waiting)))
        XCTAssertTrue(settlement.isSettled(prompt, seeing: .init(processAlive: true, status: .movedOn)))
    }

    func testASessionWhoseProcessIsGoneSettlesIt() throws {
        var settlement = PromptSettlement()
        XCTAssertTrue(settlement.isSettled(try bash(), seeing: .init(processAlive: false)))
    }

    func testNothingKnownSettlesNothing() throws {
        var settlement = PromptSettlement()
        let prompt = try bash()
        for _ in 0..<5 { XCTAssertFalse(settlement.isSettled(prompt, seeing: .init())) }
    }

    func testParallelPromptsAreSettledEachOnTheirOwn() throws {
        var settlement = PromptSettlement()
        let first = try bash("npm test")
        let second = try bash("swift build")
        let tail = [toolUse("toolu_a", at: received),
                    toolUse("toolu_b", input: #"{"command":"swift build"}"#, at: received),
                    toolResult("toolu_a", at: received.addingTimeInterval(3))].joined(separator: "\n")
        // The same session, both still on screen in the terminal: waiting.
        let seen = PromptSettlement.Observation(processAlive: true, status: .waiting, transcriptTail: tail)
        XCTAssertTrue(settlement.isSettled(first, seeing: seen))
        XCTAssertFalse(settlement.isSettled(second, seeing: seen))
    }

    // MARK: Reading what Claude Code wrote

    func testTheRegistryStatusIsRead() {
        XCTAssertEqual(PromptSettlement.status(record: ["status": "waiting", "waitingFor": "permission prompt"], sessionID: nil), .waiting)
        XCTAssertEqual(PromptSettlement.status(record: ["status": "busy"], sessionID: nil), .movedOn)
        XCTAssertEqual(PromptSettlement.status(record: ["status": "idle"], sessionID: nil), .movedOn)
        XCTAssertEqual(PromptSettlement.status(record: [:], sessionID: nil), .unknown,
                       "a record without a status says nothing")
        XCTAssertEqual(PromptSettlement.status(record: ["status": "busy", "sessionId": "other"], sessionID: "s-1"), .unknown,
                       "another session in the same process is not this prompt's")
    }

    func testTheLiveLookReadsTheRegistryAndTheTranscript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("settle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appendingPathComponent("t.jsonl")
        let pid = getpid()
        let json = #"{"session_id":"s-1","transcript_path":"\#(transcript.path)","tool_name":"Bash","tool_input":{"command":"npm test"}}"#
        var prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8), now: received))
        prompt.pid = pid
        let record = folder.appendingPathComponent("\(pid).json")

        var settlement = PromptSettlement(sessionsDirectory: folder)
        try #"{"pid":\#(pid),"sessionId":"s-1","status":"waiting","waitingFor":"permission prompt"}"#.write(to: record, atomically: true, encoding: .utf8)
        try toolUse("toolu_1", at: received).write(to: transcript, atomically: true, encoding: .utf8)
        var seen = settlement.observe(prompt)
        XCTAssertEqual(seen.processAlive, true)
        XCTAssertEqual(seen.status, .waiting)
        XCTAssertNotNil(seen.transcriptTail)
        XCTAssertFalse(settlement.isSettled(prompt, seeing: seen))

        // Unchanged since: not read again.
        XCTAssertNil(settlement.observe(prompt).transcriptTail)

        // Answered in the terminal: the session runs the command.
        try #"{"pid":\#(pid),"sessionId":"s-1","status":"busy"}"#.write(to: record, atomically: true, encoding: .utf8)
        seen = settlement.observe(prompt)
        XCTAssertTrue(settlement.isSettled(prompt, seeing: seen))
    }
}

@MainActor
final class PromptReleaseTests: XCTestCase {
    func testAReleasedPromptGoesWithoutAnAnswer() async throws {
        let path = "/tmp/lid-release-\(UUID().uuidString.prefix(8)).sock"
        let broker = PromptBroker(path: path, patience: 30)
        defer { broker.stop() }
        var received: PendingPrompt?
        var gone: UUID?
        broker.onPrompt = { received = $0; return nil }
        broker.onGone = { gone = $0 }
        try broker.start()
        let pending = Task.detached { PromptHookClient.exchange(Data(PendingPromptTests.bash.utf8), path: path) }
        for _ in 0..<100 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
        let prompt = try XCTUnwrap(received)
        broker.release(prompt.id)
        let reply = await pending.value
        XCTAssertEqual(reply, Data(), "no decision: whatever was answered elsewhere stands")
        for _ in 0..<100 where gone == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(gone, prompt.id)
        // A late click on the card it was answers nothing either.
        broker.answer(prompt.id, with: .allow)
    }
}
