import Foundation

/// Which displays get a notch when more than one is connected.
///
/// One notch per display rather than one stretched across them: each panel is
/// welded to its own screen edge, and hovering one opens only that one — a
/// shared open state would unfold the notch on every screen at once, including
/// the one you are not looking at.
enum NotchScreenScope: String, CaseIterable, Identifiable {
    /// Only the display with the menu bar. What a single-panel setup always did.
    case mainDisplay
    /// Every connected display gets its own notch.
    case allDisplays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainDisplay: return L10n.t("Main display")
        case .allDisplays: return L10n.t("All displays")
        }
    }

    var explanation: String {
        switch self {
        case .mainDisplay:
            return L10n.t("The notch appears only on the display with the menu bar.")
        case .allDisplays:
            return L10n.t("Each display gets its own notch, and hovering one opens only that one.")
        }
    }
}
