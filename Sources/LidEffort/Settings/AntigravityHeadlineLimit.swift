import Foundation

enum AntigravityHeadlineLimit: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case fiveHour = "5h"
    case weekly = "weekly"
    
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("Automatic")
        case .fiveHour: return L10n.t("5-Hour Limit")
        case .weekly: return L10n.t("Weekly Limit")
        }
    }

    var explanation: String { title }
}
