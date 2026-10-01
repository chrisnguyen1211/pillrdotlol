import Foundation

/// The kind of usage alert event.
enum UsageAlertKind: Equatable {
    case reset
    case sessionLimitReached
    case weeklyLimitReached
}

/// One alert event for a provider's usage window (reset or limit reached).
struct UsageAlertEvent: Equatable {
    let kind: UsageAlertKind
    let providerID: String
    let providerName: String
    let windowLabel: String
    let glyph: ProviderGlyph
    let previousFraction: Double
    let currentFraction: Double
    let resetsAt: Date?

    init(
        kind: UsageAlertKind = .reset,
        providerID: String,
        providerName: String,
        windowLabel: String,
        glyph: ProviderGlyph,
        previousFraction: Double,
        currentFraction: Double,
        resetsAt: Date?
    ) {
        self.kind = kind
        self.providerID = providerID
        self.providerName = providerName
        self.windowLabel = windowLabel
        self.glyph = glyph
        self.previousFraction = previousFraction
        self.currentFraction = currentFraction
        self.resetsAt = resetsAt
    }
}

typealias UsageResetEvent = UsageAlertEvent

/// Watches store snapshots and detects when a provider's limit window rolls over
/// or its usage drops back down to reset levels.
@MainActor
final class UsageResetWatcher {
    private struct TrackedState {
        var fraction: Double
        var resetsAt: Date?
        var peakFraction: Double
        var lastAlertedResetDate: Date?
    }

    private var states: [String: TrackedState] = [:]
    private let isMuted: (String) -> Bool
    private let deliver: (UsageResetEvent) -> Void

    init(
        isMuted: @escaping (String) -> Bool = { _ in false },
        deliver: @escaping (UsageResetEvent) -> Void = { _ in }
    ) {
        self.isMuted = isMuted
        self.deliver = deliver
    }

    func observe(_ snapshots: [ProviderSnapshot]) {
        for snapshot in snapshots {
            observe(snapshot)
        }
    }

    private func observe(_ snapshot: ProviderSnapshot) {
        guard let headline = snapshot.headline,
              let fraction = snapshot.usedFraction else { return }

        guard var previous = states[snapshot.id] else {
            states[snapshot.id] = TrackedState(
                fraction: fraction,
                resetsAt: headline.resetsAt,
                peakFraction: fraction,
                lastAlertedResetDate: headline.resetsAt
            )
            return
        }

        let isDateRolled = headline.resetsAt != nil
            && previous.resetsAt != nil
            && headline.resetsAt != previous.resetsAt
            && (previous.lastAlertedResetDate == nil || headline.resetsAt! > previous.lastAlertedResetDate!)

        let droppedSignificantly = fraction < previous.fraction
            && (previous.fraction - fraction >= 0.20 || (previous.peakFraction >= 0.30 && fraction <= 0.10))

        let hadSignificantUsage = previous.peakFraction >= 0.15

        // A session reset with the week already spent is not one you can
        // use: the counter is back at zero and every request still fails.
        // Nothing to cheer, so nothing is said — but the reading still
        // becomes the baseline, so the same reset is not announced later,
        // stale, once the week comes back.
        let weekIsSpent = (snapshot.weeklyFraction ?? 0) >= 1.0

        if (isDateRolled || droppedSignificantly) && hadSignificantUsage && !isMuted(snapshot.id) {
            if !weekIsSpent {
                deliver(UsageResetEvent(
                    providerID: snapshot.id,
                    providerName: snapshot.displayName,
                    windowLabel: headline.label,
                    glyph: snapshot.glyph,
                    previousFraction: previous.fraction,
                    currentFraction: fraction,
                    resetsAt: headline.resetsAt
                ))
            }

            previous.fraction = fraction
            previous.peakFraction = fraction
            previous.resetsAt = headline.resetsAt
            previous.lastAlertedResetDate = headline.resetsAt
            states[snapshot.id] = previous
        } else {
            previous.fraction = fraction
            previous.peakFraction = max(previous.peakFraction, fraction)
            previous.resetsAt = headline.resetsAt
            states[snapshot.id] = previous
        }
    }
}
