import SwiftUI
import XCTest
@testable import LidEffort

@MainActor
final class IntroTourTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The note sits beside what it is about, on the side away from the
    /// bezel, and never off the screen.
    func testTheNoteSitsBesideItsAnchorAwayFromTheBezel() {
        let pill = CGRect(x: 1410, y: 400, width: 30, height: 100)
        let size = IntroTour.cardSize
        let right = IntroTour.cardFrame(anchor: pill, edge: .right, visible: screen, size: size)
        XCTAssertLessThan(right.maxX, pill.minX)
        XCTAssertEqual(right.midY, pill.midY, accuracy: 1)

        let top = CGRect(x: 670, y: 870, width: 100, height: 30)
        let below = IntroTour.cardFrame(anchor: top, edge: .top, visible: screen, size: size)
        XCTAssertLessThan(below.maxY, top.minY)
        XCTAssertEqual(below.midX, top.midX, accuracy: 1)

        let corner = CGRect(x: 1410, y: 880, width: 30, height: 20)
        let clamped = IntroTour.cardFrame(anchor: corner, edge: .right, visible: screen, size: size)
        XCTAssertTrue(screen.contains(clamped), "the note ran off the screen")
    }

    func testTheLidAndTheEndAreInTheMiddle() {
        let size = IntroTour.cardSize
        let centred = IntroTour.cardFrame(anchor: nil, edge: .right, visible: screen, size: size)
        XCTAssertEqual(centred.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(centred.midY, screen.midY, accuracy: 1)
        XCTAssertTrue(IntroTour.Step.lid.isCentred)
        XCTAssertFalse(IntroTour.Step.approval.isCentred)
    }

    /// The demos are real prompts, the kind the notch shows — and marked as
    /// the tour's, so answering one sends nothing to Claude.
    func testTheDemosAreRealPromptsTheTourAnswersItself() throws {
        let approval = try XCTUnwrap(IntroTour.demoApproval())
        XCTAssertEqual(approval.summary, "npm run build")
        XCTAssertTrue(approval.canRemember)
        let question = try XCTUnwrap(IntroTour.demoQuestion())
        XCTAssertEqual(question.questions.first?.options.count, 3)

        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        let tour = IntroTour(fleet: fleet, preferences: Preferences(defaults: UserDefaults(suiteName: "IntroTourTests.\(UUID())")!),
                             effort: { nil })
        XCTAssertFalse(tour.handleAnswer(approval.id), "a prompt the tour did not put up is not the tour's")
    }

    private func tour(edge: NotchEdge) -> (IntroTour, Preferences) {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "IntroTourTests.\(UUID())")!)
        preferences.notchEdge = edge
        let tour = IntroTour(fleet: NotchFleet(scope: .mainDisplay, edge: edge), preferences: preferences, effort: { nil })
        return (tour, preferences)
    }

    /// The tour is laid out for the pill on the right, so it starts by
    /// bringing it there — and remembers where it was.
    func testTheTourBringsThePillHomeToTheRight() {
        let (tour, preferences) = tour(edge: .top)
        XCTAssertTrue(tour.bringHome())
        XCTAssertEqual(preferences.notchEdge, .right)
        XCTAssertEqual(tour.edgeBeforeTour, .top)

        let (stay, home) = self.tour(edge: .right)
        XCTAssertFalse(stay.bringHome(), "already home: nothing to fly")
        XCTAssertEqual(home.notchEdge, .right)
        XCTAssertNil(stay.edgeBeforeTour)
    }

    /// Sent round the screen on "anywhere", it comes home when the tour moves on.
    func testLeavingAnywhereBringsThePillBackRight() {
        let (tour, preferences) = tour(edge: .right)
        tour.showForTesting(.anywhere, anchor: nil, screen: screen, edge: .right)
        tour.sendRound()
        XCTAssertNotEqual(preferences.notchEdge, .right)
        tour.next()
        XCTAssertEqual(tour.step, .lid)
        XCTAssertEqual(preferences.notchEdge, .right)
    }

    /// "anywhere" is done when the pill has seen every side — each one
    /// cheered as it lands, the last one saying so.
    func testEverySideIsVisitedAndCheered() {
        let (tour, _) = tour(edge: .right)
        tour.showForTesting(.anywhere, anchor: nil, screen: screen, edge: .right, visited: [.right])
        for edge in [NotchEdge.bottom, .left] {
            tour.arrived(at: edge)
            XCTAssertFalse(tour.hasVisitedEveryEdge)
            XCTAssertNotNil(tour.celebration)
        }
        tour.arrived(at: .top)
        XCTAssertTrue(tour.hasVisitedEveryEdge)
        XCTAssertTrue(tour.celebration?.contains("four") == true)
    }

    /// Show me flies the whole round, clockwise from home, and lands home.
    func testShowMeFliesRoundEverySide() async throws {
        let (tour, preferences) = tour(edge: .right)
        tour.showForTesting(.anywhere, anchor: nil, screen: screen, edge: .right, visited: [.right])
        XCTAssertEqual(IntroTour.round, [.right, .bottom, .left, .top])
        tour.flyRound()
        XCTAssertTrue(tour.isFlying)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(preferences.notchEdge, .bottom, "the first hop is straight away")
    }

    /// Answering a demo prompt is a step of the tour: its own card takes the
    /// prompt's place and says what was done.
    func testAnsweringADemoShowsTheToursOwnCard() throws {
        let (tour, _) = tour(edge: .right)
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        let owned = IntroTour(fleet: fleet, preferences: Preferences(defaults: UserDefaults(suiteName: "IntroTourTests.\(UUID())")!),
                              effort: { nil })
        owned.showForTesting(.done, anchor: nil, screen: screen, edge: .right)
        owned.next()
        XCTAssertEqual(owned.step, .approval)
        let demo = try XCTUnwrap(fleet.prompts.last)
        XCTAssertTrue(owned.handleAnswer(demo.id, with: .allow))
        XCTAssertTrue(fleet.prompts.isEmpty, "the demo is taken down")
        XCTAssertEqual(owned.result?.title, "Allowed")
        XCTAssertEqual(owned.result?.detail, "npm run build")
        XCTAssertFalse(tour.handleAnswer(demo.id, with: .allow), "another tour's prompt is not this one's")

        owned.next()
        XCTAssertNil(owned.result, "the card goes with its step")
        let question = try XCTUnwrap(fleet.prompts.last)
        XCTAssertTrue(owned.handleAnswer(question.id, with: .answers(["Which database…": ["SQLite"]])))
        XCTAssertEqual(owned.result?.title, "Answered")
        XCTAssertEqual(owned.result?.detail, "SQLite")
    }

    /// And the last note can give it back to where it lived before.
    func testTheLastNoteCanPutItBack() {
        let (tour, preferences) = tour(edge: .left)
        tour.bringHome()
        tour.restoreEdge()
        XCTAssertEqual(preferences.notchEdge, .left)
        XCTAssertNil(tour.edgeBeforeTour)
    }

    /// A stroke is drawn against the step's clock, so a view rebuilt half
    /// way through carries on from where it was — rebuilding it used to
    /// start it over, and one rebuilt often enough never appeared at all.
    func testStrokesDrawAgainstTheStepsClock() {
        let start = Date()
        XCTAssertEqual(MarkerStroke.progress(at: start, since: start, delay: 0), 0)
        XCTAssertEqual(MarkerStroke.progress(at: start.addingTimeInterval(0.2), since: start, delay: 0.3), 0,
                       "not before its delay")
        let half = MarkerStroke.progress(at: start.addingTimeInterval(0.35), since: start, delay: 0)
        XCTAssertGreaterThan(half, 0.5, "eased out: more than half drawn at half time")
        XCTAssertEqual(MarkerStroke.progress(at: start.addingTimeInterval(5), since: start, delay: 0.5), 1)
        XCTAssertEqual(MarkerStroke.progress(at: Date(), since: .distantPast, delay: 0), 1, "an old step is fully drawn")
    }

    /// Every note and the doodles over the screen, written out when
    /// EFFORT_RENDER_DIR is set.
    func testEveryStepDraws() throws {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        let tour = IntroTour(fleet: fleet, preferences: Preferences(defaults: UserDefaults(suiteName: "IntroTourTests.\(UUID())")!),
                             effort: { nil })
        let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"]
        let pill = CGRect(x: 1402, y: 380, width: 34, height: 140)
        let promptCard = CGRect(x: 1150, y: 330, width: 250, height: 240)
        for step in IntroTour.Step.allCases {
            let anchor = (step == .approval || step == .question) ? promptCard : pill
            tour.showForTesting(step, anchor: step.isCentred ? nil : anchor, screen: screen, edge: .right,
                                celebration: step == .approval ? "Nice! That's all it takes." : nil,
                                result: step == .approval ? TourResult(answer: .allow, question: false, at: promptCard)
                                    : step == .question ? TourResult(answer: .answers(["q": ["Postgres"]]), question: true, at: promptCard) : nil,
                                visited: step == .anywhere ? [.right, .bottom] : [])
            let card = try render(TourCard(tour: tour), size: IntroTour.cardSize)
            let scene = try render(ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(white: 0.85), Color(white: 0.6)], startPoint: .top, endPoint: .bottom)
                // A stand-in pill and card, where the real ones would be.
                RoundedRectangle(cornerRadius: 17).fill(.black)
                    .frame(width: pill.width, height: pill.height)
                    .position(x: pill.midX, y: screen.maxY - pill.midY)
                TourDoodles(tour: tour)
                TourCard(tour: tour)
                    .position(x: tour.cardFrame.midX, y: screen.maxY - tour.cardFrame.midY)
            }, size: screen.size, settle: 1.2)
            if let dir {
                try card.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tour-card-\(step).png"))
                try scene.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tour-scene-\(step).png"))
            }
        }
    }

    /// The intro's sound: as long as the film, never clipping, quiet at the
    /// start and swelling to the bowl's strike.
    /// The scroll runs fastest in the middle and comes to rest — never back.
    func testTheAgentScrollSpeedsUpThenSettles() {
        let total = IntroTimeline.scrollDistance
        let samples = stride(from: IntroTimeline.scrollFrom, through: IntroTimeline.scrollTo, by: 0.05)
            .map { IntroTimeline.scrolled($0, total: total) }
        XCTAssertEqual(samples.first ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(samples.last ?? -1, total, accuracy: 0.5)
        XCTAssertEqual(samples, samples.sorted(), "it ran backwards")
        XCTAssertLessThan(IntroTimeline.speed(IntroTimeline.scrollFrom + 0.2), IntroTimeline.speed(IntroTimeline.scrollFrom + 1.3))
    }

    func testTheIntroSoundRisesToTheStrike() {
        let sound = MeditationRise.render()
        let rate = MeditationRise.sampleRate
        XCTAssertEqual(Double(sound.left.count) / rate, MeditationRise.duration, accuracy: 0.01)
        func loudness(_ from: Double, _ to: Double) -> Float {
            let slice = sound.left[Int(from * rate)..<Int(to * rate)]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        let strike = MeditationRise.strike
        // Gentle: well short of full scale anywhere.
        XCTAssertLessThan(sound.left.map(abs).max() ?? 1, 0.4, "too loud")
        XCTAssertLessThan(loudness(0, 0.5), loudness(strike - 1.0, strike - 0.5), "does not rise")
        XCTAssertLessThan(loudness(strike * 0.4, strike * 0.4 + 0.5), loudness(strike - 0.5, strike), "does not keep rising")
        XCTAssertLessThan(loudness(MeditationRise.duration - 0.4, MeditationRise.duration), loudness(strike, strike + 0.5),
                          "does not let go")
    }

    /// Heard from the first moment, and a bloop for every drop that joins.
    func testTheIntroSoundStartsAtOnceAndEveryDropIsHeard() {
        let sound = MeditationRise.render()
        let rate = MeditationRise.sampleRate
        func loudness(_ from: Double, _ to: Double) -> Float {
            let slice = sound.left[Int(from * rate)..<Int(to * rate)]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        XCTAssertGreaterThan(loudness(0.6, 1.0), 0.01, "silent at the start")
        for at in IntroTimeline.drops {
            XCTAssertGreaterThan(loudness(at, at + 0.04), loudness(at - 0.03, at - 0.005) * 1.5, "no bloop at \(at)")
        }
    }

    /// The film's pill really gets small on its way home — not only the
    /// agents inside it. Measured off the drawn frames: how much of the
    /// screen the pill's light covers as it leaves, and as it lands.
    func testTheIntroPillShrinksIntoTheFoldedPill() throws {
        let size = CGSize(width: 1440, height: 900)
        let target = CGRect(x: 1426, y: 410, width: 10, height: 80)
        func lit(at t: Double) throws -> Int {
            let renderer = ImageRenderer(content: ZStack {
                Color.black
                IntroFrame(t: t, size: size, target: target, agents: [.claude], showsBackdrop: false)
            }.frame(width: size.width, height: size.height))
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var count = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.55 { count += 1 }
                }
            }
            return count
        }
        let leaving = try lit(at: IntroTimeline.flyFrom + 0.05)
        let landing = try lit(at: IntroTimeline.flyTo - 0.08)
        XCTAssertGreaterThan(leaving, 0)
        XCTAssertLessThan(Double(landing), Double(leaving) * 0.25,
                          "the pill is \(landing) lit points landing against \(leaving) leaving — it did not shrink")
    }

    /// Each drop touches the pill exactly when its bloop sounds — apart
    /// from it a moment before, sinking into it a moment after.
    func testEveryDropTouchesThePillOnItsBloop() {
        let pill = IntroFrame.pillSize
        let centre = CGPoint(x: 500, y: 500)
        for path in IntroTimeline.dropPaths {
            func gap(_ t: Double) -> Double? {
                guard let drop = IntroTimeline.drop(path, at: t, centre: centre, pill: pill) else { return nil }
                let reach = hypot(Double(drop.point.x - centre.x), Double(drop.point.y - centre.y))
                return reach - (IntroTimeline.touchDistance(path, pill: pill) - Double(path.radius) + 4) - Double(drop.radius)
            }
            XCTAssertEqual(gap(path.arrive) ?? 99, -4 + Double(path.radius) - Double(path.radius), accuracy: 1.5,
                           "drop \(path.arrive) is not at the pill's edge on its bloop")
            XCTAssertGreaterThan(gap(path.arrive - 0.25) ?? -1, 20, "drop \(path.arrive) touched too early")
            XCTAssertNil(IntroTimeline.drop(path, at: path.arrive + 0.4, centre: centre, pill: pill), "never sank in")
        }
        // The sound's bloops are at the same moments.
        XCTAssertEqual(IntroTimeline.dropPaths.map(\.arrive), IntroTimeline.drops)
    }

    /// The tour's sounds are soft, and each action has its own.
    func testEachActionHasItsOwnSoftSound() {
        let rendered = TourSounds.Sound.allCases.map { TourSounds.render($0) }
        for (sound, samples) in zip(TourSounds.Sound.allCases, rendered) {
            XCTAssertLessThan(samples.map(abs).max() ?? 1, 0.2, "\(sound) is loud")
            XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.005, "\(sound) is silent")
        }
        let approve = TourSounds.render(.approve), answer = TourSounds.render(.answer)
        XCTAssertNotEqual(approve.count, answer.count, "approve and answer sound alike")
    }

    /// The Liquid Glass look — the film's key frames and every card —
    /// written out when EFFORT_RENDER_DIR is set.
    func testTheGlassTourDraws() throws {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        let tour = IntroTour(fleet: fleet, preferences: Preferences(defaults: UserDefaults(suiteName: "IntroTourTests.\(UUID())")!),
                             effort: { nil })
        let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"]
        let pill = CGRect(x: 1410, y: 390, width: 26, height: 120)
        let backdrop = LinearGradient(colors: [Color(red: 0.1, green: 0.12, blue: 0.2), Color(red: 0.25, green: 0.2, blue: 0.35)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
        for moment in [2.4] {
            let frame = try render(ZStack {
                backdrop
                IntroFrame(t: moment, size: screen.size,
                           target: CGRect(x: pill.minX, y: screen.maxY - pill.maxY, width: pill.width, height: pill.height),
                           agents: [.claude, .openai, .grok])
            }, size: screen.size)
            if let dir { try frame.write(to: URL(fileURLWithPath: dir).appendingPathComponent("glass-intro-\(moment).png")) }
        }
        let promptCard = CGRect(x: 1150, y: 330, width: 250, height: 240)
        for step in IntroTour.Step.allCases {
            let anchor = (step == .approval || step == .question) ? promptCard : pill
            tour.showForTesting(step, anchor: step.isCentred && step != .anywhere ? nil : anchor, screen: screen, edge: .right,
                                celebration: step == .approval ? "Nice! That's all it takes." : nil,
                                result: step == .approval ? TourResult(answer: .allow, question: false, at: promptCard) : nil,
                                visited: step == .anywhere ? [.right, .bottom] : [], style: .glass)
            let scene = try render(ZStack(alignment: .topLeading) {
                backdrop
                RoundedRectangle(cornerRadius: 13).fill(.black)
                    .frame(width: pill.width, height: pill.height)
                    .position(x: pill.midX, y: screen.maxY - pill.midY)
                GlassTourOverlay(tour: tour)
                GlassTourCard(tour: tour)
                    .position(x: tour.cardFrame.midX, y: screen.maxY - tour.cardFrame.midY)
            }, size: screen.size, settle: 1.0)
            if let dir { try scene.write(to: URL(fileURLWithPath: dir).appendingPathComponent("glass-\(step).png")) }
        }
    }

    private func render(_ view: some View, size: CGSize, settle: TimeInterval = 0.4) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

@MainActor
final class TourSoundsTests: XCTestCase {
    /// Every voice is wired to the engine. Wired straight to the reverb, all
    /// but one were cut off, and the tour crashed on its second sound.
    func testEveryVoiceIsConnected() throws {
        let sounds = TourSounds()
        defer { sounds.stop() }
        for sound in TourSounds.Sound.allCases { sounds.playNow(sound) }
        guard let engine = sounds.engineForTesting else {
            throw XCTSkip("no audio output on this machine")
        }
        XCTAssertEqual(sounds.players.count, 4)
        for player in sounds.players {
            XCTAssertFalse(engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty, "a voice is unplugged")
        }
        // Round the voices twice more: every one of them plays without raising.
        for _ in 0..<8 { sounds.playNow(.tick) }
    }
}

@MainActor
final class TourDemoTests: XCTestCase {
    /// While the tour runs the notch shows the demo — real readings keep
    /// arriving underneath, unseen — and the real ones are back when it ends.
    func testTheDemoStandsInForRealReadingsThenGivesThemBack() {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        let real = Fixtures.snapshots()
        fleet.setSnapshots(real)
        fleet.showTourDemo(snapshots: TourDemo.snapshots(), sessions: TourDemo.sessions())
        XCTAssertEqual(fleet.menuModel.snapshots.map(\.id), ["claude", "codex", "cursor"])
        XCTAssertEqual(fleet.menuModel.sessions["claude"]?.count, 3)

        fleet.setSnapshots(real)
        fleet.setSessions(providerID: "claude", sessions: [])
        XCTAssertEqual(fleet.menuModel.snapshots.map(\.id), ["claude", "codex", "cursor"], "real readings broke into the demo")

        fleet.endTourDemo()
        XCTAssertEqual(fleet.menuModel.snapshots.map(\.id), real.map(\.id))
        XCTAssertEqual(fleet.menuModel.sessions["claude"], [])
        XCTAssertEqual(fleet.menuModel.sessions["codex"], [], "a demo session outlived the tour")
    }

    /// Clicking a demo session is the tour's to answer; a real one is not.
    func testOnlyDemoSessionsAreTheToursToAnswer() throws {
        let tour = IntroTour(fleet: NotchFleet(scope: .mainDisplay, edge: .right),
                             preferences: Preferences(defaults: UserDefaults(suiteName: "TourDemoTests.\(UUID())")!),
                             effort: { nil })
        let pid = try XCTUnwrap(TourDemo.pids.first)
        XCTAssertTrue(tour.handleSessionClick(pid))
        XCTAssertNotNil(tour.celebration)
        XCTAssertFalse(tour.handleSessionClick(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(Set(TourDemo.sessions().values.flatMap { $0 }.compactMap(\.processID)), TourDemo.pids)
    }

    /// The first two steps light the part of the tooltip they talk about —
    /// the limits, then the sessions — and dim the rest behind it.
    func testTheTourLightsWhatItShowsInTheTooltip() throws {
        let now = Date()
        let claude = try XCTUnwrap(TourDemo.snapshots(now: now).first)
        let sessions = TourDemo.sessions(now: now)["claude"] ?? []
        func card(_ focus: TooltipTourFocus?) -> some View {
            TooltipCard(snapshot: claude, activity: ActivitySummary(sessions: sessions), now: now,
                        effortValue: "high", effortDots: EffortDotState(count: 4, filled: 3), tourFocus: focus)
        }
        let view = HStack(alignment: .top, spacing: 24) { card(nil); card(.limits); card(.sessions) }
            .padding(20).background(Color(white: 0.2))
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tour-tooltip-focus.png"))
        }
        // How much light is in a band of rows, in one of the three cards.
        let rep = NSBitmapImageRep(cgImage: image)
        let column = CGFloat(image.width - 40 - 48) / 3
        func light(card: Int, rows: ClosedRange<CGFloat>) -> CGFloat {
            var sum: CGFloat = 0
            let x0 = 20 + CGFloat(card) * (column + 24)
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
                for x in stride(from: x0, to: x0 + column, by: 3) {
                    sum += rep.colorAt(x: Int(x), y: Int(y))?.brightnessComponent ?? 0
                }
            }
            return sum
        }
        let height = CGFloat(image.height)
        let top = (height * 0.1)...(height * 0.35), bottom = (height * 0.7)...(height * 0.95)
        XCTAssertLessThan(light(card: 1, rows: bottom), light(card: 0, rows: bottom) * 0.7, "the sessions were not dimmed under the limits")
        XCTAssertLessThan(light(card: 2, rows: top), light(card: 0, rows: top) * 0.7, "the limits were not dimmed under the sessions")
    }

    func testSessionsComeRightAfterLimits() {
        XCTAssertEqual(IntroTour.Step.allCases.prefix(2), [.hello, .sessions])
        XCTAssertTrue(IntroTour.Step.hello.holdsTooltip)
        XCTAssertTrue(IntroTour.Step.sessions.holdsTooltip)
        XCTAssertFalse(IntroTour.Step.done.holdsTooltip)
    }
}

@MainActor
final class PixelSkyTests: XCTestCase {
    /// Clouds, but not everywhere: sky shows between them, as on the page.
    func testTheSkyHasCloudsAndClearSky() throws {
        let image = try XCTUnwrap(PixelSky.clouds(PixelSky.near, columns: 160, rows: 80))
        let rep = NSBitmapImageRep(cgImage: image)
        var cloud = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { cloud += 1 } }
        let share = Double(cloud) / Double(rep.pixelsWide * rep.pixelsHigh)
        XCTAssertGreaterThan(share, 0.03, "no clouds")
        XCTAssertLessThan(share, 0.4, "no sky")
    }

    /// The intro's sky comes in and goes out: nothing at the start and
    /// the end, all of it in the middle.
    func testTheSkyFadesInAndOut() throws {
        let size = CGSize(width: 480, height: 300)
        func blue(at t: Double) throws -> Double {
            let renderer = ImageRenderer(content: IntroFrame(t: t, size: size, target: nil, agents: [.claude])
                .frame(width: size.width, height: size.height).background(Color.black))
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            // A corner, away from the pill and the words.
            return Double(rep.colorAt(x: 8, y: 8)?.blueComponent ?? 0)
        }
        XCTAssertLessThan(try blue(at: 0), 0.1)
        XCTAssertGreaterThan(try blue(at: IntroTimeline.strike), 0.3)
        XCTAssertLessThan(try blue(at: IntroTimeline.length), 0.1)
    }
}
