import AppKit
import SwiftUI

/// Light or dark, for pillr's own surfaces: the notch's glass, its cards and
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

/// What the person picked: light, dark, or whatever the Mac is set to. On
/// System, pillr follows macOS — including when macOS switches by itself at
/// sunset — rather than taking a reading at launch and keeping it.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return L10n.t("Light")
        case .dark: return L10n.t("Dark")
        case .system: return L10n.t("System")
        }
    }

    var symbol: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    func resolved(systemIsDark: Bool) -> InterfaceMode {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    /// Whether macOS is dark right now — read from the setting itself, which
    /// is current the moment it changes, not from this app's appearance,
    /// which pillr's own choice can colour.
    static var systemIsDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }
}
