import Foundation

/// Mirrors Claude Code's `effortLevel` setting values, low to high.
public enum EffortLevel: Int, CaseIterable, Comparable, CustomStringConvertible {
    case low, medium, high, xhigh, max

    public var description: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "max"
        }
    }

    public static func < (lhs: EffortLevel, rhs: EffortLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
