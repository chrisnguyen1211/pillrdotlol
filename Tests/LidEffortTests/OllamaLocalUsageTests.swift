import XCTest
@testable import LidEffort

final class OllamaMemoryTests: XCTestCase {
    func testGPUAndCPUAllocationRemainDistinctFromQuota() throws {
        let reading = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"gpu","size":8589934592,"size_vram":2147483648,"expires_at":"2026-09-08T18:06:07.541672-04:00"},{"name":"cpu","size":524288000,"size_vram":0}]}"#.utf8))
        let cpu = reading.models[0], gpu = reading.models[1]
        XCTAssertEqual(cpu.memoryLabel, "RAM")
        XCTAssertEqual(cpu.memoryText, "500 MB")
        XCTAssertEqual(gpu.memoryLabel, "VRAM")
        XCTAssertEqual(gpu.memoryBytes, 8589934592)
        XCTAssertEqual(gpu.gpuMemoryBytes, 2147483648)
        XCTAssertEqual(gpu.memoryText, "2 GB")
        XCTAssertNotNil(gpu.expiresAt)
        let snapshot = ProviderSnapshot(id: "ollama-local", displayName: "Ollama", glyph: .ollamaLocal,
                                        fidelity: .official, status: .ok, windows: [],
                                        kind: .localRuntime, localRuntime: reading)
        XCTAssertTrue(snapshot.notchSnapshots.allSatisfy { $0.usedFraction == nil && $0.windows.isEmpty })
    }

    func testUnloadTimeDoesNotInventAnExpirationOrReset() throws {
        let reading = try OllamaLocalUsage.parse(Data(#"{"models":[{"name":"unknown","size":0}]}"#.utf8))
        XCTAssertEqual(reading.models[0].unloadText(now: Date()), "Unavailable")
        XCTAssertEqual(reading.models[0].memoryLabel, "Memory")
        XCTAssertEqual(reading.models[0].memoryText, "0 B")
        let date = try XCTUnwrap(OllamaLocalUsage.parseISO8601("2026-09-08T19:00:00Z"))
        let model = LocalRuntimeReading.Model(name: "cpu", memoryBytes: nil, contextLength: nil,
                                              quantizationLevel: nil, expiresAt: date)
        XCTAssertEqual(model.unloadText(now: date), "Pending")
        XCTAssertFalse(model.unloadText(now: date.addingTimeInterval(-60)).isEmpty)
        XCTAssertNotNil(OllamaLocalUsage.parseISO8601("2026-09-08T18:06:07.541672-04:00"))
        XCTAssertNil(OllamaLocalUsage.parseISO8601("not-a-date"))
    }
}
