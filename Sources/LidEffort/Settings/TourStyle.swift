import Foundation

/// How the intro tour looks.
enum TourStyle: String, CaseIterable, Identifiable {
    /// Liquid Glass: a cinematic intro with its own sound, then glass cards
    /// and light pointing at the pill.
    case glass
    /// Sticky notes and marker doodles.
    case doodle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return L10n.t("Liquid Glass")
        case .doodle: return L10n.t("Doodle")
        }
    }
}
