import XCTest
import SwiftUI
@testable import LidEffort

/// Renders the effort marks, the tooltip row and the change card. A smoke
/// test that they lay out, and a way to look at them: set `EFFORT_RENDER_DIR`
/// (or `TEST_RUNNER_EFFORT_RENDER_DIR` through xcodebuild) and each frame is
/// written there as a PNG.
@MainActor
final class EffortRenderTests: XCTestCase {
    private func snapshot(_ id: String, _ name: String, _ glyph: ProviderGlyph, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official, status: .ok,
                         windows: [LimitWindow(id: "session", label: "Session", usedFraction: used)])
    }

    private func write(_ image: NSImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] else { return }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private func render<V: View>(_ view: V) throws -> NSImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 3
        return try XCTUnwrap(renderer.nsImage)
    }

    func testCellsCarryTheEffortMarksOnlyWhereTheLidDrives() throws {
        let cells = HStack(spacing: NotchLayout.cellSpacing) {
            ProviderCell(snapshot: snapshot("claude", "Claude", .claude, used: 0.73), effortDots: EffortDotState(count: 4, filled: 3))
            ProviderCell(snapshot: snapshot("codex", "Codex", .openai, used: 0.21), effortDots: EffortDotState(count: 6, filled: 6))
            ProviderCell(snapshot: snapshot("grok", "Grok", .grok, used: 0.52), effortDots: EffortDotState(count: 6, filled: 2))
        }
        .padding(40)
        .background(Palette.notch)

        let image = try render(cells)
        XCTAssertGreaterThan(image.size.height, NotchLayout.cellExtent)
        try write(image, "cells.png")
    }

    func testTooltipCarriesTheEffortRow() throws {
        let activity = ActivitySummary(sessions: [
            AgentSession(id: "a", name: "effort-lid-3c", detail: "Terminal · Effort Lid",
                         state: .busy, waitingFor: nil, since: Date().addingTimeInterval(-90))
        ])
        let withRow = TooltipCard(snapshot: snapshot("claude", "Claude", .claude, used: 0.47),
                                  activity: activity, now: Date(), effortValue: "xhigh",
                                  effortDots: EffortDotState(count: 4, filled: 4))
            .padding(20).background(Color.black)
        let without = TooltipCard(snapshot: snapshot("claude", "Claude", .claude, used: 0.47),
                                  activity: activity, now: Date())
            .padding(20).background(Color.black)

        let tall = try render(withRow)
        let short = try render(without)
        // The row is budgeted, not measured: the card must grow by exactly
        // what `NotchLayout.cardHeight(effortRow:)` reserves, or the hover
        // region and the drawn card disagree.
        let expected = NotchLayout.headerToBlock + NotchLayout.cardBodyLineHeight
            + 2 * NotchLayout.effortWellPadding
        XCTAssertEqual(tall.size.height - short.size.height, expected, accuracy: 3,
                       "tall \(tall.size.height) vs short \(short.size.height)")
        try write(tall, "tooltip.png")
    }

    func testChangeCardLaysOut() throws {
        let event = EffortChangeEvent(level: .high, values: [("Claude Code", "high"), ("Codex", "high"), ("Grok", "high")], at: Date())
        let card = VStack(spacing: 12) {
            EffortChangeCard(event: event, direction: .leading)
            // Live: the lid is a third of the way from high to max.
            EffortChangeCard(event: event, direction: .leading, livePosition: 3.35)
            EffortChangeCard(event: EffortChangeEvent(level: .max, values: [("Codex", "ultra")], at: Date()),
                             direction: .leading)
            EffortChangeCard(event: EffortChangeEvent(level: .high, values: [], at: Date(), isHint: true),
                             direction: .leading)
            EffortChangeCard(event: EffortChangeEvent(level: .high, values: [("Claude Code", "high"), ("Codex", "high")],
                                                      at: Date(), note: "Claude · applies next session"),
                             direction: .leading)
        }
        .padding(20).background(Color.black)
        let image = try render(card)
        XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)
        try write(image, "card.png")
    }

    /// The card as it came up for a session with no terminal in view: four
    /// agents' values and the amber note. Its height is measured from those,
    /// so the note is inside the card rather than under its edge.
    func testTheNoteIsNeverClipped() throws {
        let values: [(name: String, value: String)] = [("Claude Code", "medium"), ("Codex", "medium"),
                                                       ("Grok", "medium"), ("Gemini", "medium")]
        let bare = EffortChangeEvent(level: .medium, values: values, at: Date())
        let noted = EffortChangeEvent(level: .medium, values: values, at: Date(),
                                      note: "No session in view · applies next session")
        XCTAssertGreaterThanOrEqual(EffortChangeCard.cardHeight(for: noted) - EffortChangeCard.cardHeight(for: bare),
                                    NotchLayout.cardBodyLineHeight, "the note gets a line of its own")
        let card = VStack(spacing: 12) {
            EffortChangeCard(event: noted, direction: .leading)
            EffortChangeCard(event: bare, direction: .leading)
        }
        .padding(20).background(Color.black)
        try write(try render(card), "card-note.png")
    }

    func testTheAppNotesRead() throws {
        // What the card says in the Claude and Codex apps, where a change
        // that waits must not look like one that failed.
        let session = "Fix the lid effort card on Desktop"
        let events = [
            EffortChangeEvent(level: .high, values: [("Claude Code", "high")], at: Date(), forSession: true,
                              note: EffortNotes.claudeApp(nil, session: session).text),
            EffortChangeEvent(level: .high, values: [("Claude Code", "high")], at: Date(), forSession: true,
                              note: EffortNotes.claudeApp(.draft, session: session).text),
            EffortChangeEvent(level: .high, values: [("Claude Code", "high")], at: Date(), forSession: true,
                              note: EffortNotes.delivered(to: session), noteIsLive: true),
            EffortChangeEvent(level: .high, values: [("Codex", "high")], at: Date(),
                              note: EffortNotes.codex(frontBundleID: EffortNotes.codexBundleID, cliInView: false, value: "high")!.text),
        ]
        let cards = VStack(spacing: 12) {
            ForEach(events) { EffortChangeCard(event: $0, direction: .leading) }
        }
        .padding(20).background(Color.black)
        try write(try render(cards), "card-app-notes.png")
    }

    func testTheBarFitsTheTooltipsLine() throws {
        // The row is budgeted at one body line; the knob is the tallest
        // thing in it and must fit inside that.
        XCTAssertLessThanOrEqual(NotchLayout.effortBarKnob, NotchLayout.cardBodyLineHeight)
        let bars = VStack(spacing: 16) {
            EffortBar(count: 5, position: 0).frame(width: 400)
            EffortBar(count: 5, position: 2.5).frame(width: 400)
            EffortBar(count: 6, position: 5).frame(width: 400)
            EffortRow(value: "ultra", dots: EffortDotState(count: 6, filled: 6)).frame(width: 520)
        }
        .padding(20).background(Color.black)
        try write(try render(bars), "effort-bars.png")
    }
    func testEveryResetCheerFitsTheCard() throws {
        // One card per line, found by walking reset times until every index
        // has come up, so the PNG shows each cheer at the card's real width.
        let count = ResetCheer.lines(provider: "Claude", window: "Current session").count
        var events: [Int: UsageResetEvent] = [:]
        var at = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<(count * 16) where events.count < count {
            let event = UsageResetEvent(providerID: "claude", providerName: "Claude",
                                        windowLabel: "Current session", glyph: .claude,
                                        previousFraction: 0.91, currentFraction: 0.0, resetsAt: at)
            events[ResetCheer.index(for: event, count: count)] = event
            at.addTimeInterval(5 * 3600)
        }
        // A five-hour cadence has to reach every line within a few weeks of
        // resets, or someone hears the same two cheers forever.
        XCTAssertEqual(events.count, count, "lines reached: \(events.keys.sorted())")
        let cards = VStack(spacing: 12) {
            ForEach(events.keys.sorted(), id: \.self) { index in
                UsageResetCard(event: events[index]!, direction: .leading, onDismiss: {})
            }
        }
        .padding(20).background(Color.black)
        let image = try render(cards)
        XCTAssertGreaterThan(image.size.height, UsageResetCard.cardHeight * CGFloat(count))
        try write(image, "reset-cards.png")
    }

    func testTheWholeNotchRendersAsAPillWithEndOrbs() throws {
        let model = NotchViewModel()
        model.updateSnapshots([
            snapshot("claude", "Claude", .claude, used: 0.73),
            snapshot("codex", "Codex", .openai, used: 0.21),
            snapshot("grok", "Grok", .grok, used: 0.52),
        ])
        var effort = EffortState()
        effort.values = ["claude": "high", "codex": "ultra", "grok": "medium"]
        effort.scales = ["claude": ["low", "medium", "high", "xhigh"],
                         "codex": ["low", "medium", "high", "xhigh", "max", "ultra"],
                         "grok": ["minimal", "low", "medium", "high", "xhigh", "max"]]
        model.effort = effort
        model.isExpanded = true
        // Glass has nothing to refract offscreen; solid shows the shape.
        model.surfaceStyle = .solid
        let size = model.panelSize
        let view = NotchRootView(model: model)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.55))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, image.size.width)
        try write(image, "notch.png")
    }
}

/// The API keys cell in the pill, and its card, in both appearances.
@MainActor
final class APIKeysRenderTests: XCTestCase {
    private func write(_ image: NSImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] else { return }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// Drawn under the appearance asked for: the palette's colours resolve
    /// against the drawing appearance, not the SwiftUI colour scheme.
    private func render<V: View>(_ view: V, dark: Bool, scale: CGFloat = 2) throws -> NSImage {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = scale
            image = renderer.nsImage
        }
        return try XCTUnwrap(image)
    }

    /// Drawn by AppKit in an offscreen window, as Settings' renders are:
    /// the glass card needs a window to draw into.
    private func windowSnapshot(_ view: some View, size: CGSize, name: String, dark: Bool) throws {
        let background = dark ? Color(white: 0.16) : Color(white: 0.93)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .background(background)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] else { return }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    static func keys(now: Date) -> [ProviderSnapshot] {
        func key(_ id: String, _ name: String, _ glyph: ProviderGlyph, _ windows: [LimitWindow],
                 status: ProviderStatus = .ok) -> ProviderSnapshot {
            ProviderSnapshot(id: id, displayName: name, glyph: glyph, fidelity: .official, status: status,
                             windows: windows, headlineID: windows.first?.id)
        }
        let several = APIReading.several([.balance(7.5, .money("USD")), .spend(3.2, .money("USD"), .month),
                                          .spend(41, .money("USD"), .total)])
        let glmKey = ProviderGlyph.forProvider("glm") ?? .apiKey
        return [
            key("apikey_openrouter-k00001", "OpenRouter · Work", APICatalog.entry(id: "openrouter")?.glyph ?? .apiKey,
                several.windows(providerName: "OpenRouter", currency: nil)),
            key("glm", "GLM", glmKey, [
                LimitWindow(id: "five-hour", label: "5-hour", usedFraction: 0.82, resetsAt: now.addingTimeInterval(2 * 3600)),
                LimitWindow(id: "weekly", label: "Weekly", usedFraction: 0.41, resetsAt: now.addingTimeInterval(4 * 86400)),
            ]),
            key("apikey_elevenlabs-k00003", "ElevenLabs · Voice", APICatalog.entry(id: "elevenlabs")?.glyph ?? .apiKey,
                [APIReading.used(3200, of: 10000, .characters, resetsAt: nil).window(providerName: "ElevenLabs", currency: nil)]),
            key("apikey_groq-k00004", "Groq · Key 1", APICatalog.entry(id: "groq")?.glyph ?? .apiKey,
                [APIReading.keyWorks(.requestsLeft(remaining: 14399, limit: 14400, today: true))
                    .window(providerName: "Groq", currency: nil)],
                status: .stale(since: now.addingTimeInterval(-7 * 60))),
            key("apikey_openai-k00005", "OpenAI · Org", .openai, [], status: .needsAuth),
        ]
    }

    func testTheCellAndItsCardDraw() throws {
        let now = Date()
        let group = APIKeyGroup.snapshot(members: Self.keys(now: now))
        XCTAssertEqual(group.usedFraction, 0.82, "the GLM key's five hours are closest to running out")
        XCTAssertTrue(group.status.isStale, "the refused OpenAI key dims the cell")

        // The whole notch, the cell among the agents, its card open.
        let model = NotchViewModel()
        model.updateSnapshots([
            ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.31)]),
            group,
            ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.12)]),
        ])
        model.now = now
        model.isExpanded = true
        model.surfaceStyle = .solid
        model.hoveredIndex = 1
        let size = model.panelSize
        let notch = NotchRootView(model: model)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.55))
        try write(try render(notch, dark: true), "notch-apikeys.png")

        let plan = NotchLayout.keyGroupPlan(group.keyGroup!)
        let budgeted = NotchLayout.cardHeight(windowCount: 1, keyGroupBody: plan.body)
        let solid = try render(TooltipCard(snapshot: group, now: now).padding(20).background(Color(white: 0.16))
            .environment(\.notchSurfaceStyle, .solid), dark: true)
        XCTAssertEqual(solid.size.height - 40, budgeted, accuracy: 3, "the card is as tall as it was budgeted")
        try write(solid, "apikeys-tooltip-dark.png")

        // Light is the glass style's, which only a real window draws.
        try windowSnapshot(TooltipCard(snapshot: group, now: now)
                            .padding(20)
                            .environment(\.notchSurfaceStyle, .glass)
                            // Nothing behind an offscreen window to see:
                            // the card's own frosted tint.
                            .environment(\.cardGlassSeesBehind, false),
                           size: CGSize(width: NotchLayout.cardWidth + NotchLayout.tailLength + 40, height: budgeted + 40),
                           name: "apikeys-tooltip-light.png", dark: false)

        // A list longer than the card, cut short and counted.
        let many = (0..<14).map { i in
            ProviderSnapshot(id: "apikey_openrouter-k\(String(format: "%05x", i))", displayName: "OpenRouter · Key \(i + 1)",
                             glyph: .apiKey, fidelity: .official, status: .ok,
                             windows: [APIReading.left(Double(20 - i), of: 20, .money("USD"), resetsAt: nil)
                                .window(providerName: "OpenRouter", currency: nil)])
        }
        let long = TooltipCard(snapshot: APIKeyGroup.snapshot(members: many), now: now)
            .padding(20).background(Color(white: 0.16))
            .environment(\.notchSurfaceStyle, .solid)
        let image = try render(long, dark: true)
        XCTAssertLessThanOrEqual(image.size.height - 40, NotchLayout.defaultMaxCardHeight + 1)
        try write(image, "apikeys-tooltip-long.png")
    }

    /// No key yet: the cell is there anyway, and its card says what it is for.
    func testTheEmptyCellAndItsCardDraw() throws {
        let now = Date()
        let empty = APIKeyGroup.snapshot(members: [])
        XCTAssertEqual(empty.status, .ok, "an empty group is not dimmed as failing")
        let model = NotchViewModel()
        model.updateSnapshots([
            ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.31)]),
            empty,
        ])
        model.now = now
        model.isExpanded = true
        model.surfaceStyle = .solid
        model.hoveredIndex = 1
        let size = model.panelSize
        try write(try render(NotchRootView(model: model).frame(width: size.width, height: size.height)
            .background(Color(white: 0.55)), dark: true), "notch-apikeys-empty.png")

        let plan = NotchLayout.keyGroupPlan([])
        let budgeted = NotchLayout.cardHeight(windowCount: 1, keyGroupBody: plan.body)
        let card = try render(TooltipCard(snapshot: empty, now: now).padding(20).background(Color(white: 0.16))
            .environment(\.notchSurfaceStyle, .solid), dark: true)
        XCTAssertEqual(card.size.height - 40, budgeted, accuracy: 3, "the card is as tall as it was budgeted")
        try write(card, "apikeys-tooltip-empty.png")
    }
}

@MainActor
final class TooltipSessionsTests: XCTestCase {
    private func session(_ name: String, _ state: AgentSession.State, ago: TimeInterval) -> AgentSession {
        AgentSession(id: name, name: name, detail: "Terminal · project", state: state,
                     waitingFor: nil, since: Date().addingTimeInterval(-ago))
    }

    func testStaleIdleSessionsAreLeftOutButWaitingOnesStay() {
        let model = NotchViewModel()
        model.now = Date()
        model.staleIdleAfter = 6 * 3600
        model.sessions["claude"] = [
            session("fresh", .idle, ago: 600),
            session("overnight", .idle, ago: 30 * 3600),
            session("asking", .waiting, ago: 30 * 3600),
        ]
        let names = model.activity(for: "claude")?.sessions.map(\.name).sorted()
        XCTAssertEqual(names, ["asking", "fresh"])
        model.staleIdleAfter = nil
        XCTAssertEqual(model.activity(for: "claude")?.sessions.count, 3)
    }

    func testTheCapIsTheSmallerOfTheSettingAndTheScreen() {
        let model = NotchViewModel()
        model.sessionLimit = 3
        XCTAssertLessThanOrEqual(model.sessionCap, 3)
    }

    func testTheTooltipRendersWithSectionsAndACappedList() throws {
        let now = Date()
        let sessions: [AgentSession] = (0..<9).map { (i: Int) -> AgentSession in
            let state: AgentSession.State = i == 4 ? .waiting : (i == 7 ? .busy : .idle)
            return session("session-\(i)", state, ago: Double(i) * 700)
        }
        let snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                        status: .ok, windows: [LimitWindow(id: "s", label: "Current session", usedFraction: 0.29)])
        let tooltip = TooltipCard(
            snapshot: snapshot,
            activity: ActivitySummary(sessions: sessions), now: now, sessionCap: 6,
            effortValue: "high", effortDots: EffortDotState(count: 4, filled: 3))
        let card = tooltip
            .padding(20).background(Color(white: 0.2))
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tooltip-sections.png"))
        }
        XCTAssertGreaterThan(image.size.height, 300)
    }
}
