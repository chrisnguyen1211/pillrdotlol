import Foundation

/// The kind of usage alert event.
enum UsageAlertKind: Equatable {
    case reset
    case sessionLimitReached
    case weeklyLimitReached
    /// Not a limit: the day's recap, said on the same card.
    case recap
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
    /// Set for `.recap`: what the card says.
    var recap: DailyRecap? = nil
    /// Set for `.recap` instead of a recap: a few words of its own, from the
    /// productivity coach — a record broken, or a nudge.
    var note: CardNote? = nil

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
        /// When this reading was taken — a reset is news only to someone who
        /// was watching when it happened.
        var observedAt: Date
    }

    /// How late a reset may be noticed and still be said: a reset found an
    /// hour after it happened — the login came back, the Mac woke — is not
    /// "Claude is back", it is old news.
    static let freshFor: TimeInterval = 15 * 60
    /// How far a reset time may drift between readings without being a new
    /// window: providers that roll their window report it a little later
    /// each time.
    static let rollTolerance: TimeInterval = 10 * 60

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

    func observe(_ snapshots: [ProviderSnapshot], now: Date = Date()) {
        for snapshot in snapshots {
            observe(snapshot, now: now)
        }
    }

    private func observe(_ snapshot: ProviderSnapshot, now: Date) {
        // Only fresh, good readings are compared: a stale or failed one is
        // the old number re-shown, or none, and the reading after it is not
        // a drop from it.
        guard snapshot.status == .ok,
              let headline = snapshot.headline,
              let fraction = snapshot.usedFraction else { return }

        guard var previous = states[snapshot.id] else {
            states[snapshot.id] = TrackedState(fraction: fraction, resetsAt: headline.resetsAt,
                                               peakFraction: fraction, lastAlertedResetDate: headline.resetsAt,
                                               observedAt: now)
            return
        }

        let watching = now.timeIntervalSince(previous.observedAt) <= Self.freshFor
        let fell = fraction < previous.fraction
            && (previous.fraction - fraction >= 0.20 || (previous.peakFraction >= 0.30 && fraction <= 0.10))
        let hadSignificantUsage = previous.peakFraction >= 0.15

        var isReset: Bool
        var isFresh: Bool
        if let oldReset = previous.resetsAt {
            // A window with a reset time resets at that time — not before.
            // A drop well before it is another source's number or a glitch,
            // and a reset time that only drifted is the same window.
            let due = now >= oldReset.addingTimeInterval(-120)
            let rolled: Bool
            if let next = headline.resetsAt {
                let beyondLast = previous.lastAlertedResetDate.map { next > $0.addingTimeInterval(Self.rollTolerance) } ?? true
                rolled = next > oldReset.addingTimeInterval(Self.rollTolerance) && beyondLast
            } else {
                rolled = false
            }
            isReset = due && (rolled || fell) && fraction <= previous.fraction + 0.02
            isFresh = watching && now.timeIntervalSince(oldReset) <= Self.freshFor
        } else {
            // No reset time to go by: a real fall, seen as it happened.
            isReset = fell
            isFresh = watching
        }

        // A spent week makes the session's reset unusable: nothing to cheer.
        let weekIsSpent = (snapshot.weeklyFraction ?? 0) >= 1.0

        if isReset {
            if isFresh && hadSignificantUsage && !weekIsSpent && !isMuted(snapshot.id) {
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
            // Said or not, it is the new baseline: never announced later.
            previous.peakFraction = fraction
            previous.lastAlertedResetDate = headline.resetsAt
        } else if fell {
            // Fell, but not a reset: start the peak again from here, so a
            // glitch's low number is not later mistaken for a recovery.
            previous.peakFraction = fraction
        } else {
            previous.peakFraction = max(previous.peakFraction, fraction)
        }
        previous.fraction = fraction
        previous.resetsAt = headline.resetsAt
        previous.observedAt = now
        states[snapshot.id] = previous
    }
}

/// Words for the shared alert card that are not a limit or a recap.
struct CardNote: Equatable {
    let title: String
    let subtitle: String
    let status: String
    /// Good news is said in green; a nudge in amber.
    let good: Bool
}
