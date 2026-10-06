import XCTest
@testable import LidEffort

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var displayIdentifier: String? = nil
}

final class NotchGeometryTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    func testPanelHugsTheRightEdgeAndIsVerticallyCentred() {
        let size = CGSize(width: 334, height: 484)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
        // Centring is allowed to be half a point out: the frame is rounded to
        // whole points so the right-hand edge can be exact, and being flush
        // against the bezel matters where half a point of vertical drift does not.
        XCTAssertEqual(frame.midY, screen.frameValue.midY, accuracy: 0.5)
        XCTAssertEqual(frame.size, size)
    }

    func testPanelFollowsAScreenWithANonZeroOrigin() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        )
        let frame = NotchGeometry.panelFrame(for: secondary, panelSize: CGSize(width: 334, height: 484))
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 920, accuracy: 0.5)
    }

    func testAChosenDisplayWinsOverTheActiveOne() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")
        let chosen = FakeScreen(frameValue: CGRect(x: 100, y: 0, width: 100, height: 100),
                                visibleFrameValue: .zero, displayIdentifier: "chosen")

        let result = NotchGeometry.preferredScreen(
            from: [active, chosen], preference: .display("chosen"), activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "chosen")
    }

    func testADisconnectedChoiceTemporarilyFallsBackToTheActiveDisplay() {
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")

        let result = NotchGeometry.preferredScreen(
            from: [active], preference: .display("missing"), activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "active")
    }

    func testFollowActiveWindowUsesTheActiveDisplay() {
        let first = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                               displayIdentifier: "first")
        let active = FakeScreen(frameValue: .zero, visibleFrameValue: .zero,
                                displayIdentifier: "active")

        let result = NotchGeometry.preferredScreen(
            from: [first, active], preference: .followActiveWindow, activeScreen: active
        )

        XCTAssertEqual(result?.displayIdentifier, "active")
    }
}

/// `alongOffset` is how a ⌥-drag on the pill (`NotchWindowController.dragged`)
/// nudges it off the centred default. These pin down the sign convention —
/// get it wrong and the pill runs away from the cursor instead of following
/// it — and the clamp that keeps a drag from pushing it off the screen.
final class PanelOffsetTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    @MainActor
    func testDraggingToTheTrailingEndKeepsTheSettingsHandleOnScreen() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1169),
            visibleFrameValue: CGRect(x: -1800, y: -200, width: 1800, height: 1132)
        )
        for display in [screen, secondary] {
            for edge in NotchEdge.allCases {
                let model = NotchViewModel()
                model.edge = edge
                let frame = NotchGeometry.panelFrame(
                    for: display, panelSize: model.panelSize, edge: edge,
                    alongOffset: 10_000, slack: model.slack,
                    trailingExtent: model.trailingExtent
                )
                let handleEnd = model.slack + model.orbAlong + NotchLayout.orbHotZone / 2
                if edge.isVertical {
                    XCTAssertGreaterThanOrEqual(frame.maxY - handleEnd,
                                                display.frameValue.minY - 0.5)
                } else {
                    XCTAssertLessThanOrEqual(frame.minX + handleEnd,
                                             display.frameValue.maxX + 0.5)
                }
            }
        }
    }

    func testZeroOffsetChangesNothing() {
        let size = CGSize(width: 334, height: 484)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
        let explicit = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 0)
        XCTAssertEqual(centred, explicit)
    }

    /// A positive offset on a side edge moves the pill *down* — the direction
    /// `NotchWindowController.dragged` feeds it in when the pointer moves
    /// down, since `NSEvent`'s raw delta and AppKit's y-grows-up frame origin
    /// disagree about which way is positive.
    func testPositiveOffsetMovesASideEdgePanelDown() {
        let size = CGSize(width: 334, height: 484)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
        let nudged = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 100)
        XCTAssertEqual(nudged.midY, centred.midY - 100, accuracy: 0.5)
        // Still flush against the right-hand bezel — only the along axis moved.
        XCTAssertEqual(nudged.maxX, centred.maxX, accuracy: 0.001)
    }

    /// A positive offset on a top/bottom edge moves the pill *right* — no sign
    /// flip needed there, since `NSEvent.deltaX` and AppKit's x already agree.
    func testPositiveOffsetMovesATopEdgePanelRight() {
        let size = CGSize(width: 484, height: 120)
        let centred = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top)
        let nudged = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .top, alongOffset: 100)
        XCTAssertEqual(nudged.midX, centred.midX + 100, accuracy: 0.5)
        XCTAssertEqual(nudged.maxY, centred.maxY, accuracy: 0.001)
    }

    /// `slack` is the padding `panelSize` carries beyond the visible pill,
    /// reserved for a hover card that may not be open. Clamping by the full
    /// panel — as if that padding had to stay on screen too — left almost no
    /// room to drag on a panel sized for the worst-case card. Clamping by the
    /// pill's own extent instead should let it travel nearly the whole edge.
    func testAnExtremeOffsetKeepsTheVisiblePillOnScreenRatherThanThePadding() {
        let slack = 400.0
        let size = CGSize(width: 334, height: 900)   // mostly hover-card padding
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: slack
        )
        let pillTop = frame.maxY - slack
        let pillBottom = frame.minY + slack
        XCTAssertLessThanOrEqual(pillTop, screen.frameValue.maxY + 0.5)
        XCTAssertGreaterThanOrEqual(pillBottom, screen.frameValue.minY - 0.5)
    }

    /// Without `slack`'s allowance, the same drag would have clamped to
    /// keeping the *entire* padded panel on screen — which the real bug
    /// report was about: a handful of points of travel on a panel sized for
    /// four providers' worth of hover card.
    func testSlackWidensTheDraggableRangeBeyondClampingTheWholePanel() {
        let size = CGSize(width: 334, height: 900)
        let withoutSlack = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: 0
        )
        let withSlack = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: .right, alongOffset: 10_000, slack: 400
        )
        XCTAssertLessThan(withSlack.minY, withoutSlack.minY)
    }
}

/// A hairline of wallpaper down the right-hand side is all it takes for the
/// notch to read as floating instead of welded to the bezel, and a fractional
/// panel frame is how that happens.
final class PanelEdgeTests: XCTestCase {
    private let screen = FakeScreen(
        frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1132)
    )

    /// The real panel size is fractional — it is derived from the design
    /// frame's pixel ratios — which is exactly the case that used to leave a gap.
    func testAFractionalSizeStillLandsFlushOnTheEdge() {
        let fractional = CGSize(width: 334.3247863247863, height: 205.182905982906)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: fractional)
        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.0001)
    }

    func testTheFrameIsIntegral() {
        let frame = NotchGeometry.panelFrame(
            for: screen,
            panelSize: CGSize(width: 334.3247863247863, height: 205.182905982906)
        )
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(), "\(value) is not a whole point")
        }
    }

    /// Rounding must never make the panel narrower than its content.
    func testItNeverRoundsBelowTheRequestedSize() {
        let requested = CGSize(width: 334.325, height: 205.183)
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: requested)
        XCTAssertGreaterThanOrEqual(frame.width, requested.width)
        XCTAssertGreaterThanOrEqual(frame.height, requested.height)
    }

    func testItStaysFlushOnAScreenWithANonZeroOrigin() {
        let secondary = FakeScreen(
            frameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
            visibleFrameValue: CGRect(x: -2560, y: 200, width: 2560, height: 1415)
        )
        let frame = NotchGeometry.panelFrame(
            for: secondary,
            panelSize: CGSize(width: 334.3247863247863, height: 205.182905982906)
        )
        XCTAssertEqual(frame.maxX, 0, accuracy: 0.0001)
    }
}

/// Use an offset monitor and reserve desktop space on every side so accidental
/// dependencies on the primary display or visibleFrame are caught together.
final class ScreenAnchorRegressionTests: XCTestCase {
    func testEveryEdgeIgnoresDesktopReservationsAtEveryDragPosition() {
        let full = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let shown = FakeScreen(frameValue: full,
                               visibleFrameValue: full.insetBy(dx: 90, dy: 70))
        let hidden = FakeScreen(frameValue: full, visibleFrameValue: full)
        for edge in NotchEdge.allCases {
            let size = NotchPlacement.panelSize(edge: edge, length: 800, depth: 300)
            for offset: CGFloat in [-10000, -230, 0, 310, 10000] {
                let frame = NotchGeometry.panelFrame(for: shown, panelSize: size,
                                                     edge: edge, alongOffset: offset, slack: 200)
                XCTAssertEqual(frame, NotchGeometry.panelFrame(for: hidden, panelSize: size,
                                                                edge: edge, alongOffset: offset, slack: 200))
                switch edge {
                case .left: XCTAssertEqual(frame.minX, full.minX)
                case .right: XCTAssertEqual(frame.maxX, full.maxX)
                case .top: XCTAssertEqual(frame.maxY, full.maxY)
                case .bottom: XCTAssertEqual(frame.minY, full.minY)
                }
            }
        }
    }

    @MainActor func testCornerTooltipsStayInsideTheVisiblePartOfThePanel() {
        for size in NotchSize.allCases {
            for edge in NotchEdge.allCases {
                let model = NotchViewModel()
                model.edge = edge
                model.sizeScale = size.scale
                let length: CGFloat = edge.isVertical ? 300 : NotchLayout.cardWidth
                let ring = model.slack + model.ringCenter(index: 0) * size.scale
                XCTAssertEqual(model.tooltipAlong(index: 0, length: length), ring)
                // Both ends of the screen: the ring remains on screen, while a
                // card centred on it would lose its heading or its right edge.
                for range in [(ring - 45)...(ring + 900), (ring - 900)...(ring + 45)] {
                    model.visibleAlongRange = range
                    let centre = model.tooltipAlong(index: 0, length: length)
                    XCTAssertGreaterThanOrEqual(centre - length / 2, range.lowerBound - 0.0001)
                    XCTAssertLessThanOrEqual(centre + length / 2, range.upperBound + 0.0001)
                    XCTAssertNotEqual(centre, ring)
                    XCTAssertLessThanOrEqual(abs(ring - centre), length / 2 - NotchLayout.tailHeight / 2)
                }
                model.visibleAlongRange = (ring - 900)...(ring + 900)
                XCTAssertEqual(model.tooltipAlong(index: 0, length: length), ring)
            }
        }
    }
}

/// The size choice reaches the screen in the notch's own measurements, never
/// in the tooltip's. These pin the seam between the two.
final class ScaledMeasurementTests: XCTestCase {
    /// A scaled panel is still a panel: it has to land flush on the bezel like
    /// any other, or a large notch floats a hairline off the edge.
    func testAScaledPanelStillLandsFlushOnTheEdge() {
        let screen = FakeScreen(frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1000),
                                visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1000))
        let frame = NotchGeometry.panelFrame(
            for: screen,
            panelSize: CGSize(width: 200, height: 750),
            edge: .right
        )

        XCTAssertEqual(frame.maxX, 1800, accuracy: 0.001)
    }

    /// The notch's own end margin scales; the room reserved for the card does
    /// not. Scaling both would reserve space for a card that is never that big,
    /// and at the small end would reserve less than the card needs.
    func testSlackScalesTheNotchsMarginAndNotTheCards() {
        let cardBound = NotchLayout.slack(for: .right, maxCardHeight: 2000)
        XCTAssertEqual(NotchLayout.slack(for: .right, maxCardHeight: 2000, notchScale: 0.8),
                       cardBound,
                       "the card's half-extent was scaled with the notch")

        let marginBound = NotchLayout.slack(for: .right, maxCardHeight: 0)
        XCTAssertEqual(NotchLayout.slack(for: .right, maxCardHeight: 0, notchScale: 2),
                       marginBound * 2, accuracy: 0.001)
    }
}

/// "Follow the window you are typing in": which display that window is on,
/// from the window server's bounds — the layout this was found on: the
/// laptop as the menu-bar display, a monitor above it, another to the right.
final class ActiveWindowScreenTests: XCTestCase {
    private let laptop = FakeScreen(frameValue: CGRect(x: 0, y: 0, width: 1920, height: 1200),
                                    visibleFrameValue: CGRect(x: 0, y: 0, width: 1920, height: 1170))
    private let above = FakeScreen(frameValue: CGRect(x: 0, y: 1200, width: 1920, height: 1080),
                                   visibleFrameValue: CGRect(x: 0, y: 1200, width: 1920, height: 1080))
    private let right = FakeScreen(frameValue: CGRect(x: 1920, y: 120, width: 1920, height: 1080),
                                   visibleFrameValue: CGRect(x: 1920, y: 120, width: 1920, height: 1080))
    private var screens: [FakeScreen] { [laptop, above, right] }

    private func display(of windowServerRect: CGRect) -> CGRect? {
        let rect = NotchGeometry.cocoaRect(fromWindowServer: windowServerRect, primaryHeight: 1200)
        return NotchGeometry.screen(holding: rect, in: screens)?.frameValue
    }

    func testTheWindowsDisplayIsFoundFromWindowServerBounds() {
        // Chrome on the laptop: y 33 down from the top of the menu-bar display.
        XCTAssertEqual(display(of: CGRect(x: 0, y: 33, width: 1920, height: 1167)), laptop.frameValue)
        // Claude full screen on the monitor above: negative y in that space.
        XCTAssertEqual(display(of: CGRect(x: 0, y: -1080, width: 1920, height: 1080)), above.frameValue)
        // A window on the right-hand monitor.
        XCTAssertEqual(display(of: CGRect(x: 2100, y: 300, width: 800, height: 600)), right.frameValue)
        // Straddling two: the one holding most of it.
        XCTAssertEqual(display(of: CGRect(x: 1700, y: 300, width: 800, height: 600)), right.frameValue)
        // Off every display.
        XCTAssertNil(display(of: CGRect(x: -5000, y: -5000, width: 100, height: 100)))
    }

    func testAStripOfChromeIsNotTheWindow() {
        let titleBar = CGRect(x: 0, y: -1112, width: 1920, height: 32)
        let window = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(NotchGeometry.activeWindow(among: [titleBar, window]), window)
        XCTAssertNil(NotchGeometry.activeWindow(among: [titleBar]))
    }

    func testAChosenDisplayStillWinsOverTheActiveWindow() {
        let chosen = FakeScreen(frameValue: above.frameValue, visibleFrameValue: above.visibleFrameValue,
                                displayIdentifier: "above")
        let result = NotchGeometry.preferredScreen(from: [laptop, chosen], preference: .display("above"),
                                                   activeScreen: laptop)
        XCTAssertEqual(result?.frameValue, above.frameValue)
        XCTAssertEqual(NotchGeometry.preferredScreen(from: [laptop, chosen], preference: .followActiveWindow,
                                                     activeScreen: chosen)?.frameValue, above.frameValue)
    }
}
