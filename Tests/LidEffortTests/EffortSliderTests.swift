import XCTest
import SwiftUI
@testable import LidEffort

/// The move handle's cycle and the drop's route — the parts of the new
/// chrome that are arithmetic.
final class EffortSliderTests: XCTestCase {
    // MARK: - The move handle's cycle

    func testAClickGoesClockwiseRoundAllFourEdges() {
        XCTAssertEqual(NotchEdge.right.nextSide, .bottom, "the bottom is reachable")
        XCTAssertEqual(NotchEdge.bottom.nextSide, .left)
        XCTAssertEqual(NotchEdge.left.nextSide, .top)
        XCTAssertEqual(NotchEdge.top.nextSide, .right)
        XCTAssertEqual(NotchEdge.right.nextSide.nextSide.nextSide.nextSide, .right, "four clicks, home")
        XCTAssertEqual(Set([NotchEdge.right, .bottom, .left, .top].map(\.nextSide)), Set(NotchEdge.allCases))
    }

    // MARK: - The drop's route

    private let screen = CGSize(width: 1000, height: 600)

    func testLeftToTopTurnsTheTopLeftCorner() {
        let route = EdgeFlowRoute.points(from: .left, at: CGPoint(x: 10, y: 300),
                                         to: .top, at: CGPoint(x: 500, y: 10),
                                         size: screen, depth: 20)
        XCTAssertEqual(route, [CGPoint(x: 10, y: 300), CGPoint(x: 10, y: 10), CGPoint(x: 500, y: 10)])
    }

    func testLeftToRightRunsUpOverAndDown() {
        let route = EdgeFlowRoute.points(from: .left, at: CGPoint(x: 10, y: 300),
                                         to: .right, at: CGPoint(x: 990, y: 300),
                                         size: screen, depth: 20)
        XCTAssertEqual(route, [CGPoint(x: 10, y: 300), CGPoint(x: 10, y: 10),
                               CGPoint(x: 990, y: 10), CGPoint(x: 990, y: 300)])
    }

    func testRightToLeftTakesTheSameCornersTheOtherWay() {
        let route = EdgeFlowRoute.points(from: .right, at: CGPoint(x: 990, y: 300),
                                         to: .left, at: CGPoint(x: 10, y: 300),
                                         size: screen, depth: 20)
        XCTAssertEqual(route.map(\.y), [300, 10, 10, 300])
        XCTAssertEqual(route.map(\.x), [990, 990, 10, 10])
    }

    func testTheCornerSitsHalfAStrokeInFromBothEdges() {
        let route = EdgeFlowRoute.points(from: .top, at: CGPoint(x: 500, y: 13),
                                         to: .right, at: CGPoint(x: 987, y: 300),
                                         size: screen, depth: 26)
        XCTAssertEqual(route[1], CGPoint(x: 987, y: 13))
    }

    func testRightToBottomTurnsTheBottomRightCorner() {
        let route = EdgeFlowRoute.points(from: .right, at: CGPoint(x: 990, y: 300),
                                         to: .bottom, at: CGPoint(x: 500, y: 590),
                                         size: screen, depth: 20)
        XCTAssertEqual(route, [CGPoint(x: 990, y: 300), CGPoint(x: 990, y: 590), CGPoint(x: 500, y: 590)])
    }

    func testBottomToLeftTurnsTheBottomLeftCorner() {
        let route = EdgeFlowRoute.points(from: .bottom, at: CGPoint(x: 500, y: 590),
                                         to: .left, at: CGPoint(x: 10, y: 300),
                                         size: screen, depth: 20)
        XCTAssertEqual(route, [CGPoint(x: 500, y: 590), CGPoint(x: 10, y: 590), CGPoint(x: 10, y: 300)])
    }

    func testTopToBottomGoesTheShorterWayRound() {
        let route = EdgeFlowRoute.points(from: .top, at: CGPoint(x: 200, y: 10),
                                         to: .bottom, at: CGPoint(x: 300, y: 590),
                                         size: screen, depth: 20)
        XCTAssertEqual(route.map(\.x), [200, 10, 10, 300])
    }

    /// The tour's round — right, bottom, left, top, home — never cuts across
    /// the screen: every leg of every hop runs along one side.
    func testEveryHopOfTheRoundHugsTheBezel() {
        let at: [NotchEdge: CGPoint] = [.right: CGPoint(x: 990, y: 300), .bottom: CGPoint(x: 500, y: 590),
                                        .left: CGPoint(x: 10, y: 300), .top: CGPoint(x: 500, y: 10)]
        let round: [NotchEdge] = [.right, .bottom, .left, .top, .right]
        for (from, to) in zip(round, round.dropFirst()) {
            let route = EdgeFlowRoute.points(from: from, at: at[from]!, to: to, at: at[to]!, size: screen, depth: 20)
            for (a, b) in zip(route, route.dropFirst()) {
                XCTAssertTrue(a.x == b.x || a.y == b.y, "\(from) → \(to) cuts across from \(a) to \(b)")
            }
        }
    }

    func testRouteLengthIsTheSumOfItsLegs() {
        let length = EdgeFlowRoute.length(of: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 30), CGPoint(x: 40, y: 30)])
        XCTAssertEqual(length, 70)
    }

    func testSamplingWalksTheRouteRoundItsCorner() {
        let route = [CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let before = EdgeFlowRoute.sample(route, at: 0.25)
        XCTAssertEqual(before.point, CGPoint(x: 0, y: 50))
        XCTAssertEqual(before.tangent, CGPoint(x: 0, y: -1))
        let after = EdgeFlowRoute.sample(route, at: 0.75)
        XCTAssertEqual(after.point, CGPoint(x: 50, y: 0))
        XCTAssertEqual(after.tangent, CGPoint(x: 1, y: 0))
        XCTAssertEqual(EdgeFlowRoute.sample(route, at: 1).point, CGPoint(x: 100, y: 0))
    }

    func testTheDropSetsOutAndLandsAsThePill() {
        // No liquidity at either end of the journey: the body is a capsule
        // of one width there, so the hand-off with the real pill is exact.
        XCTAssertEqual(EdgeFlowView.liquidity(at: 0), 0)
        XCTAssertEqual(EdgeFlowView.liquidity(at: 1), 0)
        XCTAssertEqual(EdgeFlowView.liquidity(at: 0.5), 1, accuracy: 0.0001)
        for step in 1...9 {
            let t = CGFloat(step) / 10
            XCTAssertEqual(EdgeFlowShape.profile(t, time: 3, cap: 0.05, liquidity: 0), 1, accuracy: 0.0001,
                           "a capsule is one width along its body")
        }
        XCTAssertLessThan(EdgeFlowShape.profile(0.01, time: 0, cap: 0.05, liquidity: 0), 0.7, "round tail end")
        XCTAssertLessThan(EdgeFlowShape.profile(0.99, time: 0, cap: 0.05, liquidity: 0), 0.7, "round head end")
    }

    func testTheDropIsRoundAtTheHeadAndThinAtTheTail() {
        let head = EdgeFlowShape.profile(0.75, time: 0)
        let tail = EdgeFlowShape.profile(0.1, time: 0)
        XCTAssertGreaterThan(head, tail * 2, "a liquid, not a pipe")
        XCTAssertLessThan(EdgeFlowShape.profile(1, time: 0), 0.05, "closed at the very head")
        XCTAssertLessThan(EdgeFlowShape.profile(0, time: 0), 0.05, "and at the very tail")
        // Wherever the ripple is, the body is never wider than a bit past
        // the pill and never vanishes mid-length.
        for step in 0...100 {
            let width = EdgeFlowShape.profile(CGFloat(step) / 100, time: 1.3)
            XCTAssertLessThanOrEqual(width, 1.25)
            XCTAssertGreaterThan(width, 0.01)
        }
    }

    @MainActor
    func testTheDropRendersAsOneClosedBody() throws {
        let route = [CGPoint(x: 15, y: 380), CGPoint(x: 15, y: 15), CGPoint(x: 580, y: 15)]
        let window = EdgeFlowMotion.window(progress: 0.45, pillFraction: 0.2)
        let view = ZStack {
            Color(white: 0.85)
            EdgeFlowShape(points: route, tail: window.tail, head: window.head, depth: 30, time: 0.4)
                .fill(MagicFlow.gradient())
            EdgeFlowShape(points: route, tail: window.tail, head: window.head, depth: 30, time: 0.4)
                .stroke(Color.black.opacity(0.4), lineWidth: 1)
        }
        .frame(width: 600, height: 400)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 600)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("edge-flow.png"))
        }
    }

    // MARK: - The drop's motion

    func testTheDropStartsAsThePillAndLandsAsThePill() {
        let start = EdgeFlowMotion.window(progress: 0, pillFraction: 0.1)
        XCTAssertEqual(start.tail, 0, accuracy: 0.0001)
        XCTAssertEqual(start.head, 0.1, accuracy: 0.0001)
        let end = EdgeFlowMotion.window(progress: 1, pillFraction: 0.1)
        XCTAssertEqual(end.tail, 0.9, accuracy: 0.0001)
        XCTAssertEqual(end.head, 1, accuracy: 0.0001)
    }

    func testTheDropStretchesInFlightAndNeverRunsBackwards() {
        var previous = EdgeFlowMotion.window(progress: 0, pillFraction: 0.1)
        var stretched = false
        for step in 1...50 {
            let window = EdgeFlowMotion.window(progress: CGFloat(step) / 50, pillFraction: 0.1)
            XCTAssertGreaterThanOrEqual(window.head, previous.head)
            XCTAssertGreaterThanOrEqual(window.tail, previous.tail)
            XCTAssertGreaterThanOrEqual(window.head - window.tail, 0.1 - 0.0001, "never shorter than the pill")
            if window.head - window.tail > 0.2 { stretched = true }
            previous = window
        }
        XCTAssertTrue(stretched)
    }
}

/// A finished session is said from the pill, not by opening the notch.
@MainActor
final class DoneToastTests: XCTestCase {
    private func event(reason: SessionCompletionWatcher.Reason = .finished) -> SessionCompletionWatcher.Event {
        let session = AgentSession(id: "s1", name: "effort-lid", detail: "Terminal",
                                   state: .idle, waitingFor: nil, since: Date(), processID: 4242)
        return SessionCompletionWatcher.Event(session: session, reason: reason, providerID: "claude")
    }

    func testTheCardCheersAFinishAndFlagsAQuestion() {
        let done = DoneToast(event: event(), glyph: .claude)
        XCTAssertTrue(DoneCheer.finished.contains { $0.title == done.title && $0.status == done.status })
        XCTAssertEqual(done.subtitle, "effort-lid · Terminal")
        let blocked = DoneToast(event: event(reason: .blocked), glyph: .claude)
        XCTAssertTrue(DoneCheer.blocked.contains { $0.title == blocked.title && $0.status == blocked.status })
    }

    func testTheSameSessionAlwaysGetsTheSameLineAndDifferentSessionsVary() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        func toast(_ name: String, offset: TimeInterval = 0) -> DoneToast {
            let session = AgentSession(id: name, name: name, detail: "Terminal", state: .idle,
                                       waitingFor: nil, since: since.addingTimeInterval(offset), processID: 1)
            return DoneToast(event: SessionCompletionWatcher.Event(session: session, reason: .finished, providerID: "claude"),
                             glyph: .claude)
        }
        XCTAssertEqual(toast("a").title, toast("a").title)
        let titles = Set((0..<40).map { toast("s\($0)", offset: Double($0) * 300).title })
        XCTAssertGreaterThan(titles.count, 4, "\(titles)")
    }

    func testTheQuestionItselfBeatsTheLine() {
        let session = AgentSession(id: "q", name: "effort-lid", detail: "Terminal", state: .waiting,
                                   waitingFor: "Overwrite README?", since: Date(), processID: 1)
        let toast = DoneToast(event: SessionCompletionWatcher.Event(session: session, reason: .blocked, providerID: "claude"),
                              glyph: .claude)
        XCTAssertEqual(toast.status, "Asking: Overwrite README?")
    }

    func testLinesFitTheCard() {
        for line in DoneCheer.finished + DoneCheer.blocked {
            XCTAssertLessThanOrEqual(line.title.count, 26, line.title)
            XCTAssertLessThanOrEqual(line.status.count, 22, line.status)
        }
    }

    func testClickingTheCardOpensTheSessionItIsAbout() throws {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        var focused: pid_t?
        controller.model.onFocusSession = { focused = $0 }

        controller.showDoneToast(event(), duration: 5)
        let rect = controller.doneToastRectForTesting
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        // `handleClick` takes the window's own bottom-left coordinates.
        controller.handleClick(at: CGPoint(x: rect.midX, y: frame.height - rect.midY))

        XCTAssertEqual(focused, 4242, "the card's own session, by the rows' route")
        XCTAssertNil(controller.model.activeDoneToast, "and the card has said its piece")
        XCTAssertFalse(controller.model.isExpanded)
    }

    /// A click on the pill while the card is up only puts the card away:
    /// opening the notch must never turn into a jump to some terminal.
    func testClickingThePillWhileTheCardIsUpOnlyDismissesIt() throws {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        var focused: pid_t?
        controller.model.onFocusSession = { focused = $0 }

        controller.showDoneToast(event(), duration: 5)
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        // The pill's middle: the folded notch sits on the bezel, centred along.
        let place = NotchPlacement(edge: controller.model.edge, panelSize: frame.size)
        let pill = place.point(along: controller.model.slack + controller.model.shapeLength * controller.model.sizeScale / 2,
                               across: controller.model.restingDepth * controller.model.sizeScale / 2)
        controller.handleClick(at: CGPoint(x: pill.x, y: frame.height - pill.y))

        XCTAssertNil(focused)
        XCTAssertNil(controller.model.activeDoneToast)
    }

    /// The tour takes its demo line down when its step ends, click offer
    /// and all: left up, it came back over the next step's own card.
    func testTheLineCanBeTakenDownAtOnce() throws {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        var focused: pid_t?
        controller.model.onFocusSession = { focused = $0 }
        controller.showDoneToast(event(), duration: 30)

        controller.dismissDoneToast()

        XCTAssertNil(controller.model.activeDoneToast)
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let place = NotchPlacement(edge: controller.model.edge, panelSize: frame.size)
        let pill = place.point(along: controller.model.slack + controller.model.shapeLength * controller.model.sizeScale / 2,
                               across: controller.model.restingDepth * controller.model.sizeScale / 2)
        controller.handleClick(at: CGPoint(x: pill.x, y: frame.height - pill.y))
        XCTAssertNil(focused, "a click on the pill no longer answers a line that is gone")
    }

    func testShowingTheLineDoesNotOpenTheNotch() {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        XCTAssertFalse(controller.model.isExpanded)

        controller.showDoneToast(event(), duration: 5)

        XCTAssertNotNil(controller.model.activeDoneToast)
        XCTAssertFalse(controller.model.isExpanded, "the announcement must not get in the way of the work")
    }

    func testTheCardRendersBesideThePill() throws {
        // Dark, as the solid panel is: the solid style pins the window to
        // dark aqua, so its text is white on the black card.
        let cards = VStack(spacing: 16) {
            DoneToastView(toast: DoneToast(event: event(), glyph: .claude), direction: .trailing)
            DoneToastView(toast: DoneToast(event: event(reason: .blocked), glyph: .openai), direction: .trailing)
        }
        let renderer = ImageRenderer(content: cards
            .padding(20).background(Color.black)
            .environment(\.notchSurfaceStyle, .solid)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("done-toast.png"))
        }
    }
}
