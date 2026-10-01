import CoreGraphics
import XCTest
@testable import LidEffort

final class GlassSightlineTests: XCTestCase {
    /// A folded pill on the left edge: a few points deep, tall.
    private let pill = CGRect(x: 0, y: 400, width: 8, height: 160)

    private func window(_ bounds: CGRect, pid: pid_t = 100, layer: Int = 0, alpha: Double = 1) -> GlassSightline.Window {
        GlassSightline.Window(pid: pid, layer: layer, alpha: alpha, bounds: bounds)
    }

    func testAWindowUnderTheWholePillIsSeen() {
        let windows = [window(CGRect(x: 0, y: 30, width: 1200, height: 900))]
        XCTAssertTrue(GlassSightline.glassSees(pill, through: windows))
    }

    func testNothingUnderThePillIsTheDesktop() {
        XCTAssertFalse(GlassSightline.glassSees(pill, through: []))
    }

    func testTheWallpaperAndWidgetsAreNotSeen() {
        // Below the normal level: the wallpaper, desktop icons, widgets.
        let screen = CGRect(x: 0, y: 0, width: 1952, height: 1220)
        let windows = [
            window(screen, layer: -2_147_483_625),
            window(screen, layer: -2_147_483_603),
            window(CGRect(x: 0, y: 380, width: 360, height: 200), layer: -2_147_483_601),
        ]
        XCTAssertFalse(GlassSightline.glassSees(pill, through: windows))
    }

    func testAWindowCoveringOnlyPartOfThePillIsNotEnough() {
        // Stage Manager leaves the strip along the edge: the window starts
        // to the right of it, or covers only the top of the pill.
        XCTAssertFalse(GlassSightline.glassSees(pill, through: [window(CGRect(x: 60, y: 0, width: 1000, height: 1000))]))
        XCTAssertFalse(GlassSightline.glassSees(pill, through: [window(CGRect(x: 0, y: 0, width: 1000, height: 480))]))
    }

    func testTwoWindowsTogetherCoverThePill() {
        let windows = [
            window(CGRect(x: 0, y: 0, width: 1000, height: 480)),
            window(CGRect(x: 0, y: 480, width: 1000, height: 500), pid: 200),
        ]
        XCTAssertTrue(GlassSightline.glassSees(pill, through: windows))
    }

    func testBlindAgentsAndInvisibleWindowsHideNothing() {
        let cover = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertFalse(GlassSightline.glassSees(pill, through: [window(cover, pid: 7)], blind: [7]))
        XCTAssertFalse(GlassSightline.glassSees(pill, through: [window(cover, alpha: 0)]))
    }

    func testSamplesRunDownTheLongSide() {
        let tall = GlassSightline.samples(of: pill)
        XCTAssertEqual(tall.count, 5)
        XCTAssertTrue(tall.allSatisfy { $0.x == pill.midX && pill.contains($0) })

        let wide = CGRect(x: 700, y: 0, width: 200, height: 10)
        XCTAssertTrue(GlassSightline.samples(of: wide).allSatisfy { $0.y == wide.midY && wide.contains($0) })
        XCTAssertTrue(GlassSightline.samples(of: .zero).isEmpty)
    }

    func testACardIsSampledAcrossItsWholeFace() {
        let card = CGRect(x: 700, y: 60, width: 300, height: 400)
        let points = GlassSightline.samples(of: card)
        XCTAssertEqual(points.count, 9)
        XCTAssertTrue(points.allSatisfy { card.contains($0) })
        // A window under the left half only: the right-hand column is over
        // the desktop, so the card is.
        let leftHalf = window(CGRect(x: 0, y: 0, width: 850, height: 1000))
        XCTAssertFalse(GlassSightline.glassSees(card, through: [leftHalf]))
        XCTAssertTrue(GlassSightline.glassSees(card, through: [window(CGRect(x: 0, y: 0, width: 1200, height: 1000))]))
    }
}
