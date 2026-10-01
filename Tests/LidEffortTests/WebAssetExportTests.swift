import XCTest
import SwiftUI
@testable import LidEffort
import LidEffortCore

/// The landing page's pictures, drawn by the app itself: each agent's mark
/// as an SVG, and the real pill and cards as PNGs. Runs only when asked —
/// `SPYX_WEB_ASSETS_DIR=<dir> swift test --filter WebAssetExportTests`.
@MainActor
final class WebAssetExportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SPYX_WEB_ASSETS_DIR"] else {
            throw XCTSkip("set SPYX_WEB_ASSETS_DIR to export the landing page's assets")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("glyphs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("ui"), withIntermediateDirectories: true)
    }

    func testExportGlyphs() throws {
        let glyphs: [(String, [[CGPoint]])] = [
            ("claude", GlyphOutline.claude), ("codex", GlyphOutline.openai), ("cursor", GlyphOutline.cursor),
            ("antigravity", GlyphOutline.antigravity), ("gemini", GlyphOutline.gemini), ("glm", GlyphOutline.glm),
            ("grok", GlyphOutline.grok), ("opencode", GlyphOutline.opencode), ("commandcode", GlyphOutline.commandcode),
            ("copilot", GlyphOutline.copilot), ("kimi", GlyphOutline.kimi), ("ollama", GlyphOutline.ollama),
            ("perplexity", GlyphOutline.third),
        ]
        for (name, loops) in glyphs {
            var d = ""
            for loop in loops where !loop.isEmpty {
                d += "M" + loop.map { String(format: "%.2f %.2f", $0.x * 100, $0.y * 100) }.joined(separator: "L") + "Z"
            }
            let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path fill="currentColor" fill-rule="evenodd" d="\#(d)"/></svg>"#
            try svg.write(to: dir.appendingPathComponent("glyphs/\(name).svg"), atomically: true, encoding: .utf8)
        }
    }

    func testExportUI() throws {
        let now = Date()
        let snapshots = TourDemo.snapshots(now: now)
        let claude = try XCTUnwrap(snapshots.first)
        let sessions = TourDemo.sessions(now: now)["claude"] ?? []
        let direction = NotchEdge.right.tooltipDirection
        func tooltip(_ focus: TooltipTourFocus?) -> some View {
            TooltipCard(snapshot: claude, activity: ActivitySummary(sessions: sessions), now: now, direction: direction,
                        effortValue: "high", effortDots: EffortDotState(count: 4, filled: 3), tourFocus: focus)
        }
        try write("pill", RealPill(agents: snapshots))
        try write("tooltip", tooltip(nil))
        try write("tooltip-limits", tooltip(.limits))
        try write("tooltip-sessions", tooltip(.sessions))
        try write("done", DoneToastView(toast: DoneToast(event: IntroTour.demoFinished(), glyph: .claude), direction: direction))
        for (name, prompt) in [("approval", IntroTour.demoApproval()), ("question", IntroTour.demoQuestion())] {
            let prompt = try XCTUnwrap(prompt)
            try write(name, PromptCard(prompt: prompt, draft: .constant(PromptDraft(questions: prompt.questions)),
                                       direction: direction, onAnswer: { _ in }))
        }
        for level in EffortLevel.allCases {
            let values = [(name: "Claude", value: level.description), (name: "Codex", value: level.description),
                          (name: "Grok", value: level.description)]
            try write("effort-\(level)", EffortChangeCard(event: EffortChangeEvent(level: level, values: values, at: now),
                                                         direction: direction))
        }
    }

    /// The question card through an answer, for the launch video: nothing
    /// picked, one option, another, then "Something else…" typed into a
    /// letter at a time — and the lines that confirm an answer.
    func testExportQuestionStates() throws {
        let folder = dir.appendingPathComponent("ui/question")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prompt = try XCTUnwrap(IntroTour.demoQuestion())
        let direction = NotchEdge.right.tooltipDirection
        func write(_ name: String, _ draft: PromptDraft) throws {
            try render(PromptCard(prompt: prompt, draft: .constant(draft), direction: direction, onAnswer: { _ in })
                .environment(\.drawsFieldsAsText, true), to: folder.appendingPathComponent("\(name).png"))
        }
        var draft = PromptDraft(questions: prompt.questions)
        try write("0-none", draft)
        draft.toggle("Postgres"); try write("1-postgres", draft)
        draft.toggle("SQLite"); try write("2-sqlite", draft)
        let context = "Postgres, keep SQLite for tests"
        var typed = ""
        draft.setCustom("\u{258F}"); try write("3-typed-00", draft)
        for (i, ch) in context.enumerated() {
            typed.append(ch)
            guard i % 2 == 1 || i == context.count - 1 else { continue }
            draft.setCustom(typed + "\u{258F}")
            try write(String(format: "3-typed-%02d", typed.count), draft)
        }
        draft.setCustom(typed); try write("4-done", draft)
        for (name, answer) in [("echo-sent", PromptAnswer.answers([:])), ("echo-allowed", .allow)] {
            try render(PromptEchoPill(echo: PromptEcho(answer: answer, prompt: prompt, origin: .card)),
                       to: dir.appendingPathComponent("ui/\(name).png"))
        }
    }

    /// The effort card while the lid moves: the bar following it
    /// continuously, low to max, the way the app shows it before the level
    /// settles — for a smooth rise in the launch video.
    func testExportEffortSweep() throws {
        let folder = dir.appendingPathComponent("ui/effort-live")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let levels = EffortLevel.allCases
        for step in 0...80 {
            let position = Double(step) / 20
            let level = levels[min(levels.count - 1, Int(position.rounded()))]
            let values = [(name: "Claude", value: level.description), (name: "Codex", value: level.description),
                          (name: "Grok", value: level.description)]
            try render(EffortChangeCard(event: EffortChangeEvent(level: level, values: values, at: Date()),
                                        direction: NotchEdge.right.tooltipDirection, livePosition: position),
                       to: folder.appendingPathComponent(String(format: "%03d.png", step)))
        }
    }

    private func render(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    /// The tour's own sounds as WAVs, for the launch video: every little
    /// sound, and the intro's rising drone.
    func testExportSounds() throws {
        let folder = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for sound in TourSounds.Sound.allCases {
            let samples = TourSounds.render(sound)
            try Self.wav(left: samples, right: samples).write(to: folder.appendingPathComponent("\(sound).wav"))
        }
        let drone = MeditationRise.render()
        try Self.wav(left: drone.left, right: drone.right).write(to: folder.appendingPathComponent("intro.wav"))
    }

    /// 16-bit stereo PCM at 44.1 kHz.
    static func wav(left: [Float], right: [Float]) -> Data {
        let frames = min(left.count, right.count)
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(44_100)); put(UInt32(44_100 * 4)); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for i in 0..<frames {
            put(Int16(max(-1, min(1, left[i])) * 32_767))
            put(Int16(max(-1, min(1, right[i])) * 32_767))
        }
        return data
    }

    /// Solid, black: the glass is an AppKit view an image renderer cannot
    /// draw. The page lays these over glass of its own and screens the
    /// black away, so the card's contents sit on the page's glass.
    private func write(_ name: String, _ view: some View) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.colorScheme, .dark))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage, name)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("ui/\(name).png"))
    }
}
