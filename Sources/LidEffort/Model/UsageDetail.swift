import Foundation

/// Provider-owned usage detail for one explicit time range.
///
/// This is separate from the generic limit windows: a window answers what is
/// left, while this structure answers what has been consumed by API key/model.
struct ProviderUsageDetail: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    let timeZoneSeconds: Int
    let currency: String
    let groups: [UsageDetailGroup]

    var hasUsage: Bool {
        groups.contains { $0.totalTokens > 0 || $0.totalCost > 0 || $0.requests > 0 }
    }

    var visibleGroups: [UsageDetailGroup] { groups.filter(\.hasUsage) }

    var visibleAPIKeyCount: Int {
        Set(visibleGroups.map(\.apiKeyID)).count
    }

    var totalTokens: Int { groups.reduce(0) { $0 + $1.totalTokens } }
    var totalCost: Double { groups.reduce(0) { $0 + $1.totalCost } }
    var totalRequests: Int { groups.reduce(0) { $0 + $1.requests } }
}

/// One API key × model series. The tracking ID is an internal join key and is
/// never displayed in the card.
struct UsageDetailGroup: Codable, Equatable, Sendable, Identifiable {
    let apiKeyID: String
    let apiKeyLabel: String
    let model: String
    let days: [UsageDetailDay]

    var id: String { "\(apiKeyID)|\(model)" }
    var cacheHitTokens: Int { days.reduce(0) { $0 + $1.cacheHitTokens } }
    var cacheMissTokens: Int { days.reduce(0) { $0 + $1.cacheMissTokens } }
    var outputTokens: Int { days.reduce(0) { $0 + $1.outputTokens } }
    var totalTokens: Int { cacheHitTokens + cacheMissTokens + outputTokens }
    var requests: Int { days.reduce(0) { $0 + $1.requests } }
    var totalCost: Double { days.reduce(0) { $0 + $1.cost } }
    var hasUsage: Bool { totalTokens > 0 || totalCost > 0 || requests > 0 }

    var cacheHitRate: Double? {
        let input = cacheHitTokens + cacheMissTokens
        guard input > 0 else { return nil }
        return Double(cacheHitTokens) / Double(input)
    }
}

struct UsageDetailDay: Codable, Equatable, Sendable {
    let date: Date
    let cacheHitTokens: Int
    let cacheMissTokens: Int
    let outputTokens: Int
    let requests: Int
    let cost: Double

    var totalTokens: Int { cacheHitTokens + cacheMissTokens + outputTokens }
}
