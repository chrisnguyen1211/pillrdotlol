import XCTest
import SwiftUI
@testable import LidEffort

/// The effort card says what the lid is changing: which session, on which
/// model — or every agent's next sessions.
final class EffortAimTests: XCTestCase {
    func testModelsReadTheWayPeopleSayThem() {
        XCTAssertEqual(ModelName.pretty("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.pretty("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelName.pretty("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ModelName.pretty("claude-opus-5-5[1m]"), "Opus 5.5 · 1M")
        XCTAssertEqual(ModelName.pretty("opus[1m]"), "Opus · 1M")
        XCTAssertEqual(ModelName.pretty("minimax/MiniMax-M2.7-highspeed"), "MiniMax M2.7 Highspeed")
        XCTAssertEqual(ModelName.pretty("fable"), "Fable")
        XCTAssertEqual(ModelName.pretty("gpt-5.6-sol"), "GPT-5.6 Sol")
        XCTAssertEqual(ModelName.pretty("gpt-5.5"), "GPT-5.5")
        XCTAssertEqual(ModelName.pretty("grok-4.7"), "Grok 4.7")
        XCTAssertEqual(ModelName.pretty("o3"), "o3")
    }

    func testTheAimNamesSessionAndModel() {
        XCTAssertEqual(EffortAim(agent: "claude", session: "SPYX", model: "claude-opus-5-5").text, "SPYX · Opus 5.5")
        XCTAssertEqual(EffortAim(agent: "grok", session: "shop-redesign", model: nil).text, "shop-redesign")
    }

    @MainActor
    func testBothCardsRender() throws {
        let aimed = EffortChangeEvent(level: .high, values: [("Claude Code", "high")], at: Date(), forSession: true,
                                      note: "Let go of ⌘ to apply · Live → SPYX", noteIsLive: true, agent: "claude",
                                      aim: EffortAim(agent: "claude", session: "SPYX", model: "claude-opus-5-5"))
        let everyone = EffortChangeEvent(level: .high,
                                         values: [("Claude Code (Fable)", "high"), ("Codex (GPT-5.6 Sol)", "high"), ("Grok (Grok 4.7)", "high")],
                                         at: Date(), note: "No session in view · applies next session")
        let view = VStack(spacing: 16) {
            EffortChangeCard(event: aimed, direction: .leading)
            EffortChangeCard(event: everyone, direction: .leading)
        }
        .environment(\.notchSurfaceStyle, .solid)
        .padding(20).background(Color(red: 0.12, green: 0.13, blue: 0.2))
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("effort-aim.png"))
        }
    }
}
