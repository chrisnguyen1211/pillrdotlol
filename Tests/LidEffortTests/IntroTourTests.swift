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
        XCTAssertEqual(owned.step, .reply)
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
        let light = LinearGradient(colors: [Color(white: 0.93), Color(red: 0.8, green: 0.86, blue: 0.95)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
        for step in IntroTour.Step.allCases {
            let anchor = (step == .approval || step == .question) ? promptCard : step == .reply ? Self.replyCapsule(beside: pill) : pill
            tour.showForTesting(step, anchor: step.isCentred && step != .anywhere ? nil : anchor, screen: screen, edge: .right,
                                celebration: step == .approval ? "Nice! That's all it takes." : nil,
                                result: step == .approval ? TourResult(answer: .allow, question: false, at: promptCard) : nil,
                                visited: step == .anywhere ? [.right, .bottom] : [])
            // The new steps, and the one whose words changed, in light as well.
            let looks: [Bool] = [.apiKeys, .reply, .anywhere, .badge, .dashboard].contains(step) ? [true, false] : [true]
            for dark in looks {
                let scene = try render(ZStack(alignment: .topLeading) {
                    if dark { backdrop } else { light }
                    RoundedRectangle(cornerRadius: 13).fill(.black)
                        .frame(width: pill.width, height: pill.height)
                        .position(x: pill.midX, y: screen.maxY - pill.midY)
                    GlassTourOverlay(tour: tour)
                    GlassTourCard(tour: tour)
                        .position(x: tour.cardFrame.midX, y: screen.maxY - tour.cardFrame.midY)
                }, size: screen.size, settle: 1.0, dark: dark)
                let name = dark ? "glass-\(step).png" : "glass-\(step)-light.png"
                if let dir { try scene.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)) }
            }
        }
    }

    /// The steps that want you to try something say so until you have: the
    /// prompts until one is answered, "anywhere" until Show me is pressed —
    /// and Next is the quiet button meanwhile.
    func testTheStepsToTryInviteYouUntilYouHave() throws {
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        let tour = IntroTour(fleet: fleet, preferences: Preferences(defaults: UserDefaults(suiteName: "IntroTourTests.\(UUID())")!),
                             effort: { nil })
        let card = CGRect(x: 1150, y: 330, width: 250, height: 240)
        tour.showForTesting(.approval, anchor: card, screen: screen, edge: .right)
        XCTAssertTrue(tour.invitesTry)
        XCTAssertEqual(tour.tryHint, L10n.t("Try it: press Allow on the card"))
        tour.showForTesting(.approval, anchor: card, screen: screen, edge: .right,
                            result: TourResult(answer: .allow, question: false, at: card))
        XCTAssertFalse(tour.invitesTry, "answered: nothing left to ask")
        XCTAssertNil(tour.tryHint)
        tour.showForTesting(.question, anchor: card, screen: screen, edge: .right)
        XCTAssertEqual(tour.tryHint, L10n.t("Try it: pick an answer, then Send"))
        tour.showForTesting(.anywhere, anchor: nil, screen: screen, edge: .right)
        XCTAssertEqual(tour.tryHint, L10n.t("Try Show me"))
        tour.showForTesting(.sessions, anchor: nil, screen: screen, edge: .right)
        XCTAssertFalse(tour.invitesTry, "a step with nothing to try asks for nothing")

        // Drawn, before trying: the hint over the buttons, Show me lit.
        guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] else { return }
        let pill = CGRect(x: 1410, y: 390, width: 26, height: 120)
        for step in [IntroTour.Step.approval, .anywhere] {
            tour.showForTesting(step, anchor: step == .approval ? card : pill, screen: screen, edge: .right)
            let scene = try render(ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.1, green: 0.12, blue: 0.2), Color(red: 0.25, green: 0.2, blue: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                GlassTourCard(tour: tour)
                    .position(x: tour.cardFrame.midX, y: screen.maxY - tour.cardFrame.midY)
            }, size: screen.size, settle: 1.0, dark: true)
            try scene.write(to: URL(fileURLWithPath: dir).appendingPathComponent("glass-\(step)-try.png"))
        }
    }

    /// Where the reply field's capsule opens beside a pill on the right edge.
    private static func replyCapsule(beside pill: CGRect) -> CGRect {
        CGRect(x: pill.minX + ReplyPanelController.orbGap - OrbReplyView.stage.width
                   + (OrbReplyView.stage.width - OrbReplyView.fieldSize.width) / 2,
               y: pill.midY - OrbReplyView.fieldSize.height / 2,
               width: OrbReplyView.fieldSize.width, height: OrbReplyView.fieldSize.height)
    }

    /// The new steps are where they belong: the keys straight after the
    /// limits, a reply straight after a session finishes.
    func testTheKeysAndTheReplyHaveTheirPlaces() {
        let order = IntroTour.Step.allCases
        XCTAssertEqual(order, [.hello, .apiKeys, .sessions, .done, .reply, .approval, .question, .anywhere, .lid,
                               .badge, .dashboard, .finish])
        XCTAssertTrue(IntroTour.Step.apiKeys.holdsTooltip, "the keys' card is a tooltip, held open")
        XCTAssertFalse(IntroTour.Step.reply.holdsTooltip, "the reply field takes the tooltip's place")
        XCTAssertFalse(IntroTour.Step.apiKeys.isCentred)
        XCTAssertFalse(IntroTour.Step.reply.isCentred)

        let (tour, _) = tour(edge: .right)
        XCTAssertTrue(tour.steps.contains(.apiKeys) && tour.steps.contains(.reply), "shown on every Mac")
        for step in order {
            tour.showForTesting(step, anchor: nil, screen: screen, edge: .right)
            XCTAssertFalse(tour.stepTitle.isEmpty, "\(step) has no title")
            XCTAssertFalse(tour.stepText.isEmpty, "\(step) has no words")
        }
        tour.showForTesting(.apiKeys, anchor: nil, screen: screen, edge: .right)
        XCTAssertTrue(tour.stepText.contains("\(APICatalog.entries.count) providers"), tour.stepText)
        tour.showForTesting(.hello, anchor: nil, screen: screen, edge: .right)
        tour.next()
        XCTAssertEqual(tour.step, .apiKeys)
        tour.next()
        XCTAssertEqual(tour.step, .sessions)
        tour.back()
        XCTAssertEqual(tour.step, .apiKeys)
    }

    /// 1.2.0's steps close the tour: a badge on the notch after the lid, then
    /// the dashboard in Settings, then the end. Shown on every Mac; the badge
    /// beside the pill, the dashboard, which is not on the notch, centred.
    func testTheBadgeAndTheDashboardComeBeforeTheEnd() {
        let order = IntroTour.Step.allCases
        XCTAssertEqual(Array(order.suffix(4)), [.lid, .badge, .dashboard, .finish])
        XCTAssertFalse(IntroTour.Step.badge.isCentred, "the badge's note points at its card")
        XCTAssertTrue(IntroTour.Step.dashboard.isCentred, "nothing on the notch to point at")
        XCTAssertFalse(IntroTour.Step.badge.holdsTooltip)
        XCTAssertFalse(IntroTour.Step.dashboard.holdsTooltip)

        let (tour, _) = tour(edge: .right)
        XCTAssertTrue(tour.steps.contains(.badge) && tour.steps.contains(.dashboard), "shown on every Mac")
        tour.showForTesting(.lid, anchor: nil, screen: screen, edge: .right)
        tour.next()
        XCTAssertEqual(tour.step, .badge)
        XCTAssertEqual(tour.stepTitle, L10n.t("Badges, earned as you go"))
        XCTAssertTrue(tour.stepText.contains("48"), tour.stepText)
        tour.next()
        XCTAssertEqual(tour.step, .dashboard)
        XCTAssertEqual(tour.stepTitle, L10n.t("A dashboard in Settings"))
        for words in ["gear", "today, this week or this month", "your Mac's own hour", "down arrow", "up slides it away"] {
            XCTAssertTrue(tour.stepText.contains(words), "the dashboard step does not say \(words)")
        }
        tour.next()
        XCTAssertEqual(tour.step, .finish)
        tour.back()
        XCTAssertEqual(tour.step, .dashboard)
        tour.back()
        XCTAssertEqual(tour.step, .badge)
        tour.end()
    }

    /// Nothing anyone reads in the new steps, or in the approval's words
    /// that now say a card answered elsewhere goes, has an em dash.
    func testTheNewWordsHaveNoEmDash() {
        let (tour, _) = tour(edge: .right)
        for step in [IntroTour.Step.badge, .dashboard] {
            tour.showForTesting(step, anchor: nil, screen: screen, edge: .right)
            XCTAssertFalse(tour.stepTitle.contains("—") || tour.stepText.contains("—"), "\(step)")
        }
        let card = CGRect(x: 1150, y: 330, width: 250, height: 240)
        tour.showForTesting(.approval, anchor: card, screen: screen, edge: .right,
                            result: TourResult(answer: .allow, question: false, at: card))
        XCTAssertTrue(tour.stepText.contains("the terminal or the Claude app"), tour.stepText)
        XCTAssertTrue(tour.stepText.contains("leaves the notch"), tour.stepText)
        XCTAssertFalse(tour.stepText.contains("—"))
    }

    /// The badge step puts the coach's own card up: badges, three of them
    /// taking turns, on the taller badge card. Not at once, so the flip is
    /// seen once the note is in place; down again when the step is left.
    /// Nothing is awarded.
    func testTheBadgeStepPutsUpTheRealBadgeCardThenTakesItDown() async throws {
        let card = IntroTour.demoBadgeCard()
        XCTAssertEqual(card.kind, .recap)
        XCTAssertEqual(card.providerID, "coach", "the coach's card, as the notch shows a badge")
        let note = try XCTUnwrap(card.note)
        XCTAssertEqual(note.badges, IntroTour.demoBadges)
        XCTAssertEqual(note.badges.count, 3, "several earned together take turns")
        XCTAssertEqual(note, Achievements.note(IntroTour.demoBadges))
        XCTAssertEqual(UsageResetCard.cardHeight(for: card), UsageResetCard.badgeCardHeight)
        XCTAssertTrue(note.good)

        // Timing: after the note, like the reply's field; up for the step.
        XCTAssertGreaterThan(IntroTour.badgeDelay, 0.3)
        XCTAssertLessThan(IntroTour.badgeDelay, 1.0)
        XCTAssertLessThan(IntroTour.badgeLands, 0.7, "the sparkle comes before the flip is over")
        XCTAssertGreaterThanOrEqual(IntroTour.badgeHold, 30, "as long as the done note")

        let earned = Achievements.earned()
        let (tour, _) = tour(edge: .right)
        tour.showForTesting(.lid, anchor: nil, screen: screen, edge: .right)
        tour.next()
        XCTAssertEqual(tour.step, .badge)
        XCTAssertNil(tour.badgeCard, "up before the note is in place")
        try await Task.sleep(for: .seconds(IntroTour.badgeDelay + 0.3))
        XCTAssertEqual(tour.badgeCard?.note, card.note, "the tour's badge card")
        XCTAssertNotEqual(IntroTour.demoBadgeCard(), IntroTour.demoBadgeCard(),
                          "each visit's card is its own, so an earlier one's timer can't take it down")
        XCTAssertEqual(tour.badgeCard?.note?.badges.isEmpty, false, "the card shows badges")
        tour.next()
        XCTAssertEqual(tour.step, .dashboard)
        XCTAssertNil(tour.badgeCard, "the card goes with its step")

        // Left before it came up, it never comes.
        tour.back()
        XCTAssertEqual(tour.step, .badge)
        tour.next()
        try await Task.sleep(for: .seconds(IntroTour.badgeDelay + 0.3))
        XCTAssertNil(tour.badgeCard)
        XCTAssertEqual(Achievements.earned(), earned, "the tour awarded a badge")
        tour.end()
    }

    /// On the notch: the card comes up beside the open pill where the tour
    /// laid its note out before it was up, and only the tour's card is taken
    /// down by the tour.
    func testTheBadgeCardStandsWhereTheNoteExpectedIt() throws {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        let card = IntroTour.demoBadgeCard()
        let expected = try XCTUnwrap(controller.screenRect(of: .alert))
        controller.showResetAlert(card, duration: IntroTour.badgeHold)
        XCTAssertEqual(controller.model.activeResetAlert, card)
        XCTAssertTrue(controller.model.isExpanded, "the card comes with the notch open")
        let shown = try XCTUnwrap(controller.screenRect(of: .alert))
        XCTAssertEqual(shown.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(shown.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(shown.width, expected.width, accuracy: 1)
        XCTAssertEqual(shown.height, expected.height, accuracy: 1)
        let notch = try XCTUnwrap(controller.screenRect(of: .notch))
        XCTAssertTrue(shown.insetBy(dx: -1, dy: -1).contains(notch), "the halo goes round the pill and the card")
        XCTAssertGreaterThan(shown.width * shown.height, notch.width * notch.height * 2, "no room for the card")

        var other = card
        other.note = Achievements.note([.init(family: "keys", tier: .bronze)])
        controller.dismissResetAlert(other)
        XCTAssertEqual(controller.model.activeResetAlert, card, "a card not the tour's stays")
        controller.dismissResetAlert(card)
        XCTAssertNil(controller.model.activeResetAlert)
    }

    /// The badge card the step shows is the badge card: the medal drawn
    /// large in colour, where a card with no badges has none.
    func testTheTourBadgeCardShowsItsBadges() throws {
        let card = IntroTour.demoBadgeCard()
        var plain = card
        plain.note = CardNote(title: "Best week yet", subtitle: "12 h of agent work", status: "Record", good: true)
        func colour(_ event: UsageResetEvent, name: String) throws -> Int {
            let view = UsageResetCard(event: event, direction: NotchEdge.right.tooltipDirection)
                .frame(width: NotchLayout.cardWidth + NotchLayout.tailLength, height: UsageResetCard.badgeCardHeight,
                       alignment: .top)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .environment(\.notchSurfaceStyle, .solid)
                .environment(\.badgeBurstFrozenAt, 2.4)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            var count = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.saturationComponent > 0.35, c.brightnessComponent > 0.35 { count += 1 }
                }
            }
            return count
        }
        let badge = try colour(card, name: "tour-badge-card.png")
        let none = try colour(plain, name: "tour-badge-card-plain.png")
        XCTAssertGreaterThan(badge, 400, "no badge on the card")
        XCTAssertGreaterThan(badge, none * 4, "the badge card is no more colourful than a card without one")
    }

    /// The dashboard step's picture is made of the dashboard's own pieces:
    /// its folded height, its widgets, its sky, and a commit for most days.
    func testTheDashboardPictureIsTheFoldedDashboard() throws {
        XCTAssertEqual(TourDashboard.size.height, DashboardPanel.foldedHeight)
        let now = Date()
        let commits = TourDashboard.commits(now: now)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        XCTAssertNotNil(commits[today], "today is in the grid")
        XCTAssertGreaterThan(commits.values.filter { $0 > 0 }.count, commits.count / 2, "a grid of mostly empty days")
        XCTAssertNil(commits[calendar.date(byAdding: .day, value: 1, to: today)!], "a commit from tomorrow")

        let renderer = ImageRenderer(content: TourDashboard(t: 0).environment(\.colorScheme, .dark))
        renderer.scale = 1
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(CGFloat(rep.pixelsWide), TourDashboard.size.width)
        // The sky shows in a corner, under no widget.
        let corner = try XCTUnwrap(rep.colorAt(x: 30, y: 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.alphaComponent, 0.9, "no sky behind the dashboard")
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tour-dashboard.png"))
        }
    }

    /// The keys step's demo is the real cell, built the way the notch builds
    /// it, with a key for each kind of reading.
    func testTheKeysDemoIsTheRealCell() throws {
        let now = Date()
        let group = TourDemo.keyGroup()
        XCTAssertEqual(group.id, APIKeyGroup.id)
        let keys = try XCTUnwrap(group.keyGroup)
        XCTAssertEqual(keys.map(\.glyph), [.openrouter, .elevenlabs, .deepseek, .groq])
        XCTAssertTrue(keys.allSatisfy { APIKeyGroup.isMember($0.id) }, "a demo key the group would not take")
        XCTAssertTrue(keys.allSatisfy { $0.hasReading })
        XCTAssertEqual(group.status, .ok, "no demo key is failing")

        let lines = keys.map { APIKeyGroup.figures(for: $0, now: now).map(\.text) }
        XCTAssertEqual(lines[0], ["$7.50 left", "$3.20 spent this month", "$41.00 spent in total"])
        let elevenLabs = try XCTUnwrap(APIKeyGroup.figures(for: keys[1], now: now).first)
        XCTAssertEqual(elevenLabs.usedFraction ?? 0, 0.64, accuracy: 0.001, "the characters draw a bar")
        XCTAssertEqual(lines[2], ["$18.20 left"])
        XCTAssertTrue(lines[3].first?.hasPrefix("Key works") == true, "\(lines[3])")
        XCTAssertEqual(APIKeyGroup.ringMember(of: keys)?.glyph, .elevenlabs, "the only share is the ring's")

        // On the pill after the agents — and never taken for one.
        XCTAssertEqual(TourDemo.pill(now: now).map(\.id), ["claude", "codex", "cursor", APIKeyGroup.id])
        let fleet = NotchFleet(scope: .mainDisplay, edge: .right)
        fleet.showTourDemo(snapshots: TourDemo.pill(now: now), sessions: TourDemo.sessions(now: now))
        XCTAssertEqual(fleet.tourAgents.map(\.id), ["claude", "codex", "cursor"])
        fleet.endTourDemo()

        // Every key fits the card: none cut short and counted.
        XCTAssertEqual(NotchLayout.keyGroupPlan(keys).shown, keys.count)
    }

    /// The reply step writes to an idle session of the demo's, and its field
    /// opens beside the pill, level with it, where the card points.
    func testTheReplyDemoHasAnIdleSessionAndAPlace() throws {
        let session = try XCTUnwrap(TourDemo.replySession())
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(TourDemo.pids.contains(try XCTUnwrap(session.processID)), "a session with a real window")
        guard let display = NSScreen.main else { throw XCTSkip("no display") }
        let frame = display.visibleFrame
        let pill = CGRect(x: frame.maxX - 30, y: frame.midY - 70, width: 30, height: 140)
        let field = IntroTour.replyField(pill: pill, edge: .right, screen: display)
        XCTAssertEqual(field.capsule.size, OrbReplyView.fieldSize)
        XCTAssertLessThan(field.capsule.maxX, pill.minX, "the field covers the pill")
        XCTAssertEqual(field.capsule.midY, pill.midY, accuracy: 1, "not level with the pill")
        XCTAssertEqual(field.anchor.height, 0, "the pointer would move it off the card's mark")
        let card = IntroTour.cardFrame(anchor: field.capsule, edge: .right, visible: frame, size: IntroTour.cardSize)
        XCTAssertFalse(card.intersects(field.capsule), "the note sits on the field")
    }

    /// The reply step's picture is the real row, its Reply showing as it
    /// does under the pointer.
    func testTheReplyPictureShowsTheRowsReply() throws {
        let session = try XCTUnwrap(TourDemo.replySession())
        func row(_ showsReply: Bool) throws -> CGImage {
            let renderer = ImageRenderer(content: SessionRow(session: session, now: Date(), onAction: { _ in },
                                                             showsReply: showsReply)
                .frame(width: NotchLayout.cardTextWidth).padding(10).background(Color.black)
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            return try XCTUnwrap(renderer.cgImage)
        }
        let plain = try row(false), replying = try row(true)
        let a = NSBitmapImageRep(cgImage: plain), b = NSBitmapImageRep(cgImage: replying)
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        var differs = 0
        for x in stride(from: 0, to: a.pixelsWide, by: 2) {
            for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh) / 2, by: 2) {
                let ca = a.colorAt(x: x, y: y)?.brightnessComponent ?? 0, cb = b.colorAt(x: x, y: y)?.brightnessComponent ?? 0
                if abs(ca - cb) > 0.2 { differs += 1 }
            }
        }
        XCTAssertGreaterThan(differs, 20, "the Reply button did not show")
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let png = try XCTUnwrap(b.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tour-reply-row.png"))
        }
    }

    private func render(_ view: some View, size: CGSize, settle: TimeInterval = 0.4, dark: Bool? = nil) throws -> Data {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        if let dark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
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

    func testSessionsComeRightAfterLimitsAndKeys() {
        XCTAssertEqual(IntroTour.Step.allCases.prefix(3), [.hello, .apiKeys, .sessions])
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
