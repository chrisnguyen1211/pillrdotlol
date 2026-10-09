import XCTest
import CoreGraphics
@testable import LidEffort

/// A card over the desktop takes the wallpaper's tone under it.
final class WallpaperToneTests: XCTestCase {
    /// A wallpaper dark on its left half and white on its right.
    private func halves(width: Int = 32, height: Int = 20) -> WallpaperTone.Grid {
        WallpaperTone.Grid(width: width, height: height,
                           values: (0..<(width * height)).map { $0 % width < width / 2 ? 0.02 : 1 })
    }

    func testTheToneIsReadWhereTheCardIs() throws {
        let grid = halves()
        let left = try XCTUnwrap(WallpaperTone.luminance(of: grid, in: CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.1), screenAspect: 1.6))
        let right = try XCTUnwrap(WallpaperTone.luminance(of: grid, in: CGRect(x: 0.75, y: 0.4, width: 0.2, height: 0.1), screenAspect: 1.6))
        XCTAssertLessThan(left, WallpaperTone.darkBelow)
        XCTAssertGreaterThan(right, WallpaperTone.darkBelow)
    }

    func testAWiderWallpaperIsCroppedFromBothSides() throws {
        // 32 × 10 is wider than the screen: its outer quarters are off screen,
        // so the screen's left edge is a quarter of the way in, still dark.
        let grid = halves(width: 32, height: 10)
        let edge = try XCTUnwrap(WallpaperTone.luminance(of: grid, in: CGRect(x: 0, y: 0.4, width: 0.05, height: 0.2), screenAspect: 1.6))
        XCTAssertLessThan(edge, 0.1)
    }

    func testTheGridIsTheImagesLuminance() {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let grid = WallpaperTone.makeGrid(context.makeImage()!)
        XCTAssertEqual(grid.values.count, 8)
        XCTAssertEqual(grid.values[0], 1, accuracy: 0.01)
    }
}
