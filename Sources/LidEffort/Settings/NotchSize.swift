import Foundation

/// How large the notch is drawn.
///
/// A fixed set rather than a free number, for the same reason `PeekDuration` is
/// one: the useful range is narrow. Below about three quarters the percentage
/// under each ring stops being readable at a glance, which is the one thing the
/// notch exists to do; much above a quarter larger and a stack of five
/// providers is competing with the windows it sits beside rather than reporting
/// on them.
///
/// The scale multiplies the whole surface — rings, text, tooltip and all — so
/// the proportions stay exactly as they were drawn. `NotchLayout` keeps every
/// constant it quotes from the design frame, and `medium` is that frame at 1:1.
enum NotchSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// What every measured distance is multiplied by. `medium` is 1, so it is
    /// the design frame untouched and the behaviour every earlier version had.
    var scale: CGFloat {
        switch self {
        case .small:  return 0.8
        case .medium: return 1
        case .large:  return 1.25
        }
    }

    var title: String {
        switch self {
        case .small:  return L10n.t("Small")
        case .medium: return L10n.t("Medium")
        case .large:  return L10n.t("Large")
        }
    }

    var explanation: String {
        switch self {
        case .small:
            return L10n.t("Takes the least room on the edge. Readable, but not from across the desk.")
        case .medium:
            return L10n.t("The size the notch was drawn at.")
        case .large:
            return L10n.t("Easier to read at a glance, and harder to ignore.")
        }
    }
}
