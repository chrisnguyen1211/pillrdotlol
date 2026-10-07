import XCTest
@testable import LidEffort

/// The mark is defined rather than traced, so its geometry is pinned: one
/// loop, inside the unit box, reading as a compact M with stroke depth 0.2.
final class MiniMaxGlyphTests: XCTestCase {
    func testTheOutlineIsASingleLoopInsideTheUnitBox() {
        let outline = GlyphOutline.minimax
        XCTAssertEqual(outline.count, 1, "one loop; even-odd fill has no counters to keep open")
        let loop = outline[0]
        XCTAssertEqual(loop.count, 12)
        for point in loop {
            XCTAssertTrue(point.x >= 0 && point.x <= 1, "x \(point.x) outside the unit box")
            XCTAssertTrue(point.y >= 0 && point.y <= 1, "y \(point.y) outside the unit box")
        }
    }

    func testTheMarkMatchesTheProviderGlyph() {
        XCTAssertEqual(ProviderGlyph.minimax.rawValue, "minimax")
        XCTAssertEqual(ProviderGlyph.minimax.outline, GlyphOutline.minimax)
        XCTAssertFalse(ProviderGlyph.minimax.outline.isEmpty,
                       "grouping MiniMax with the asset-only glyphs would draw an empty ring")
        XCTAssertEqual(ProviderGlyph.minimax.assetName, "glyph-minimax")
        XCTAssertEqual(ProviderGlyph.minimax.opticalScale, 0.95)
    }

    /// A ring with no reading still draws the glyph: the shape has to have
    /// ink, or the cell renders an empty ring.
    func testTheOutlineHasInk() {
        let loop = GlyphOutline.minimax[0]
        var area = 0.0
        for (index, point) in loop.enumerated() {
            let next = loop[(index + 1) % loop.count]
            area += Double(point.x * next.y - next.x * point.y)
        }
        XCTAssertGreaterThan(abs(area) / 2, 0.3, "the mark covers less than a third of its box")
    }

    /// Stems and diagonals share one weight, the same bargain as GLM's Z.
    func testTheStrokeDepthIsPointTwo() {
        let loop = GlyphOutline.minimax[0]
        let left = loop.filter { $0.x <= 0.25 }.map(\.x)
        let right = loop.filter { $0.x >= 0.75 }.map(\.x)
        let leftSpan = (left.max() ?? 0) - (left.min() ?? 0)
        let rightSpan = (right.max() ?? 0) - (right.min() ?? 0)
        XCTAssertEqual(leftSpan, 0.2, accuracy: 0.001)
        XCTAssertEqual(rightSpan, 0.2, accuracy: 0.001)

        let inner = CGPoint(x: 0.2200, y: 0.0000)
        let innerValley = CGPoint(x: 0.5000, y: 0.4200)
        let join = CGPoint(x: 0.2200, y: 0.3600)
        let outerValley = CGPoint(x: 0.5000, y: 0.7800)
        XCTAssertTrue(loop.contains(inner))
        XCTAssertTrue(loop.contains(innerValley))
        XCTAssertTrue(loop.contains(join))
        XCTAssertTrue(loop.contains(outerValley))
        let diag = CGVector(dx: innerValley.x - inner.x, dy: innerValley.y - inner.y)
        let outer = CGVector(dx: outerValley.x - join.x, dy: outerValley.y - join.y)
        XCTAssertEqual(diag.dx, outer.dx, accuracy: 0.0001)
        XCTAssertEqual(diag.dy, outer.dy, accuracy: 0.0001)
        let length = hypot(Double(diag.dx), Double(diag.dy))
        let perpendicular = Double(join.y - inner.y) * Double(diag.dx) / length
        XCTAssertEqual(perpendicular, 0.2, accuracy: 0.002)
    }

    /// Two peaks at the top and a valley on the centre line: an M, not a
    /// seashell and not a Z.
    func testTheMarkReadsAsACompactM() {
        let loop = GlyphOutline.minimax[0]
        let top = loop.filter { $0.y == 0 }
        XCTAssertEqual(top.count, 4)
        XCTAssertTrue(top.contains { $0.x <= 0.22 })
        XCTAssertTrue(top.contains { $0.x >= 0.78 })
        XCTAssertFalse(loop.contains { abs($0.x - 0.5) < 0.05 && $0.y < 0.1 })

        let valleys = loop.filter { abs($0.x - 0.5) < 0.001 }
        XCTAssertEqual(valleys.count, 2)
        XCTAssertEqual(valleys.map(\.y).min() ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(valleys.map(\.y).max() ?? 0, 0.78, accuracy: 0.001)
        XCTAssertLessThan(valleys.map(\.y).max() ?? 1, 1,
                          "a V to the baseline is a tall athletic M, not MiniMax's compact one")
    }
}
