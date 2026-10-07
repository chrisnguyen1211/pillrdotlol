import SwiftUI

/// The material the expanded notch, tooltip and settings orb are painted with.
///
/// Raw values are persistence keys, not display copy: keeping them stable lets
/// labels change without losing an existing choice. The default is `.glass`
/// because an "on by default" choice must not depend on the user having opened
/// Settings.
enum NotchSurfaceStyle: String, CaseIterable, Identifiable {
    case glass
    case solid

    var id: String { rawValue }

    /// Whether this Mac has a Liquid Glass to hand the surface to at all.
    ///
    /// pillr's deployment target is macOS 15, where `glassEffect` does not
    /// exist. A material is not a stand-in: the notch panel sits over the bezel
    /// with nothing behind it to blur, so a `.regular` material there would
    /// come out as a flat grey rectangle rather than as translucency.
    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// The style that actually gets painted, which is the chosen one only where
    /// it can be. Every glass branch keys off this rather than off `self`, so a
    /// preference set on a newer Mac (or restored from one) still draws
    /// something sensible on an older one instead of drawing nothing.
    var effective: NotchSurfaceStyle {
        self == .glass && Self.glassAvailable ? .glass : .solid
    }

    var title: String {
        switch self {
        case .glass: return L10n.t("Liquid Glass")
        case .solid: return L10n.t("Solid black")
        }
    }

    var explanation: String {
        switch self {
        case .glass:
            return L10n.t("System Liquid Glass, light or dark with the switch at the top of Settings.")
        case .solid:
            return L10n.t("The original opaque black notch. Always dark, whatever the Mac's appearance.")
        }
    }

    /// One window-level switch decides both halves of "how dark is this notch":
    /// the dynamic `NSColor`s in `Palette` and SwiftUI's `colorScheme` are both
    /// resolved against the window's appearance, so pinning it here saves
    /// threading a style through every view that picks a colour.
    ///
    /// `nil` is not a fallback — it is the whole point of the glass style. With
    /// no appearance of our own, light or dark, Clear or Tinted all arrive from
    /// the Mac's Appearance settings; naming one would quietly overrule the
    /// user there.
    ///
    /// Reduce transparency is the exception the window has to be told about:
    /// it means "no see-through chrome", which for the notch is the solid
    /// style, and a light palette on a black surface would be unreadable. The
    /// precedence is the Settings window's — reduce transparency first, then
    /// glass, then the opaque fill.
    ///
    /// `mode` is the light/dark switch in Settings. Given one, glass takes
    /// it; without, glass follows the Mac as before. The solid style is
    /// black either way — that is what it is.
    func panelAppearance(reduceTransparency: Bool, mode: InterfaceMode? = nil) -> NSAppearance? {
        guard effective == .glass && !reduceTransparency else { return NSAppearance(named: .darkAqua) }
        return mode?.appearance
    }
}

private struct NotchSurfaceStyleKey: EnvironmentKey {
    static let defaultValue = NotchSurfaceStyle.glass
}

extension EnvironmentValues {
    var notchSurfaceStyle: NotchSurfaceStyle {
        get { self[NotchSurfaceStyleKey.self] }
        set { self[NotchSurfaceStyleKey.self] = newValue }
    }
}

private struct PillFrostKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0.5
}

extension EnvironmentValues {
    /// How much frost the chrome keeps under its glass — see
    /// `Preferences.pillFrost`.
    var pillFrost: CGFloat {
        get { self[PillFrostKey.self] }
        set { self[PillFrostKey.self] = newValue }
    }
}

private struct GlassSeesBehindKey: EnvironmentKey {
    static let defaultValue = true
}

private struct CardGlassSeesBehindKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The same for the card that is up — see `CardGlass`.
    var cardGlassSeesBehind: Bool {
        get { self[CardGlassSeesBehindKey.self] }
        set { self[CardGlassSeesBehindKey.self] = newValue }
    }

    /// Whether the chrome's glass has a window under it to refract — see
    /// `GlassSightline`. Over the desktop it has not, and `ChromeGlass`
    /// shows the blur instead.
    var glassSeesBehind: Bool {
        get { self[GlassSeesBehindKey.self] }
        set { self[GlassSeesBehindKey.self] = newValue }
    }
}
