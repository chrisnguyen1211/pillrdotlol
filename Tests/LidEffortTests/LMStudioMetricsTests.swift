import XCTest
import Combine
@testable import LidEffort

/// A socket that answers from a script, so the monitor's folding of polls and
/// log lines can be driven without LM Studio.
@MainActor
final class LMStudioLinkStub: LMStudioCalling {
    var loaded: [[String: Any]] = []
    var states: [String: [String: Any]] = [:]
    var failure: Error?
    var calls: [String] = []
    var closed = 0

    func load(_ identifier: String, reference: String = "ref", type: String = "llm") {
        loaded.append(["type": type, "identifier": identifier, "instanceReference": reference, "modelKey": identifier])
    }

    func call(_ endpoint: String, parameter: Any?) async throws -> Any {
        calls.append(endpoint)
        if let failure { throw failure }
        switch endpoint {
        case "listLoaded":
            return loaded
        case "getInstanceProcessingState":
            let reference = ((parameter as? [String: Any])?["specifier"] as? [String: Any])?["instanceReference"] as? String ?? ""
            return states[reference] ?? ["status": "idle", "queued": 0]
        default:
            throw LMStudioLinkError.remote("Received rpcCall for unknown endpoint, endpoint = \(endpoint)")
        }
    }

    func close() async { closed += 1 }
}

@MainActor
final class LMStudioMetricsTests: XCTestCase {
    private var logs: URL!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        logs = FileManager.default.temporaryDirectory.appendingPathComponent("LMStudioMetricsTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("2026-09"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: logs)
    }

    private func metrics(link: LMStudioLinkStub, now: @escaping () -> Date = Date.init) -> LMStudioMetrics {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LMStudioLogFixtures.zone
        return LMStudioMetrics(makeLink: { _ in link }, logsDirectory: logs,
                               pollInterval: 0.03, inventoryInterval: 0.1, logInterval: 0.03,
                               now: now, calendar: calendar)
    }

    private func wait<T: Equatable>(for publisher: Published<T>.Publisher, _ description: String,
                                    until condition: @escaping (T) -> Bool) async {
        let expectation = expectation(description: description)
        var done = false
        publisher.sink { value in
            guard !done, condition(value) else { return }
            done = true
            expectation.fulfill()
        }.store(in: &cancellables)
        await fulfillment(of: [expectation], timeout: 3)
    }

    func testAPollBecomesActivityPhaseAndQueue() {
        let link = LMStudioLinkStub()
        let metrics = metrics(link: link)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let qwen = LMStudioLoadedInstance(identifier: "qwen", instanceReference: "a", type: "llm", modelKey: "qwen")
        let nomic = LMStudioLoadedInstance(identifier: "nomic", instanceReference: "b", type: "embedding", modelKey: "nomic")
        metrics.observe(instances: [qwen, nomic],
                        states: ["qwen": .init(status: .processingPrompt, queued: 1), "nomic": .init(status: .computingEmbedding, queued: 0)],
                        at: t0)
        let cell = LMStudioMetrics.cellID(instance: "qwen")
        XCTAssertEqual(metrics.activities, [cell: LocalModelActivity(phase: .processingPrompt, queued: 1, since: t0)],
                       "an embedding model is never a cell, so it is never busy either")
        XCTAssertTrue(metrics.isBusy)
        metrics.observe(instances: [qwen], states: ["qwen": .init(status: .processingPrompt, queued: 0)], at: t0.addingTimeInterval(1))
        XCTAssertEqual(metrics.activities[cell]?.since, t0, "the phase continues, so its start does")
        XCTAssertEqual(metrics.activities[cell]?.queued, 0)
        metrics.observe(instances: [qwen], states: ["qwen": .init(status: .generating, queued: 0)], at: t0.addingTimeInterval(2))
        XCTAssertEqual(metrics.activities[cell]?.phase, .generating)
        XCTAssertEqual(metrics.activities[cell]?.since, t0.addingTimeInterval(2))
        XCTAssertEqual(metrics.activities[cell]?.note, "Generating")
        metrics.observe(instances: [qwen], states: ["qwen": .init(status: .idle, queued: 0)], at: t0.addingTimeInterval(5))
        XCTAssertTrue(metrics.activities.isEmpty)
        XCTAssertFalse(metrics.isBusy)
        metrics.observe(instances: [qwen], states: [:], at: t0.addingTimeInterval(6))
        XCTAssertTrue(metrics.activities.isEmpty, "no state for an instance is no activity")
    }

    func testAnOpenAIResponseIsTimedByTheGeneratingPhaseItJustEnded() throws {
        let link = LMStudioLinkStub()
        var clock = LMStudioLogFixtures.date(2026, 9, 2, 16, 12, 20)
        let metrics = metrics(link: link, now: { clock })
        let qwen = LMStudioLoadedInstance(identifier: "flash-next-test", instanceReference: "a", type: "llm", modelKey: "qwen")
        metrics.observe(instances: [qwen], states: ["flash-next-test": .init(status: .processingPrompt, queued: 0)], at: clock)
        clock.addTimeInterval(1)
        metrics.observe(instances: [qwen], states: ["flash-next-test": .init(status: .generating, queued: 0)], at: clock)
        clock.addTimeInterval(4.275)
        metrics.observe(instances: [qwen], states: ["flash-next-test": .init(status: .idle, queued: 0)], at: clock)
        clock.addTimeInterval(0.5)

        var parser = LMStudioServerLog(timeZone: LMStudioLogFixtures.zone)
        let events = parser.append(Data(LMStudioLogFixtures.openAI.utf8))
        metrics.absorb(events, live: true)
        let cell = LMStudioMetrics.cellID(instance: "flash-next-test")
        let timed = try XCTUnwrap(metrics.performances[cell])
        XCTAssertTrue(timed.isApproximate)
        XCTAssertEqual(timed.outputTokens, 171)
        XCTAssertEqual(timed.tokensPerSecond, 40, accuracy: 0.01)
        XCTAssertEqual(timed.measuredAt, clock, "a live line is dated by when it was read")
        XCTAssertEqual(metrics.ledger.summary(for: cell, now: clock)?.today.requests, 1)
        XCTAssertEqual(metrics.ledger.summary(for: cell, now: clock)?.today.draftAcceptance ?? 0, 0.85, accuracy: 0.0001)

        // The interval is spent; a second untimed response cannot reuse it.
        metrics.absorb(events, live: true)
        XCTAssertEqual(metrics.performances[cell], timed)
        XCTAssertEqual(metrics.ledger.summary(for: cell, now: clock)?.today.requests, 2)

        // And one that ended long before the line was read is not its clock.
        clock.addTimeInterval(1)
        metrics.observe(instances: [qwen], states: ["flash-next-test": .init(status: .generating, queued: 0)], at: clock)
        clock.addTimeInterval(1)
        metrics.observe(instances: [qwen], states: ["flash-next-test": .init(status: .idle, queued: 0)], at: clock)
        clock.addTimeInterval(30)
        metrics.absorb(events, live: true)
        XCTAssertEqual(metrics.performances[cell], timed)
    }

    func testHistoryIsDatedByTheLogAndTheRuntimesOwnClockIsExact() throws {
        let link = LMStudioLinkStub()
        let metrics = metrics(link: link)
        var parser = LMStudioServerLog(timeZone: LMStudioLogFixtures.zone)
        let events = parser.append(Data((LMStudioLogFixtures.openAI + LMStudioLogFixtures.nativeV1 + LMStudioLogFixtures.nativeV0).utf8))
        metrics.absorb(events, live: false)
        let qwen = LMStudioMetrics.cellID(instance: "qwen3.8-27b")
        let flash = LMStudioMetrics.cellID(instance: "flash-next-test")
        XCTAssertNil(metrics.performances[flash], "history has no clock for an OpenAI response")
        let exact = try XCTUnwrap(metrics.performances[qwen])
        XCTAssertFalse(exact.isApproximate)
        XCTAssertEqual(exact.tokensPerSecond, 17.929, accuracy: 0.001, "the newest of the two native responses")
        XCTAssertEqual(exact.measuredAt, LMStudioLogFixtures.date(2026, 9, 10, 0, 35, 56))
        XCTAssertEqual(metrics.ledger.instances, [flash, qwen])
        let summary = try XCTUnwrap(metrics.ledger.summary(for: qwen, now: LMStudioLogFixtures.date(2026, 9, 10, 12, 0, 0)))
        XCTAssertEqual(summary.today.requests, 2)
        XCTAssertEqual(summary.today.inputTokens, 66 + 59)
        XCTAssertEqual(summary.today.outputTokens, 324)
        XCTAssertEqual(summary.last?.inputTokens, 66)
    }

    func testTheSocketIsPolledAndTheLogIsTailedWhileEnabled() async throws {
        let link = LMStudioLinkStub()
        link.load("qwen3.8-27b", reference: "ref-qwen")
        link.states["ref-qwen"] = ["status": "generating", "queued": 1]
        try Data(LMStudioLogFixtures.nativeV1.utf8).write(to: logs.appendingPathComponent("2026-09/2026-09-10.1.log"))
        let metrics = metrics(link: link)
        XCTAssertEqual(metrics.status, "Off")
        metrics.configure(enabled: true, endpoint: "http://127.0.0.1:1234")

        let cell = LMStudioMetrics.cellID(instance: "qwen3.8-27b")
        await wait(for: metrics.$activities, "generating") { $0[cell]?.phase == .generating && $0[cell]?.queued == 1 }
        XCTAssertTrue(metrics.linked)
        XCTAssertTrue(metrics.isBusy)
        XCTAssertEqual(metrics.status, "Connected · 1 loaded")
        await wait(for: metrics.$historyLoaded, "history") { $0 }
        XCTAssertEqual(metrics.ledger.instances, [cell])
        XCTAssertEqual(metrics.performances[cell]?.outputTokens, 24)

        // A line written now is read within a poll or two.
        let handle = try FileHandle(forWritingTo: logs.appendingPathComponent("2026-09/2026-09-10.1.log"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(LMStudioLogFixtures.nativeV0.utf8))
        try handle.close()
        await wait(for: metrics.$performances, "live speed") { $0[cell]?.outputTokens == 300 }

        link.states["ref-qwen"] = ["status": "idle", "queued": 0]
        await wait(for: metrics.$activities, "idle") { $0.isEmpty }
        XCTAssertFalse(metrics.isBusy)
        // The listing is written to LM Studio's own log on every call, so it is
        // asked far less often than the state, which is not.
        let listings = link.calls.filter { $0 == "listLoaded" }.count
        let states = link.calls.filter { $0 == "getInstanceProcessingState" }.count
        XCTAssertGreaterThan(states, listings * 2, "\(states) state calls against \(listings) listings")

        // The server going away clears activity and says so, without dropping
        // the ledger that was read from disk.
        link.failure = LMStudioLinkError.unauthorized("Invalid API token")
        await wait(for: metrics.$linked, "unlinked") { !$0 }
        XCTAssertEqual(metrics.status, "Invalid API token")
        XCTAssertFalse(metrics.ledger.isEmpty)

        metrics.configure(enabled: false, endpoint: "http://127.0.0.1:1234")
        XCTAssertEqual(metrics.status, "Off")
        XCTAssertTrue(metrics.activities.isEmpty)
        XCTAssertTrue(metrics.performances.isEmpty)
        XCTAssertTrue(metrics.ledger.isEmpty)
        // A poll already in flight may still land; after that, nothing more.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertGreaterThan(link.closed, 0)
        let calls = link.calls.count
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(link.calls.count, calls, "switched off means no more polling")
    }

    func testABadAddressNeverOpensASocket() {
        let link = LMStudioLinkStub()
        let metrics = metrics(link: link)
        metrics.configure(enabled: true, endpoint: "http://10.0.0.5:1234")
        XCTAssertTrue(metrics.status.contains("HTTP address on this Mac"))
        XCTAssertTrue(link.calls.isEmpty)
        metrics.stop()
        XCTAssertEqual(metrics.status, "Off")
    }

    func testLiveLMStudioWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PILLR_LMSTUDIO_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live LM Studio check")
        }
        // The whole history of this Mac's server log, timed: half a gigabyte
        // on the machine this was written on, and it must not take minutes.
        let started = Date()
        let tail = LMStudioLogTail(directory: LMStudioEndpoint.serverLogsDirectory())
        let history = tail.loadHistory()
        let elapsed = Date().timeIntervalSince(started)
        let logged = history.filter { if case .prediction = $0 { return true } else { return false } }.count
        print("LM Studio history: \(logged) responses in \(history.count) events, \(String(format: "%.1f", elapsed))s")
        XCTAssertLessThan(elapsed, 60)
        let endpoint = try LMStudioEndpoint.parse(LMStudioEndpoint.configuredAddress() ?? LMStudioEndpoint.defaultAddress)
        let provider = LMStudioLocalProvider(endpoint: endpoint)
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertTrue(snapshot.hasReading)
        let link = LMStudioLink(endpoint: endpoint, token: { LMStudioCredentials.load() })
        let loaded = LMStudioLoadedInstance.parse(try await link.call("listLoaded", parameter: nil))
        XCTAssertEqual(Set(loaded.filter(\.isLanguageModel).map(\.identifier)),
                       Set(snapshot.localRuntime?.models.map(\.name) ?? []),
                       "the socket and the REST listing name the same instances")
        for instance in loaded where instance.isLanguageModel {
            let state = LMStudioProcessingState(try await link.call("getInstanceProcessingState",
                parameter: LMStudioWire.processingStateParameter(instanceReference: instance.instanceReference)))
            XCTAssertNotNil(state, instance.identifier)
        }
        await link.close()
    }
}
