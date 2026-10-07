import XCTest
import SwiftUI
@testable import LidEffort
import LidEffortCore

/// The landing page's pictures, drawn by the app itself: each agent's mark
/// as an SVG, and the real pill and cards as PNGs. Runs only when asked —
/// `PILLR_WEB_ASSETS_DIR=<dir> swift test --filter WebAssetExportTests`.
@MainActor
final class WebAssetExportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["PILLR_WEB_ASSETS_DIR"] else {
            throw XCTSkip("set PILLR_WEB_ASSETS_DIR to export the landing page's assets")
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

    // MARK: - The launch video's API keys and Reply scenes

    /// The API keys cell's card, as the notch draws it on the right edge:
    /// several keys, each in its own provider's mark, with its own figures —
    /// and the key mark the cell's ring wears, white on clear.
    func testExportAPIKeys() throws {
        let now = Date()
        func key(_ id: String, _ name: String, _ glyph: ProviderGlyph, _ windows: [LimitWindow]) -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official, status: .ok,
                             windows: windows, headlineID: windows.first?.id)
        }
        let members = [
            key("apikey_openrouter-k00001", "OpenRouter · Work", .openrouter,
                APIReading.several([.balance(7.5, .money("USD")), .spend(3.2, .money("USD"), .month),
                                    .spend(41, .money("USD"), .total)])
                    .windows(providerName: "OpenRouter", currency: nil)),
            key("apikey_elevenlabs-k00002", "ElevenLabs · Voice", .elevenlabs,
                [APIReading.used(41_200, of: 100_000, .characters, resetsAt: nil)
                    .window(providerName: "ElevenLabs", currency: nil)]),
            key("apikey_deepseek-k00003", "DeepSeek · Chat", .deepseek,
                [APIReading.balance(86.4, .money("CNY")).window(providerName: "DeepSeek", currency: nil)]),
            key("apikey_groq-k00004", "Groq · Key 1", .groq,
                [APIReading.keyWorks(.requestsLeft(remaining: 998, limit: 1_000, today: true))
                    .window(providerName: "Groq", currency: nil)]),
        ]
        let group = APIKeyGroup.snapshot(members: members)
        try renderDark(TooltipCard(snapshot: group, now: now, direction: NotchEdge.right.tooltipDirection),
                       to: dir.appendingPathComponent("ui/apikeys-tooltip.png"))
        try renderDark(ProviderGlyphView(glyph: .apiKey, size: 100).foregroundStyle(.white),
                       to: dir.appendingPathComponent("glyphs/apikey.png"))
    }

    /// Reply, for the video: the idle session's row as the pointer finds it
    /// (the lift and the Reply button in place of its status), the reply
    /// capsule typed into a character or two at a time, and the card it
    /// becomes, its words arriving. The capsule's field is an AppKit text
    /// field the renderer cannot draw, so the field's line is laid out here
    /// from `OrbReplyView`'s own measures, its text as text — as
    /// `drawsFieldsAsText` does for the prompt card. The glass is the page's.
    func testExportReplyStates() throws {
        let folder = dir.appendingPathComponent("ui/reply")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let session = AgentSession(id: "claude.demo-3", name: "write-release-notes", detail: "Desktop", state: .idle,
                                   waitingFor: nil, since: now.addingTimeInterval(-40 * 60), processID: 990_003)
        let pad = CGFloat(8)

        // The row, as it is and as it is under the pointer.
        try renderDark(SessionRow(session: session, now: now)
                        .frame(width: NotchLayout.cardTextWidth).padding(pad),
                       to: folder.appendingPathComponent("row-idle.png"))
        let hovered = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.px(20)) {
                Text(session.name).foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                RowActionButton(symbol: "arrowshape.turn.up.left.fill", label: L10n.t("Reply")) {}
            }
            .font(Typography.cardBody)
            .lineLimit(1)
            SplitRow(leading: session.detail, trailing: ElapsedCopy.text(since: session.since, now: now),
                     leadingColor: Palette.textSecondary)
                .padding(.top, NotchLayout.sessionRowGap)
        }
        .frame(width: NotchLayout.cardTextWidth)
        // HoverLiftModifier, lifted.
        .background {
            RoundedRectangle(cornerRadius: Design.px(18), style: .continuous)
                .fill(Palette.textPrimary.opacity(0.09))
                .overlay(RoundedRectangle(cornerRadius: Design.px(18), style: .continuous)
                    .strokeBorder(Palette.textPrimary.opacity(0.1), lineWidth: 1))
                .padding(.horizontal, -Design.px(16))
                .padding(.vertical, -Design.px(10))
        }
        .padding(pad)
        try renderDark(hovered, to: folder.appendingPathComponent("row-hover.png"))

        // The capsule's line, typed into.
        let message = L10n.t("Add a test for the empty cart, then open a PR")
        let agent = ProviderGlyph.forSession(session)?.agentName ?? ""
        let placeholder = L10n.t("Reply to \(agent) · \(session.name)…")
        func field(_ typed: String, caret: Bool) -> some View {
            let ready = SessionCommander.oneLine(typed) != nil
            return HStack(spacing: 12) {
                ProviderGlyphView(glyph: .claude, size: 20).foregroundStyle(.primary.opacity(0.8))
                Group {
                    if typed.isEmpty {
                        Text(placeholder).foregroundStyle(Color(nsColor: .placeholderTextColor))
                    } else {
                        Text(typed + (caret ? "\u{258F}" : "")).foregroundStyle(.primary)
                    }
                }
                .font(.system(size: 16))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ready ? AnyShapeStyle(.background) : AnyShapeStyle(.tertiary))
                }
                .frame(width: 38, height: 38)
                .background(Circle().fill(ready ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)))
            }
            .padding(.leading, 20)
            .padding(.trailing, 11)
            .frame(width: 480, height: 60)
        }
        try renderDark(field("", caret: false), to: folder.appendingPathComponent("field-00.png"))
        var typed = ""
        // Every character, so the typing can be shown a key at a time.
        for ch in message {
            typed.append(ch)
            try renderDark(field(typed, caret: true), to: folder.appendingPathComponent(String(format: "field-%02d.png", typed.count)))
        }
        try renderDark(field(message, caret: false), to: folder.appendingPathComponent("field-done.png"))

        // The card it becomes: sent, the message word by word.
        let words = message.split(separator: " ").map(String.init)
        for shown in 0...words.count {
            let body = words.enumerated().reduce(Text("")) { line, item in
                line + Text(item.element + " ").foregroundColor(.primary.opacity(item.offset < shown ? 1 : 0))
            }
            let card = VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(Palette.ample).frame(width: 7, height: 7)
                    ProviderGlyphView(glyph: .claude, size: 14).foregroundStyle(.secondary)
                    Text(L10n.t("Sent to \(session.name)"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                body.font(.system(size: 13.5)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(width: 340, height: 118, alignment: .topLeading)
            try renderDark(card, to: folder.appendingPathComponent(String(format: "sent-%02d.png", shown)))
        }
    }

    /// Black, dark, at 3×, with the palette resolved for dark as well —
    /// its colours follow the drawing appearance, not the colour scheme.
    private func renderDark(_ view: some View, to url: URL) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark))
            renderer.scale = 3
            image = renderer.cgImage
        }
        let cg = try XCTUnwrap(image, url.lastPathComponent)
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url)
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
