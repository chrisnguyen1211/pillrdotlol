import AppKit
import SwiftUI

/// Light or dark, for spyx's own surfaces: the notch's glass, its cards and
/// the Settings window. Chosen with the sun/moon switch at the top of
/// Settings rather than inherited from the Mac, so the notch can be dark
/// glass on a light Mac or the other way round.
enum InterfaceMode: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }

    var appearance: NSAppearance? { NSAppearance(named: self == .dark ? .darkAqua : .aqua) }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    var toggled: InterfaceMode { self == .dark ? .light : .dark }

    /// What the Mac is set to now: the starting point before anyone has
    /// used the switch.
    static var system: InterfaceMode {
        let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            ?? NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }
}
