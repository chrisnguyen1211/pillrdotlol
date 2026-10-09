import AppKit
import ImageIO
import SwiftUI

/// How light the wallpaper is under a card, so a card over the desktop can
/// wear the pill's own glass and still be read: white ink over a dark
/// wallpaper, black over a light one, whatever the Mac's appearance.
///
/// Read from the wallpaper's file, small: nothing on screen is captured, so
/// no permission is asked. Over a window there is no telling, and the
/// cards keep their scrim there instead (`CardGlass.scrim`).
enum WallpaperTone {
    /// The luminance where white and black ink read equally well (WCAG):
    /// below it, white on the bare wallpaper is the stronger of the two.
    static let darkBelow = 0.179

    /// The card's ground in each tone: the wallpaper, then the frost's own
    /// colour and the tone's breath of scrim over it. What the glass adds
    /// is left out; it lifts both the same way.
    static let darkFrost = 0.02, lightFrost = 0.82

    /// Which tone gives the stronger contrast for a wallpaper of luminance
    /// `wallpaper`, under a frost of strength `frost` (0…1): each tone's
    /// ground worked out, its ink set against it, the better one taken.
    static func tone(forWallpaper wallpaper: Double, frost: Double) -> (tone: ColorScheme, contrast: Double) {
        let cover = min(1, max(0, frost) + tonedScrim)
        let darkGround = wallpaper + (darkFrost - wallpaper) * cover
        let lightGround = wallpaper + (lightFrost - wallpaper) * cover
        let white = ratio(1, darkGround)
        let black = ratio(0, lightGround)
        return white >= black ? (.dark, white) : (.light, black)
    }

    /// The breath of the tone's own ground a toned card keeps under its glass.
    static let tonedScrim = 0.15

    /// WCAG contrast ratio of two relative luminances.
    static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The tone for a rect in CoreGraphics coordinates (top left of the
    /// primary display), or nil when the wallpaper can't be read.
    @MainActor
    static func tone(under rect: CGRect, frost: Double) -> ColorScheme? {
        guard let primary = NSScreen.screens.first else { return nil }
        let point = CGPoint(x: rect.midX, y: primary.frame.height - rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let grid = grid(url) else { return nil }
        // The screen's frame, top-left like `rect`.
        let frame = CGRect(x: screen.frame.minX, y: primary.frame.height - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height)
        let unit = CGRect(x: (rect.minX - frame.minX) / frame.width, y: (rect.minY - frame.minY) / frame.height,
                          width: rect.width / frame.width, height: rect.height / frame.height)
        guard let light = luminance(of: grid, in: unit, screenAspect: frame.width / frame.height) else { return nil }
        return tone(forWallpaper: light, frost: frost).tone
    }

    /// A small grid of the wallpaper's luminance, kept per file.
    struct Grid {
        let width: Int
        let height: Int
        let values: [Double]
        var aspect: CGFloat { CGFloat(width) / CGFloat(height) }
    }

    @MainActor private static var cache: (url: URL, modified: Date?, grid: Grid)?

    @MainActor
    private static func grid(_ url: URL) -> Grid? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cache, cache.url == url, cache.modified == modified { return cache.grid }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
              ] as CFDictionary) else { return nil }
        let grid = makeGrid(image)
        cache = (url, modified, grid)
        return grid
    }

    static func makeGrid(_ image: CGImage) -> Grid {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func linear(_ byte: UInt8) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var values = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            values[i] = 0.2126 * linear(data[i * 4]) + 0.7152 * linear(data[i * 4 + 1]) + 0.0722 * linear(data[i * 4 + 2])
        }
        return Grid(width: width, height: height, values: values)
    }

    /// The mean luminance under `unit`, a rect in the screen's own 0…1
    /// space, with the wallpaper filling the screen as macOS fills it:
    /// scaled to cover, the overhang cut evenly from both sides.
    static func luminance(of grid: Grid, in unit: CGRect, screenAspect: CGFloat) -> Double? {
        var visible = CGRect(x: 0, y: 0, width: 1, height: 1)
        if grid.aspect > screenAspect {
            visible.size.width = screenAspect / grid.aspect
            visible.origin.x = (1 - visible.width) / 2
        } else {
            visible.size.height = grid.aspect / screenAspect
            visible.origin.y = (1 - visible.height) / 2
        }
        let image = CGRect(x: visible.minX + unit.minX * visible.width, y: visible.minY + unit.minY * visible.height,
                           width: unit.width * visible.width, height: unit.height * visible.height)
        let x0 = max(0, Int(image.minX * CGFloat(grid.width))), x1 = min(grid.width - 1, Int(image.maxX * CGFloat(grid.width)))
        let y0 = max(0, Int(image.minY * CGFloat(grid.height))), y1 = min(grid.height - 1, Int(image.maxY * CGFloat(grid.height)))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var sum = 0.0, count = 0
        for y in y0...y1 { for x in x0...x1 { sum += grid.values[y * grid.width + x]; count += 1 } }
        return count > 0 ? sum / Double(count) : nil
    }
}

private struct CardToneKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// The tone a card takes from the wallpaper under it; nil when it is
    /// over a window or the wallpaper can't be read.
    var cardTone: ColorScheme? {
        get { self[CardToneKey.self] }
        set { self[CardToneKey.self] = newValue }
    }
}

extension View {
    /// A card in the wallpaper's tone, glass and ink alike, when it is known.
    @ViewBuilder func cardTone(_ tone: ColorScheme?) -> some View {
        if let tone {
            environment(\.colorScheme, tone).environment(\.cardTone, tone)
        } else {
            self
        }
    }
}
