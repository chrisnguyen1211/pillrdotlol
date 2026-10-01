import XCTest
import SwiftUI
@testable import LidEffort

final class OllamaPerformanceTests: XCTestCase {
    func testRateUsesOutputTokensAndGenerationTimeOnly() throws {
        let item: [String: Any] = ["done": true, "eval_count": 180, "eval_duration": 6_000_000_000,
            "prompt_eval_count": 10_000, "total_duration": 90_000_000_000, "load_duration": 20_000_000_000]
        let date = Date(timeIntervalSince1970: 123)
        let reading = try XCTUnwrap(LocalModelPerformance.parse(item, now: date))
        XCTAssertEqual(reading.tokensPerSecond, 30, accuracy: 0.0001)
        XCTAssertEqual(reading.outputTokens, 180)
        XCTAssertEqual(reading.generationSeconds, 6)
        XCTAssertEqual(reading.measuredAt, date)
        XCTAssertEqual(reading.band, .smooth)
    }

    func testMissingInvalidAndUnfinishedMetricsNeverBecomeZeroSpeed() {
        let valid: [String: Any] = ["done": true, "eval_count": 100, "eval_duration": 1_000_000_000]
        for value: Any in [0, -1, true, 0.5, "100", NSNull(), Double.infinity] {
            for key in ["eval_count", "eval_duration"] {
                var item = valid; item[key] = value
                XCTAssertNil(LocalModelPerformance.parse(item), "\(key): \(value)")
            }
        }
        for key in ["done", "eval_count", "eval_duration"] {
            var item = valid; item.removeValue(forKey: key)
            XCTAssertNil(LocalModelPerformance.parse(item))
        }
        var unfinished = valid; unfinished["done"] = false
        XCTAssertNil(LocalModelPerformance.parse(unfinished))
        var failed = valid; failed["error"] = "failed"
        XCTAssertNil(LocalModelPerformance.parse(failed))
    }

    func testSpeedBandsKeepTheirExactThresholds() throws {
        let cases: [(Int, LocalModelPerformance.Band)] = [(1, .verySlow), (9, .verySlow),
            (10, .slow), (19, .slow), (20, .smooth), (39, .smooth), (40, .veryFast), (100, .veryFast)]
        for (tokens, band) in cases {
            let reading = try XCTUnwrap(LocalModelPerformance(outputTokens: tokens, durationNanoseconds: 1_000_000_000))
            XCTAssertEqual(reading.band, band)
        }
    }

    func testFragmentedCompletionCountsTokensInsteadOfNetworkChunks() throws {
        var parser = OllamaThinkingStream(path: "/api/chat", body: Data(#"{"model":"qwen3"}"#.utf8))
        let payload = #"{"message":{"thinking":"reasoning"}}"# + "\n"
            + #"{"message":{"content":"answer"}}"# + "\n"
            + #"{"model":"qwen3:latest","done":true,"eval_count":180,"eval_duration":6000000000}"# + "\n"
        for byte in payload.utf8 { _ = parser.append(Data([byte])) }
        let reading = try XCTUnwrap(parser.takePerformance())
        XCTAssertEqual(reading.tokensPerSecond, 30)
        XCTAssertEqual(reading.outputTokens, 180)
        XCTAssertEqual(parser.model, "qwen3:latest")
        XCTAssertFalse(parser.isThinking)
        XCTAssertNil(parser.takePerformance(), "A final chunk is published only once")
    }

    func testNonStreamingMetricsWaitForEndAndNeverFlashThinking() throws {
        var parser = OllamaThinkingStream(path: "/api/generate", body: Data(#"{"model":"gemma4:e4b","stream":false}"#.utf8))
        let payload = "{\n\"thinking\":\"finished\",\"response\":\"4\",\"done\":true,\"eval_count\":100,\"eval_duration\":2000000000\n}"
        XCTAssertTrue(parser.append(Data(payload.utf8)).isEmpty)
        XCTAssertFalse(parser.isThinking)
        XCTAssertNil(parser.takePerformance())
        parser.finish()
        XCTAssertEqual(try XCTUnwrap(parser.takePerformance()).tokensPerSecond, 50)
        XCTAssertFalse(parser.isThinking)
    }

    func testIncompleteRequestsAndOpenAIUsageCannotInventNativeGenerationTime() {
        var interrupted = OllamaThinkingStream(path: "/api/generate", body: Data(#"{"model":"qwen3"}"#.utf8))
        _ = interrupted.append(Data((#"{"thinking":"pending"}"# + "\n").utf8))
        interrupted.finish()
        XCTAssertNil(interrupted.takePerformance())
        var openAI = OllamaThinkingStream(path: "/v1/chat/completions", body: Data(#"{"model":"qwen3","stream":true}"#.utf8))
        _ = openAI.append(Data(("data: " + #"{"choices":[],"usage":{"completion_tokens":100}}"# + "\n\ndata: [DONE]\n\n").utf8))
        XCTAssertNil(openAI.takePerformance())
    }
}

@MainActor
final class OllamaPerformanceViewTests: XCTestCase {
    func testLatestResponseSurvivesPollingAndRemainsScopedToItsModel() throws {
        let relay = OllamaActivityRelay()
        let new = try XCTUnwrap(LocalModelPerformance(outputTokens: 60, durationNanoseconds: 1_000_000_000,
                                                     measuredAt: Date(timeIntervalSince1970: 20)))
        let old = try XCTUnwrap(LocalModelPerformance(outputTokens: 5, durationNanoseconds: 1_000_000_000,
                                                     measuredAt: Date(timeIntervalSince1970: 10)))
        relay.recordPerformance(new, model: "qwen3")
        relay.recordPerformance(old, model: "qwen3:latest")
        XCTAssertEqual(relay.performances["qwen3:latest"], new)
        let vm = NotchViewModel()
        vm.setLocalMetricsEnabled(true)
        let runtime = try runtime(names: ["qwen3:latest", "gemma4:e4b"])
        let cloud = Fixtures.snapshots()[0]
        vm.updateSnapshots([cloud, runtime])
        vm.hoveredIndex = 2
        let hoveredID = vm.hoveredSnapshot?.id
        vm.updatePerformances(relay.performances)
        XCTAssertEqual(vm.hoveredSnapshot?.id, hoveredID)
        XCTAssertEqual(vm.snapshots.first { $0.localModel?.name == "qwen3:latest" }?.localPerformance, new)
        XCTAssertNil(vm.snapshots.first { $0.localModel?.name == "gemma4:e4b" }?.localPerformance)
        XCTAssertEqual(vm.snapshots[0], cloud)
        vm.updateSnapshots([cloud, runtime])
        XCTAssertEqual(vm.snapshots.last?.localPerformance, new)
        relay.configure(enabled: false, endpoint: OllamaEndpoint.defaultAddress)
        vm.updatePerformances(relay.performances)
        XCTAssertTrue(vm.snapshots.allSatisfy { $0.localPerformance == nil })
        XCTAssertEqual(vm.snapshots.last?.headlineText, "— tok/s")
    }

    func testDisabledCaptureShowsMemoryAndClearsPreviousResponse() throws {
        let vm = NotchViewModel()
        vm.updateSnapshots([try runtime(names: ["qwen3:latest"])])
        let cell = try XCTUnwrap(vm.snapshots.first)
        XCTAssertEqual(cell.headlineText, expectedGigabytes(4.5))
        XCTAssertFalse(cell.showsLocalPerformance)
        XCTAssertNil(vm.activity(for: cell), "Residency alone does not establish thinking")
        vm.setLocalMetricsEnabled(true)
        let measurement = try XCTUnwrap(LocalModelPerformance(outputTokens: 30, durationNanoseconds: 1_000_000_000))
        XCTAssertEqual(measurement.fidelity, .derived)
        vm.updatePerformances(["qwen3:latest": measurement])
        vm.thinkingModels = ["qwen3:latest": Date()]
        XCTAssertEqual(vm.snapshots[0].headlineText, "30 tok/s")
        XCTAssertNotNil(vm.activity(for: vm.snapshots[0]))
        vm.setLocalMetricsEnabled(false)
        XCTAssertEqual(vm.snapshots[0].headlineText, expectedGigabytes(4.5))
        XCTAssertNil(vm.snapshots[0].localPerformance)
        XCTAssertNil(vm.activity(for: vm.snapshots[0]))
        vm.setLocalMetricsEnabled(true)
        XCTAssertEqual(vm.snapshots[0].headlineText, "— tok/s")
    }

    func testSpeedLabelsFitTheExistingCellAndColorHasTextMeaning() throws {
        let cases: [(Int, Int64)] = [(1, 100_000_000_000), (1, 1_000_000_000),
            (102, 10_000_000_000), (999, 10_000_000_000), (241, 1_000_000_000),
            (999, 1_000_000_000), (1234, 1_000_000_000), (987654, 1_000_000_000), (Int.max, 1)]
        var readings: [LocalModelPerformance?] = [nil]
        readings += try cases.map { tokens, duration in
            try XCTUnwrap(LocalModelPerformance(outputTokens: tokens, durationNanoseconds: duration))
        }
        let canvasWidth: CGFloat = 140
        let scale: CGFloat = 2
        for (index, reading) in readings.enumerated() {
            var snapshot = try XCTUnwrap(runtime(names: ["qwen3:32b"]).notchSnapshots.first)
            snapshot.localPerformance = reading
            snapshot.showsLocalPerformance = true
            let renderer = ImageRenderer(content: ProviderCell(snapshot: snapshot).frame(width: canvasWidth))
            renderer.scale = scale
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let labelTop = Int(ceil((NotchLayout.ringDiameter + NotchLayout.ringLabelGap) * scale))
            var columns: [Int] = []
            for x in 0..<bitmap.pixelsWide {
                if (labelTop..<bitmap.pixelsHigh).contains(where: { y in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1
                }) { columns.append(x) }
            }
            let left = try XCTUnwrap(columns.first, "The reading must remain visible")
            let right = try XCTUnwrap(columns.last)
            let inset = (canvasWidth - NotchLayout.ringDiameter) / 2 * scale
            XCTAssertGreaterThanOrEqual(CGFloat(left), inset - 1, snapshot.headlineText)
            XCTAssertLessThanOrEqual(CGFloat(right), (canvasWidth * scale) - inset + 1, snapshot.headlineText)
            if let reading { XCTAssertFalse(reading.band.label.isEmpty) }
            try save(NSImage(cgImage: image, size: .zero), name: "speed-label-\(index).png")
        }
    }

    func testAllSpeedBandsAndThinkingRenderOnAllFourEdges() throws {
        let names = ["deepseek-r1:1.5b", "gemma4:e4b", "llama3.2:1b", "ministral-3:3b", "qwen3:0.6b"]
        let vm = NotchViewModel()
        vm.setLocalMetricsEnabled(true)
        vm.updateSnapshots([Fixtures.snapshots()[0], try runtime(names: names)])
        let speeds = [999, 30, 15, 5]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        vm.now = date.addingTimeInterval(120)
        vm.updatePerformances(Dictionary(uniqueKeysWithValues: zip(names, speeds).map { name, speed in
            (name, LocalModelPerformance(outputTokens: speed, durationNanoseconds: 1_000_000_000, measuredAt: date)!)
        }))
        vm.thinkingModels = [names[0]: date]
        vm.isExpanded = true
        vm.screenSize = CGSize(width: 1512, height: 982)
        for notchSize in NotchSize.allCases {
            vm.sizeScale = notchSize.scale
            for edge in NotchEdge.allCases {
                vm.edge = edge
                vm.hoveredIndex = 1
                let size = vm.panelSize
                XCTAssertLessThanOrEqual(size.height, vm.screenSize.height + 0.1, "\(edge) \(notchSize)")
                let renderer = ImageRenderer(content: NotchRootView(model: vm).frame(width: size.width, height: size.height))
                renderer.scale = 2
                try save(XCTUnwrap(renderer.nsImage), name: "speed-notch-\(edge.rawValue)-\(notchSize.rawValue).png")
                for cell in vm.snapshots.dropFirst() {
                    let height = NotchLayout.cardHeight(windowCount: 0, localModelName: cell.localModel?.name, showsLocalPerformance: cell.showsLocalPerformance)
                    XCTAssertLessThanOrEqual(height, vm.maxCardHeight(cellCount: vm.snapshots.count))
                    let card = ImageRenderer(content: TooltipCard(snapshot: cell, activity: vm.activity(for: cell),
                        now: vm.now, direction: edge.tooltipDirection))
                    card.scale = 2
                    try save(XCTUnwrap(card.nsImage), name: "speed-card-\(cell.localModel!.brand!.rawValue)-\(edge.rawValue).png")
                }
            }
        }
    }

    private func runtime(names: [String]) throws -> ProviderSnapshot {
        let data = try JSONSerialization.data(withJSONObject: ["models": names.map {
            ["name": $0, "size": 4_831_838_208, "context_length": 2048,
             "details": $0.hasPrefix("qwen") ? [:]
                : ["quantization_level": $0.hasPrefix("llama") ? "Q8_0" : "Q4_K_M"]] as [String: Any]
        }])
        return ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollama, fidelity: .official,
            status: .ok, windows: [], kind: .localRuntime, localRuntime: try OllamaLocalUsage.parse(data))
    }

    private func save(_ image: NSImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OLLAMA_SPEED_RENDER_DIRECTORY"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
