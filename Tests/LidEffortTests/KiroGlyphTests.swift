import XCTest
@testable import LidEffort

/// The mark is flattened from Kiro's own SVG, so its geometry is pinned: three
/// loops (a head and two eye holes), inside the unit box.
final class KiroGlyphTests: XCTestCase {
    func testTheOutlineIsThreeLoopsInsideTheUnitBox() {
        let outline = GlyphOutline.kiro
        XCTAssertEqual(outline.count, 3, "one outer loop and two eye holes")
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        for loop in outline {
            for point in loop {
                XCTAssertTrue(point.x >= 0 && point.x <= 1, "x \(point.x) outside the unit box")
                XCTAssertTrue(point.y >= 0 && point.y <= 1, "y \(point.y) outside the unit box")
                xs.append(point.x)
                ys.append(point.y)
            }
        }
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        XCTAssertEqual(span, 1, accuracy: 0.01)
    }

    func testTheMarkMatchesTheProviderGlyph() {
        XCTAssertEqual(ProviderGlyph.kiro.rawValue, "kiro")
        XCTAssertEqual(ProviderGlyph.kiro.outline, GlyphOutline.kiro)
        XCTAssertEqual(ProviderGlyph.kiro.assetName, "glyph-kiro")
    }
}
