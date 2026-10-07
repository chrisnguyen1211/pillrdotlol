import XCTest
@testable import LidEffort

/// The SDK socket's frames, checked against what LM Studio 0.4.24 accepted
/// and answered on 2026-09-10.
final class LMStudioWireTests: XCTestCase {
    func testATokenIsSentAsTheTwoHalvesLMStudioReadsItAs() {
        let frame = LMStudioWire.authFrame(token: "sk-lm-tL9sH4ED:MQZTWwaOsmlIEKL4EruT")
        XCTAssertEqual(frame["authVersion"] as? Int, 1)
        XCTAssertEqual(frame["clientIdentifier"] as? String, "tL9sH4ED")
        XCTAssertEqual(frame["clientPasskey"] as? String, "MQZTWwaOsmlIEKL4EruT")
    }

    func testWithoutATokenAFreshPairNamesTheConnection() {
        let frame = LMStudioWire.authFrame(token: nil, random: { "abcdefghijklmnopqrst" })
        XCTAssertEqual(frame["clientIdentifier"] as? String, "pillr-abcdefgh")
        XCTAssertEqual(frame["clientPasskey"] as? String, "abcdefghijklmnopqrst")
        let real = LMStudioWire.authFrame(token: nil)
        XCTAssertEqual((real["clientPasskey"] as? String)?.count, 20)
        XCTAssertNotEqual(LMStudioWire.randomKey(20), LMStudioWire.randomKey(20))
        XCTAssertTrue(LMStudioWire.randomKey(30).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    func testAMalformedTokenIsStillSentSoTheServerCanRefuseIt() {
        let frame = LMStudioWire.authFrame(token: "not-a-token")
        XCTAssertEqual(frame["clientIdentifier"] as? String, "pillr")
        XCTAssertEqual(frame["clientPasskey"] as? String, "not-a-token")
    }

    func testACallWithoutAParameterOmitsTheKey() throws {
        let bare = LMStudioWire.rpcCall(endpoint: "listLoaded", callId: 3)
        XCTAssertEqual(bare["type"] as? String, "rpcCall")
        XCTAssertEqual(bare["endpoint"] as? String, "listLoaded")
        XCTAssertEqual(bare["callId"] as? Int, 3)
        XCTAssertNil(bare["parameter"], "`parameter: {}` is refused as a type error; absence is what is expected")
        let state = LMStudioWire.rpcCall(endpoint: "getInstanceProcessingState", callId: 4,
                                         parameter: LMStudioWire.processingStateParameter(instanceReference: "qLvnx"))
        let parameter = try XCTUnwrap(state["parameter"] as? [String: Any])
        XCTAssertEqual(parameter["throwIfNotFound"] as? Bool, true)
        let specifier = try XCTUnwrap(parameter["specifier"] as? [String: String])
        XCTAssertEqual(specifier, ["type": "instanceReference", "instanceReference": "qLvnx"])
        let text = try LMStudioWire.encode(bare)
        XCTAssertTrue(text.contains("\"rpcCall\""))
    }

    func testInboundFramesAreToldApart() throws {
        guard case .authReply(let ok, let error) = try XCTUnwrap(LMStudioWire.decode(#"{"success":true}"#)) else { return XCTFail() }
        XCTAssertTrue(ok)
        XCTAssertNil(error)
        guard case .authReply(let refused, let why) = try XCTUnwrap(LMStudioWire.decode(
            #"{"success":false,"error":{"title":"Invalid API token"}}"#)) else { return XCTFail() }
        XCTAssertFalse(refused)
        XCTAssertEqual(why, "Invalid API token")
        guard case .rpcResult(let callId, let result) = try XCTUnwrap(LMStudioWire.decode(
            #"{"type":"rpcResult","callId":7,"result":{"status":"generating","queued":1}}"#)) else { return XCTFail() }
        XCTAssertEqual(callId, 7)
        XCTAssertEqual(LMStudioProcessingState(result), LMStudioProcessingState(status: .generating, queued: 1))
        guard case .rpcError(let failedId, let message) = try XCTUnwrap(LMStudioWire.decode(
            #"{"type":"rpcError","callId":8,"error":{"title":"Model not found"}}"#)) else { return XCTFail() }
        XCTAssertEqual(failedId, 8)
        XCTAssertEqual(message, "Model not found")
        guard case .warning(let warning) = try XCTUnwrap(LMStudioWire.decode(
            #"{"type":"communicationWarning","warning":"Received rpcCall for unknown endpoint, endpoint = nope","kind":"x"}"#))
        else { return XCTFail() }
        XCTAssertTrue(warning.contains("unknown endpoint"))
        guard case .other = try XCTUnwrap(LMStudioWire.decode(#"{"type":"channelSend","channelId":1}"#)) else { return XCTFail() }
        XCTAssertNil(LMStudioWire.decode("not json"))
    }

    func testProcessingStatesCoverWhatTheRuntimeReportsAndWhatItMight() {
        let cases: [(String, LMStudioProcessingState.Status, LocalModelActivity.Phase?)] = [
            ("idle", .idle, nil), ("processingPrompt", .processingPrompt, .processingPrompt),
            ("generating", .generating, .generating), ("computingEmbedding", .computingEmbedding, nil),
            ("loading", .other("loading"), nil)
        ]
        for (raw, status, phase) in cases {
            let state = LMStudioProcessingState(["status": raw, "queued": 2])
            XCTAssertEqual(state?.status, status, raw)
            XCTAssertEqual(state?.queued, 2)
            XCTAssertEqual(state?.phase, phase, raw)
        }
        XCTAssertEqual(LMStudioProcessingState(["status": "idle"])?.queued, 0)
        XCTAssertEqual(LMStudioProcessingState(["status": "idle", "queued": -4])?.queued, 0)
        XCTAssertNil(LMStudioProcessingState(["queued": 1]))
        XCTAssertNil(LMStudioProcessingState("idle"))
    }

    func testLoadedInstancesKeepTheHandleTheStateCallWants() {
        let listing: [[String: Any]] = [
            ["type": "llm", "modelKey": "qwen3.8-27b", "identifier": "qwen3.8-27b", "instanceReference": "qLvnxGuSv91EgRN71iAkb1fW",
             "sizeBytes": 31457991680, "contextLength": 262144, "ttlMs": NSNull()],
            ["type": "embedding", "modelKey": "nomic", "identifier": "nomic", "instanceReference": "abc"],
            ["type": "llm", "identifier": "", "instanceReference": "x"],
            ["type": "llm", "identifier": "no-reference"]
        ]
        let instances = LMStudioLoadedInstance.parse(listing)
        XCTAssertEqual(instances.map(\.identifier), ["qwen3.8-27b", "nomic"])
        XCTAssertEqual(instances.map(\.isLanguageModel), [true, false])
        XCTAssertEqual(instances[0].instanceReference, "qLvnxGuSv91EgRN71iAkb1fW")
        XCTAssertEqual(instances[0].modelKey, "qwen3.8-27b")
        XCTAssertTrue(LMStudioLoadedInstance.parse("nonsense").isEmpty)
    }
}
