import AppKit
import SwiftUI

/// The dark values are sampled from `docs/design/frame-124-hover-tooltip.png`,
/// not invented, and they differ slightly from the hexes written in the design
/// spec — the frame is the source of truth, so the sampled values win.
///
/// The light values are not sampled from anything, because there is no light
/// frame: they exist only because the glass surface (`NotchSurfaceStyle.glass`)
/// hands light and dark to the Mac's Appearance settings, and white ink on
/// light glass is unreadable. They were picked for at least 3:1 against white.
/// `solid` pins the panel to `darkAqua`, so it keeps the frame's hexes exactly.
///
/// The two tracks are translucent white / black rather than a fixed grey so
/// they darken or lighten whatever is behind them instead of looking painted
/// on top of the glass. Their dark alphas are the ones that composite to the
/// frame's `#303030` / `#2D2D2D` over black, so the solid style is unchanged.
///
/// `notch` and `card` stay pure black: they paint the resting pill, which has
/// to read as the bezel, and the whole surface in the solid style.
enum Palette {
    static let notch         = Color.black                    // #000000
    static let card          = Color.black                    // #000000
    static let ringTrack     = Color(dark: .white.withAlphaComponent(0.188),
                                     light: .black.withAlphaComponent(0.16))
    static let barTrack      = Color(dark: .white.withAlphaComponent(0.176),
                                     light: .black.withAlphaComponent(0.15))

    static let ample         = Color(dark: NSColor(hex: 0x00FF88), light: NSColor(hex: 0x00A356))
    static let watch         = Color(dark: NSColor(hex: 0xF2FF00), light: NSColor(hex: 0xB08800))
    /// Already 3.5:1 on white, so the warning colour is the same in both.
    static let critical      = Color(hex: 0xFF3F00)           // orange

    // Generation-speed bands are independent of cloud quota usage.
    static let generationFast = Color(hex: 0x0A84FF)          // blue
    static let generationSlow = Color(hex: 0xFF453A)          // red

    static let textPrimary   = Color(dark: .white, light: .black)
    /// Light: dark enough for 4.5:1 on a light card, which #6B6B6B was not
    /// once the card sat on a blurred dark desktop.
    ///
    /// Translucent, as the tracks are, rather than a fixed grey: a fixed grey
    /// stays put while the glass under it takes on the brightness of what is
    /// behind, and the two met on a dark card over a white page. Half-white
    /// is the frame's #808080 over the solid style's black and lifts with a
    /// lighter card; two-thirds black is #555555 over white and deepens with
    /// a greyer one. With `CardGlass.scrim` bounding the card, that keeps
    /// 4.5:1 over a white window or a black one (`CardLegibilityRenderTests`).
    static let textSecondary = Color(dark: secondaryInkDark, light: secondaryInkLight)
    static let secondaryInkDark = NSColor.white.withAlphaComponent(0.502)
    static let secondaryInkLight = NSColor.black.withAlphaComponent(0.667)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Resolved against whatever appearance is current when the colour is
    /// drawn, which for the notch is the panel's: `nil` for glass (so the Mac
    /// decides) and `darkAqua` for solid.
    init(dark: NSColor, light: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   1
        )
    }
}

private struct NotchReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// True when macOS Accessibility "Reduce Transparency" is enabled in system settings,
    /// or explicitly overridden via `.environment(\.notchReduceTransparency, ...)`.
    var notchReduceTransparency: Bool {
        get { self[NotchReduceTransparencyKey.self] || self.accessibilityReduceTransparency }
        set { self[NotchReduceTransparencyKey.self] = newValue }
    }
}

