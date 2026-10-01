import AppKit
import SwiftUI

/// The user-selected colour for positive usage and active work indicators.
///
/// Raw values are persistence keys, not display copy. Keeping them stable lets
/// labels and ordering change without losing an existing choice.
enum AccentColorChoice: String, CaseIterable, Identifiable {
    case system
    case pink = "ff33e1"
    case red = "eb4236"
    case orange = "eb8436"
    case yellow = "ffd400"
    case green = "00ff88"
    case teal = "00e5cc"
    case blue = "36a8eb"
    case indigo = "6c5ce7"
    case purple = "b026ff"
    case offWhite = "f7f6f5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:   return L10n.t("Device accent color")
        case .pink:     return "#FF33E1"
        case .red:      return "#EB4236"
        case .orange:   return "#EB8436"
        case .yellow:   return "#FFD400"
        case .green:    return "#00FF88"
        case .teal:     return "#00E5CC"
        case .blue:     return "#36A8EB"
        case .indigo:   return "#6C5CE7"
        case .purple:   return "#B026FF"
        case .offWhite: return "#F7F6F5"
        }
    }

    var color: Color {
        switch self {
        case .system:   return Color(nsColor: .controlAccentColor)
        case .pink:     return Color(hex: 0xFF33E1)
        case .red:      return Color(hex: 0xEB4236)
        case .orange:   return Color(hex: 0xEB8436)
        case .yellow:   return Color(hex: 0xFFD400)
        case .green:    return Palette.ample
        case .teal:     return Color(hex: 0x00E5CC)
        case .blue:     return Color(hex: 0x36A8EB)
        case .indigo:   return Color(hex: 0x6C5CE7)
        case .purple:   return Color(hex: 0xB026FF)
        case .offWhite: return Color(hex: 0xF7F6F5)
        }
    }
}

private struct NotchAccentColorKey: EnvironmentKey {
    static let defaultValue = Color(nsColor: .controlAccentColor)
}

extension EnvironmentValues {
    var notchAccentColor: Color {
        get { self[NotchAccentColorKey.self] }
        set { self[NotchAccentColorKey.self] = newValue }
    }
}
