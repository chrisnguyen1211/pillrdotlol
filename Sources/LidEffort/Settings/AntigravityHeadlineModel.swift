import Foundation

enum AntigravityHeadlineModel: String, CaseIterable, Identifiable {
    case gemini = "gemini"
    case thirdParty = "3p"
    
    var id: String { rawValue }
    
    var explanation: String {
        switch self {
        case .gemini: return L10n.t("Gemini Models")
        case .thirdParty: return L10n.t("Claude and GPT models")
        }
    }
}
