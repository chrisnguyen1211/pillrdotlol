import SwiftUI
import XCTest
@testable import LidEffort

/// A MacBook's own notch, as this machine reports it.
private let realNotch = HardwareNotch(width: 220, height: 38)

private struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect
    var hardwareNotch: HardwareNotch?
}

private let notched = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 59, width: 1800, height: 1071),
    hardwareNotch: realNotch
)

private let plain = FakeScreen(
    frameValue: CGRect(x: 0, y: 0, width: 1800, height: 1169),
    visibleFrameValue: CGRect(x: 0, y: 0, width: 1800, height: 1144),
    hardwareNotch: nil
)

/// On a Mac that has a notch of its own, a top-edge pillr runs up to meet
/// it so the two read as one shape rather than as a bar parked underneath.
final class HardwareNotchGeometryTests: XCTestCase {
    private let size = CGSize(width: 700, height: 200)

    func testATopNotchRunsUpToTheRealTopToMeetTheHardware() {
        let frame = NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, notched.frameValue.maxY, accuracy: 0.001,
                       "it stopped below the menu bar instead of meeting the notch")
    }

    func testWithoutOneItStillReachesThePhysicalTopEdge() {
        let frame = NotchGeometry.panelFrame(for: plain, panelSize: size, edge: .top)
        XCTAssertEqual(frame.maxY, plain.frameValue.maxY, accuracy: 0.001)
    }

    /// Hardware merging only affects the top edge.
    func testTheOtherEdgesAreUnaffectedByIt() {
        XCTAssertEqual(
            NotchGeometry.panelFrame(for: notched, panelSize: size, edge: .bottom).minY,
            notched.frameValue.minY, accuracy: 0.001
        )
        XCTAssertEqual(
            NotchGeometry.panelFrame(for: notched, panelSize: CGSize(width: 300, height: 700), edge: .right).maxX,
            notched.frameValue.maxX, accuracy: 0.001
        )
    }

    func testItReadsTheNotchFromTheAreasEitherSideOfIt() {
        XCTAssertEqual(realNotch.width, 220, accuracy: 0.001)
        XCTAssertEqual(realNotch.height, 38, accuracy: 0.001)
    }
}

/// Merging costs two things, and forgetting either one is what makes it look
/// broken rather than joined.
@MainActor
final class MergedTopNotchTests: XCTestCase {
    private func model(cells: Int, screen: ScreenDescribing = notched,
                       edge: NotchEdge = .top) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: screen)
        return model
    }

    // MARK: - The band behind the hardware

    /// The first cost: the top of the shape is behind a *hole in the screen*.
    /// Anything drawn there is not dim or clipped, it is simply not there.
    func testNothingIsDrawnInsideTheHardwareNotchesOwnBand() {
        let model = model(cells: 4)
        XCTAssertGreaterThanOrEqual(
            model.contentInset, realNotch.height,
            "the rings would be drawn behind the hole in the display"
        )
    }

    /// The shape gets deeper by that band plus the gap below it, so the
    /// readings sit where they always did relative to the black around them.
    func testTheShapeGrowsByTheBandItHasToClear() {
        let merged = model(cells: 4).notchDepth
        let plainTop = model(cells: 4, screen: plain).notchDepth
        XCTAssertEqual(merged - plainTop, realNotch.height, accuracy: 0.001)
    }

    /// Folded away, it *is* the hardware notch — same width, same height.
    ///
    /// The resting pill is the wrong object here. It hangs below the hardware
    /// as a separate little tab, which is exactly the seam the whole placement
    /// exists to remove. Matching the notch instead means the app shows nothing
    /// at all at rest, and hovering makes the notch itself grow.
    func testFoldedAwayItIsExactlyTheHardwareNotch() {
        let m = model(cells: 4)
        m.isExpanded = false
        XCTAssertEqual(m.notchLength, realNotch.width, accuracy: 0.001,
                       "the resting shape is not the notch's width")
        XCTAssertEqual(m.notchDepth, realNotch.height, accuracy: 0.001,
                       "the resting shape is not the notch's height")
    }

    /// Which means nothing of it hangs below the hardware to be seen.
    func testNothingOfItShowsBelowTheHardwareAtRest() {
        let m = model(cells: 4)
        m.isExpanded = false
        XCTAssertLessThanOrEqual(m.notchDepth, realNotch.height,
                                 "part of the resting shape hangs below the hardware")
    }

    /// Opening it grows the notch rather than replacing it.
    func testOpeningGrowsItOnBothAxes() {
        let m = model(cells: 4)
        m.isExpanded = false
        let (restLength, restDepth) = (m.notchLength, m.notchDepth)
        m.isExpanded = true
        XCTAssertGreaterThan(m.notchLength, restLength)
        XCTAssertGreaterThan(m.notchDepth, restDepth)
    }

    /// A screen without one keeps the pill it always had.
    func testWithoutAHardwareNotchItStillFoldsToItsPill() {
        let m = model(cells: 4, screen: plain)
        m.isExpanded = false
        XCTAssertEqual(m.notchLength, NotchLayout.pillHeight, accuracy: 0.001)
        XCTAssertEqual(m.notchDepth, NotchLayout.pillWidth, accuracy: 0.001)
    }

    /// Nothing below the hardware wakes it.
    ///
    /// The pill's band exists because a 10pt sliver is hard to hit. The notch
    /// is 220 by 38 and needs no help — and the band it inherited ran 34pt
    /// below the menu bar, across the title bar of a window tiled to the
    /// centre of the screen. Aiming at that window's close button opened the
    /// notch on top of the button.
    func testWhatWakesItIsExactlyTheHardwareNotch() {
        let m = model(cells: 4)
        m.isExpanded = false
        XCTAssertEqual(m.wakeLength, realNotch.width, accuracy: 0.001,
                       "the wake region is wider than the hardware")
        XCTAssertEqual(m.wakeDepth, realNotch.height, accuracy: 0.001,
                       "the wake region reaches below the hardware, into the window under it")
    }

    /// The pill keeps its band: it is the small target the band was made for.
    func testThePillIsStillWokenByABandAroundIt() {
        let m = model(cells: 4, screen: plain)
        m.isExpanded = false
        XCTAssertGreaterThan(m.wakeDepth, m.restingDepth,
                             "the pill lost the band that makes it hittable")
        XCTAssertGreaterThanOrEqual(m.wakeLength, m.restingLength)
    }

    func testAScreenWithoutOneInsetsNothing() {
        XCTAssertEqual(model(cells: 4, screen: plain).contentInset, 0, accuracy: 0.001)
        for edge in [NotchEdge.right, .left, .bottom] {
            XCTAssertEqual(model(cells: 4, edge: edge).contentInset, 0, accuracy: 0.001,
                           "\(edge) has no hardware notch to clear")
        }
    }

    // MARK: - Being at least as wide as the thing it joins

    /// The second cost: a single ring makes a bar about 194pt across, and this
    /// Mac's notch is 220. Left alone the hardware would be *wider* than the
    /// shape that is supposed to be it, sticking out either side.
    ///
    /// Measured on the drawn shape rather than on the body: with the flares
    /// gone, the shape's whole length is what meets the screen's top edge, and
    /// that is what has to clear the hardware.
    func testTheDrawnBarIsNeverNarrowerThanTheHardwareNotch() {
        for count in 1...5 {
            XCTAssertGreaterThanOrEqual(
                model(cells: count).shapeLength, realNotch.width,
                "\(count) cells: the hardware notch is wider than the shape replacing it"
            )
        }
    }

    /// Widening is done evenly, so the readings stay in the middle of the bar.
    func testTheStackStaysCentredWhileTheBodyIsWidened() {
        for count in 1...5 {
            let model = model(cells: count)
            let first = model.ringCenter(index: 0)
            let last = model.ringCenter(index: count - 1)
            XCTAssertEqual(first, model.shapeLength - last, accuracy: 0.5,
                           "\(count) cells: widening pushed the stack off centre")
        }
    }

    /// Once the stack is wide enough on its own, nothing is added to it.
    ///
    /// Compared against zero rather than against an unmerged notch: the two are
    /// no longer the same length even with no widening, because a flush bar
    /// reserves only the small frame corner at its ends where a flared one
    /// reserves a whole `curlRadius`.
    func testAWideStackIsLeftAlone() {
        // Nothing past the room each end keeps for its handle.
        for cells in [4, 5] {
            let m = model(cells: cells)
            XCTAssertEqual(m.endSpread, m.inlineRoom, accuracy: 0.001, "\(cells) cells")
        }
    }

    func testASideEdgeIsNeverWidenedForIt() {
        for edge in [NotchEdge.right, .left] {
            XCTAssertEqual(model(cells: 1, edge: edge).endSpread, 0, accuracy: 0.001, "\(edge)")
        }
        // The bottom hangs from its bezel too, so it keeps room for its
        // handles — but it is never widened for a notch it cannot meet.
        let bottom = model(cells: 1, edge: .bottom)
        XCTAssertEqual(bottom.endSpread, bottom.inlineRoom, accuracy: 0.001)
    }
}

/// Where the merged shape actually puts its edges.
@MainActor
final class MergedShapeTests: XCTestCase {
    private let inset = realNotch.height

    private func model(cells: Int = 4) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: notched)
        return model
    }

    /// The stretch that runs up behind the hardware is a straight extension of
    /// the bar, not part of its flare.
    ///
    /// Left as an ordinary deeper shape, the flares — which live in the first
    /// `curlRadius` from the bezel, and this Mac's notch is almost exactly that
    /// tall — would be drawn entirely inside the hole. The bar would emerge
    /// from the hardware with square corners, and the settings orb, which is
    /// concentric with the flare, would be invisible with it.
    /// **The bar is shaped like the Mac's own notch, only bigger.**
    ///
    /// Straight sides meeting the bezel square, two rounded corners at the
    /// bottom, nothing else. The flares are what make this shape read as
    /// growing out of an edge, and that is exactly wrong here: the hardware
    /// notch does not taper. Match it and the display's own notch stops being a
    /// separate object — it simply looks wider and deeper.
    func testItMeetsTheBezelSquareAcrossItsWholeWidth() {
        let m = model()
        let size = m.notchSize
        guard let atBezel = span(of: m, at: 0.3) else { return XCTFail("nothing at the bezel") }

        XCTAssertEqual(atBezel.lowerBound, 0, accuracy: 3,
                       "the bar does not reach the top of the screen")
        XCTAssertEqual(atBezel.upperBound, size.width - 1, accuracy: 3,
                       "the bar does not reach the top of the screen")
    }

    /// Straight-sided between its two corner details: the small one into the
    /// screen's frame at the top, and its own rounding at the bottom. Anything
    /// varying in between would read as two shapes stacked.
    func testItKeepsTheSameWidthBetweenItsCorners() {
        let m = model()
        guard let reference = span(of: m, at: NotchLayout.bezelFillet + 2) else {
            return XCTFail("nothing below the frame corner")
        }
        for across in stride(from: NotchLayout.bezelFillet + 2,
                             to: m.notchDepth - NotchLayout.cornerRadius, by: 4) {
            guard let band = span(of: m, at: across) else {
                return XCTFail("the bar has a gap at depth \(across)")
            }
            XCTAssertEqual(band.lowerBound, reference.lowerBound, accuracy: 2,
                           "the bar changes width at depth \(across)")
            XCTAssertEqual(band.upperBound, reference.upperBound, accuracy: 2,
                           "the bar changes width at depth \(across)")
        }
    }

    /// The corner into the frame is a detail, not a taper: what it takes off
    /// the bar's width is a small fraction of it.
    func testTheFrameCornerBarelyNarrowsTheBar() {
        let m = model()
        guard let atFrame = span(of: m, at: 0.5),
              let below = span(of: m, at: NotchLayout.bezelFillet + 2) else {
            return XCTFail("no shape to measure")
        }
        let lost = (below.lowerBound - atFrame.lowerBound)
            + (atFrame.upperBound - below.upperBound)
        XCTAssertLessThan(lost / (atFrame.upperBound - atFrame.lowerBound), 0.12,
                          "the corner into the frame is tapering the bar")
    }

    /// And it is rounded off at the bottom, the way the hardware notch is.
    func testItsBottomCornersAreRounded() {
        let m = model()
        guard let atBezel = span(of: m, at: 1),
              let atFoot = span(of: m, at: m.notchDepth - 2) else {
            return XCTFail("no shape to measure")
        }
        let pulledIn = (atFoot.lowerBound - atBezel.lowerBound)
        XCTAssertGreaterThan(pulledIn, NotchLayout.cornerRadius / 2,
                             "the bar has square corners at the bottom")
        XCTAssertEqual(atFoot.lowerBound - atBezel.lowerBound,
                       atBezel.upperBound - atFoot.upperBound, accuracy: 2,
                       "the bottom corners do not match each other")
    }

    /// Sampled rather than probed: a single point can land exactly on a
    /// construction line, where `contains` is a coin toss.
    private func span(of m: NotchViewModel, at across: CGFloat) -> ClosedRange<CGFloat>? {
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = SideNotchShape(edge: .top, joining: m.joinedNotch)
            .path(in: CGRect(origin: .zero, size: size))
        let hits = stride(from: CGFloat(0), to: size.width, by: 1)
            .filter { path.contains(place.point(along: $0, across: across)) }
        guard let first = hits.first, let last = hits.last else { return nil }
        return first...last
    }

    /// Every other edge keeps the flares the design frame drew.
    func testTheOtherEdgesKeepTheirFlares() {
        let flared = SideNotchShape(edge: .top, joining: nil)
            .path(in: CGRect(x: 0, y: 0, width: 400, height: 140))
        let place = NotchPlacement(edge: .top, panelSize: CGSize(width: 400, height: 140))
        XCTAssertFalse(
            flared.contains(place.point(along: 2, across: NotchLayout.curlRadius + 4)),
            "the flare is missing from an ordinary notch"
        )
    }

    /// Wherever the orb ends up, all of it has to be below the hardware — the
    /// part of it inside that band is not dimmed, it is off the display.
    func testTheWholeOrbSitsBelowTheHardwareNotch() {
        let m = model()
        XCTAssertGreaterThan(m.orbInset - NotchLayout.inlineOrbDiameter / 2, realNotch.height,
                             "part of the handle is inside the hole")
    }

    /// And the card hangs off the inner face of a shape that is now deeper.
    func testTheTooltipClearsTheDeeperShape() {
        let m = model()
        XCTAssertEqual(
            m.tooltipInset, m.contentInset + m.bodyDepth + NotchLayout.tailGap,
            accuracy: 0.001
        )
    }
}

/// Hung from the bezel, the bar has no flare pocket for an arc to trace, and
/// an arc hugging its corners read as a pair of brackets round the readings.
/// So the handles ride inside the bar, one square in each end, on the rings'
/// own line — with a hardware notch or without one.
@MainActor
final class HandlesInsideTheBarTests: XCTestCase {
    private func model(notch: Bool, cells: Int = 4, edge: NotchEdge = .top) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = edge
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: notch ? notched : plain)
        return model
    }

    func testTheyAreInsideTheBarOnTheRingsLine() {
        for notch in [true, false] {
            let m = model(notch: notch)
            XCTAssertTrue(m.orbsInline)
            XCTAssertLessThan(m.orbAlong + NotchLayout.inlineOrbDiameter / 2, m.shapeLength - m.flare, "\(notch)")
            XCTAssertGreaterThan(m.moveAlong - NotchLayout.inlineOrbDiameter / 2, m.flare, "\(notch)")
            XCTAssertEqual(m.orbInset, m.contentInset + m.bodyDepth / 2, accuracy: 0.001,
                           "not level with the rings")
        }
    }

    /// Square in the end: as far from the end of the bar's straight run as
    /// from its lower edge.
    func testEachSitsSquareInItsEnd() {
        let m = model(notch: false)
        let fromEnd = (m.shapeLength - m.flare) - (m.orbAlong + NotchLayout.inlineOrbDiameter / 2)
        let fromFoot = m.notchDepth - (m.orbInset + NotchLayout.inlineOrbDiameter / 2)
        XCTAssertEqual(fromEnd, fromFoot, accuracy: 0.001)
    }

    /// One rhythm end to end: handle to first ring is the rings' own spacing.
    func testTheFirstRingIsARingsSpacingFromTheHandle() {
        for notch in [true, false] {
            let m = model(notch: notch, cells: 5)
            let gap = (m.ringCenter(index: 0) - NotchLayout.ringDiameter / 2)
                - (m.moveAlong + NotchLayout.inlineOrbDiameter / 2)
            XCTAssertEqual(gap, NotchLayout.inlineOrbGap, accuracy: 0.001, "\(notch)")
        }
    }

    /// Spread to cover a hardware notch, the rings stay centred and the
    /// handles ride the ends of the bar rather than the ends of the rings.
    func testAWidenedBarKeepsTheHandlesAtItsEnds() {
        let m = model(notch: true, cells: 1)
        XCTAssertGreaterThan(m.endSpread, m.inlineRoom, "one ring is narrower than the notch")
        XCTAssertEqual(m.ringCenter(index: 0), m.shapeLength / 2, accuracy: 0.5)
        XCTAssertEqual(m.moveAlong, m.shapeLength - m.orbAlong, accuracy: 0.001)
        XCTAssertLessThan(m.moveAlong, m.ringCenter(index: 0) - NotchLayout.ringDiameter,
                          "the handle crowds the ring instead of riding the end")
    }

    /// Reachable, and only where drawn: not from the first ring.
    func testTheHandleAnswersOnItselfAndNotOnTheRing() {
        let m = model(notch: true)
        XCTAssertTrue(m.isOnOrbHandle(along: m.orbAlong, across: m.orbInset))
        XCTAssertTrue(m.isOnMoveHandle(along: m.moveAlong, across: m.orbInset))
        let last = m.ringCenter(index: m.snapshots.count - 1)
        XCTAssertFalse(m.isOnOrbHandle(along: last, across: m.orbInset))
        XCTAssertFalse(m.isOnMoveHandle(along: m.ringCenter(index: 0), across: m.orbInset))
    }

    /// Down a side it is still the capsule, the orbs on its axis past each end.
    func testTheCapsuleSeatsTheOrbOnItsAxisPastTheEnd() {
        let m = model(notch: false, edge: .right)
        XCTAssertFalse(m.orbsInline)
        let end = m.shapeLength - m.flare
        XCTAssertEqual(m.orbAlong, end + NotchLayout.orbGap + NotchLayout.orbDiameter / 2, accuracy: 0.001)
        XCTAssertLessThan(m.orbAlong + NotchLayout.orbDiameter / 2, m.shapeLength + m.slack)
        XCTAssertEqual(m.orbInset, m.bodyDepth / 2, accuracy: 0.001)
    }

    func testTheArcIsConcentricWithTheCapsuleEnd() {
        let m = model(notch: false, edge: .right)
        let along = m.edge.alongDirection
        let offsetAlong = m.orbArcOffset.width * along.x + m.orbArcOffset.height * along.y
        XCTAssertEqual(m.orbAlong + offsetAlong, m.cornerCentreAlong, accuracy: 0.001)
        XCTAssertEqual(m.orbArcRadius - m.drawnCornerRadius, NotchLayout.pillArcGap, accuracy: 0.001)
    }

    /// Which is the concave arrangement through half a circle, on every edge.
    func testHuggingFromOutsideIsTheSameRelationshipTurnedAround() {
        for edge in NotchEdge.allCases {
            let concave = SettingsOrb.restingTrim(for: edge).lowerBound
            let convex = SettingsOrb.restingTrim(for: edge, convex: true).lowerBound
            let turned = (concave + 0.5).truncatingRemainder(dividingBy: 1)
            XCTAssertEqual(convex, turned, accuracy: 0.0001, "\(edge)")
        }
    }
}

/// Nothing of the readings may fall inside the hardware's band, and the shape
/// should meet the screen's frame with a corner rather than a raw edge.
@MainActor
final class HardwareClearanceTests: XCTestCase {
    private func model(cells: Int = 4, style: NotchSurfaceStyle = .solid) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        // The solid style is the default here because `ImageRenderer` has no
        // desktop behind it to refract, so glass renders as very little. The
        // glass style still gets its own case: there the band is painted by a
        // layer of its own, so it can regress on its own too.
        model.surfaceStyle = style
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "S", usedFraction: 0.4)],
                             headlineID: "w")
        }
        model.adopt(screen: notched)
        return model
    }

    /// The bug this pins: the cells were *centred* in a shape that had been made
    /// deeper, rather than pushed past the band that made it deeper. They ended
    /// up 19pt from the top instead of 38, so the top of every ring was inside
    /// the hole — which is what "the notch is blocking the rings" looks like.
    func testTheHardwaresBandHoldsNothingButBlack() {
        assertTheBandHoldsNothingButBlack(model())
    }

    /// The glass surface paints the band with a layer of its own, so it can go
    /// wrong on its own: without it the cutout reads as a black rectangle set
    /// into a sheet of glass.
    func testTheHardwaresBandStaysBlackInTheGlassStyle() {
        assertTheBandHoldsNothingButBlack(model(style: .glass))
    }

    private func assertTheBandHoldsNothingButBlack(
        _ m: NotchViewModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        let size = m.notchSize
        let renderer = ImageRenderer(
            content: NotchRootView(model: m).frame(width: m.panelSize.width,
                                                   height: m.panelSize.height)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage, let rep = NSBitmapImageRep(cgImage: image).cgImage
        else { return XCTFail("nothing rendered", file: file, line: line) }
        let bitmap = NSBitmapImageRep(cgImage: rep)

        let place = NotchPlacement(edge: .top, panelSize: m.panelSize)
        for across in stride(from: CGFloat(1), to: realNotch.height, by: 2) {
            for along in stride(from: CGFloat(0), to: size.width, by: 3) {
                let point = place.point(along: m.slack + along, across: across)
                guard let colour = bitmap.colorAt(x: Int(point.x), y: Int(point.y)),
                      colour.alphaComponent > 0.5 else { continue }
                // Black is the notch itself. Anything else is a ring, a track
                // or a label drawn where the display has a hole in it.
                XCTAssertLessThan(
                    colour.brightnessComponent, 0.05,
                    "something is drawn inside the hardware notch at (\(along), \(across))",
                    file: file, line: line
                )
            }
        }
    }

    /// **The hardware's bottom edge is the bezel, as far as the readings are
    /// concerned.** So a ring sits exactly the frame's own margin from it —
    /// the same distance it sits from the screen edge on every other placement.
    ///
    /// Anything on top of that is padding twice: an earlier version added a
    /// deliberate gap as well, and the readings ended up adrift of the notch
    /// they are supposed to belong to.
    func testTheRingsSitTheFramesOwnMarginFromTheHardware() {
        let m = model()
        let ringTop = m.contentInset + NotchLayout.ringMargin(for: .top)
        XCTAssertEqual(ringTop - realNotch.height, NotchLayout.ringMargin(for: .top),
                       accuracy: 0.001,
                       "the readings are padded away from the hardware twice over")
    }

    /// Which is the same margin the ring has from the bezel anywhere else.
    func testItIsTheSameMarginEveryOtherPlacementUses() {
        XCTAssertEqual(NotchLayout.ringMargin(for: .top),
                       NotchLayout.ringMargin(for: .right), accuracy: 0.001)
    }

    /// The shape meets the screen's frame with a small inverse corner, the way
    /// the hardware notch is moulded into the bezel rather than cut out of it.
    /// Small: enough to round the join, not enough to taper the bar.
    func testItMeetsTheScreensFrameWithACorner() {
        let m = model()
        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = SideNotchShape(edge: .top, joining: realNotch).path(in: CGRect(origin: .zero, size: size))

        func span(at across: CGFloat) -> ClosedRange<CGFloat>? {
            let hits = stride(from: CGFloat(0), to: size.width, by: 1)
                .filter { path.contains(place.point(along: $0, across: across)) }
            guard let first = hits.first, let last = hits.last else { return nil }
            return first...last
        }
        guard let atFrame = span(at: 0.5),
              let belowIt = span(at: NotchLayout.bezelFillet + 2) else {
            return XCTFail("no shape to measure")
        }
        XCTAssertEqual(atFrame.lowerBound, 0, accuracy: 3,
                       "the shape does not reach the screen's frame")
        let pulledIn = belowIt.lowerBound - atFrame.lowerBound
        XCTAssertEqual(pulledIn, NotchLayout.bezelFillet, accuracy: 2,
                       "the corner into the frame is missing")
        XCTAssertLessThan(NotchLayout.bezelFillet, NotchLayout.cornerRadius,
                          "the corner is big enough to taper the bar")
    }
}

/// The bar should reserve no more room at its ends than it actually draws there.
@MainActor
final class BarEndMarginTests: XCTestCase {
    private func model(cells: Int = 4, screen: ScreenDescribing = notched) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: screen)
        return model
    }

    /// The bug: `shapeLength` reserves a full `curlRadius` at each end for the
    /// flares, and a flush bar draws only the small corner into the frame. The
    /// difference — some 56pt across the pair — became dead black either side of
    /// the readings, which is what made the top bar look so wide.
    func testItReservesOnlyWhatItDraws() {
        let m = model()
        let reserved = (m.shapeLength - m.bodyLength) / 2

        let size = m.notchSize
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = SideNotchShape(edge: .top, joining: m.joinedNotch)
            .path(in: CGRect(origin: .zero, size: size))
        let probe = NotchLayout.bezelFillet + 4
        let drawn = stride(from: CGFloat(0), to: size.width, by: 1)
            .first { path.contains(place.point(along: $0, across: probe)) } ?? -1

        XCTAssertEqual(reserved, drawn, accuracy: 3,
                       "the bar reserves \(reserved)pt at each end but draws \(drawn)pt")
    }

    /// Which reads, at the ends, as a margin in proportion to the readings
    /// rather than one that dwarfs them.
    func testTheMarginBesideTheFirstRingIsProportionate() {
        // What is beside the first ring is its handle and a ring's spacing —
        // no black beyond that.
        let m = model()
        let ringEdge = m.ringCenter(index: 0) - NotchLayout.ringDiameter / 2
        let handle = m.flare + m.inlineOrbEndPad + NotchLayout.inlineOrbDiameter + NotchLayout.inlineOrbGap
        XCTAssertEqual(ringEdge, handle, accuracy: 0.001,
                       "there is black beside the first ring beyond its handle")
    }

    /// Still symmetric, and still centred.
    func testTheEndsMatchEachOther() {
        for count in 1...5 {
            let m = model(cells: count)
            XCTAssertEqual(m.ringCenter(index: 0),
                           m.shapeLength - m.ringCenter(index: count - 1),
                           accuracy: 0.5, "\\(count) cells")
        }
    }

    /// Without a hardware notch the top still hangs from the bezel, so it too
    /// reserves only the fillet it draws.
    func testATabWithoutAHardwareNotchReservesOnlyItsFillet() {
        let m = model(screen: plain)
        XCTAssertEqual((m.shapeLength - m.bodyLength) / 2, NotchLayout.bezelFillet,
                       accuracy: 0.001)
    }
}

/// The handle answers where it is drawn, and not in the space around it.
@MainActor
final class OrbHitAccuracyTests: XCTestCase {
    private func model(flush: Bool = true) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.isExpanded = true
        model.snapshots = (0..<4).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: flush ? notched : plain)
        return model
    }

    /// You can reach the button itself.
    func testTheButtonAnswers() {
        let m = model()
        XCTAssertTrue(m.isOnOrbHandle(along: m.orbAlong, across: m.orbInset))
    }

    /// Nor anywhere back inside the bar.
    func testItDoesNotAnswerInsideTheBar() {
        let m = model()
        XCTAssertFalse(m.isOnOrbHandle(along: m.shapeLength / 2, across: m.notchDepth / 2))
    }

    /// Without a hardware notch it is reached the same way: one zone, on the handle.
    func testAPlainTabAnswersOnItsHandle() {
        let m = model(flush: false)
        XCTAssertTrue(m.isOnOrbHandle(along: m.orbAlong, across: m.orbInset))
        XCTAssertFalse(m.isOnOrbHandle(along: m.orbAlong + NotchLayout.orbHotZone,
                                       across: m.orbInset))
    }
}

/// Opening should look like the notch *stretching*, not like one shape turning
/// into another.
@MainActor
final class ExpansionShapeTests: XCTestCase {
    /// How far the shape pulls in at its foot — which is its corner radius.
    private func cornerPullIn(width: CGFloat, depth: CGFloat, corner: CGFloat) -> CGFloat {
        let size = CGSize(width: width, height: depth)
        let place = NotchPlacement(edge: .top, panelSize: size)
        let path = SideNotchShape(edge: .top, joining: realNotch, cornerRadius: corner)
            .path(in: CGRect(origin: .zero, size: size))

        func span(at across: CGFloat) -> ClosedRange<CGFloat>? {
            let hits = stride(from: CGFloat(0), to: width, by: 0.5)
                .filter { path.contains(place.point(along: $0, across: across)) }
            guard let first = hits.first, let last = hits.last else { return nil }
            return first...last
        }
        // The straight section — below the frame fillet, above the corner —
        // against the very bottom, where the corner has run its course. Taken
        // at the same depth from the foot every time, so the figures compare
        // even though neither is the corner's radius outright.
        guard let body = span(at: NotchLayout.bezelFillet + 2),
              let foot = span(at: depth - 0.25) else { return -1 }
        return ((foot.lowerBound - body.lowerBound) + (body.upperBound - foot.upperBound)) / 2
    }

    private func model(expanded: Bool, cells: Int = 4) -> NotchViewModel {
        let model = NotchViewModel()
        model.edge = .top
        model.snapshots = (0..<cells).map { index in
            ProviderSnapshot(id: "p\(index)", displayName: "P", glyph: .claude,
                             fidelity: .official, status: .ok, windows: [])
        }
        model.adopt(screen: notched)
        model.isExpanded = expanded
        return model
    }

    /// Shut, it is the hardware notch, rounding and all.
    func testShutItHasTheHardwaresOwnCorner() {
        let m = model(expanded: false)
        XCTAssertEqual(m.drawnCornerRadius, realNotch.height / 2, accuracy: 0.001)
        let pull = cornerPullIn(width: realNotch.width, depth: realNotch.height, corner: m.drawnCornerRadius)
        XCTAssertEqual(pull, realNotch.height / 2, accuracy: 1.5)
    }

    /// Open, it rounds like the size it has become — the hardware's small
    /// corner on a bar three times as deep read as a box — and never less
    /// round than it was shut, so no frame of the opening squares it off.
    func testOpenItRoundsInProportionToItsDepth() {
        let shut = model(expanded: false).drawnCornerRadius
        let m = model(expanded: true)
        XCTAssertGreaterThanOrEqual(m.drawnCornerRadius, shut)
        XCTAssertEqual(m.drawnCornerRadius,
                       min(NotchLayout.cornerRadius, m.notchDepth * NotchViewModel.tabCornerRatio),
                       accuracy: 0.001)
        let pull = cornerPullIn(width: m.notchSize.width, depth: m.notchDepth, corner: m.drawnCornerRadius)
        XCTAssertEqual(pull, m.drawnCornerRadius, accuracy: 2.5, "the path draws the corner it was given")
    }

    /// The corner is animatable, so it eases between the two with the frame
    /// rather than jumping as the notch opens.
    func testTheCornerIsAnimated() {
        var shape = SideNotchShape(edge: .top, joining: realNotch, cornerRadius: 12)
        shape.animatableData = 20
        XCTAssertEqual(shape.cornerRadius, 20)
    }

    /// It can never be *squarer* than the hardware's own rounding, or the
    /// resting shape's corners poke out past the hole and show as two nubs.
    @MainActor
    func testTheRestingShapeCannotPokeOutOfTheHole() {
        let model = NotchViewModel()
        model.edge = .top
        model.adopt(screen: notched)
        XCTAssertGreaterThanOrEqual(model.drawnCornerRadius, realNotch.height / 2,
                                    "the resting corners are squarer than the hardware's")
    }
}
