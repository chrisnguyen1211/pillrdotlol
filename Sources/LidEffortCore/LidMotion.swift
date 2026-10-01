import Foundation

/// Classifies raw hinge readings into the three things that matter:
/// *closed* (hold, never write), *moving* (ignore — the lid is passing
/// through angles, not choosing one), and *resting* (the only state in
/// which a level is ever applied). Resting means every sample in the last
/// `restWindow` seconds sits within `restTolerance` degrees of each other.
public struct LidMotion {
    public var restWindow: TimeInterval
    public var restTolerance: Double
    /// Below this the lid is being shut, which is an intent to stop
    /// working, not to pick the lowest effort.
    public var closedBelow: Double

    private var samples: [(angle: Double, time: TimeInterval)] = []
    public private(set) var isResting = false
    public private(set) var restingAngle: Double?

    public init(closedBelow: Double, restWindow: TimeInterval = 0.7, restTolerance: Double = 1.5) {
        self.closedBelow = closedBelow
        self.restWindow = restWindow
        self.restTolerance = restTolerance
    }

    public var isClosed: Bool {
        guard let last = samples.last else { return false }
        return last.angle < closedBelow
    }

    public mutating func add(angle: Double, now: TimeInterval) {
        samples.append((angle, now))
        samples.removeAll { now - $0.time > restWindow }
        // Pruning at the window edge means the retained span hovers one
        // sample interval short of `restWindow`; allow that slack rather
        // than demanding a span the sampler can never quite deliver.
        guard let first = samples.first, now - first.time >= restWindow - 0.25 else {
            isResting = false
            restingAngle = nil
            return
        }
        let angles = samples.map(\.angle)
        let spread = angles.max()! - angles.min()!
        isResting = spread <= restTolerance
        restingAngle = isResting ? angles.reduce(0, +) / Double(angles.count) : nil
    }

    /// Forget history, e.g. across sleep/wake where the lid moved unseen.
    public mutating func reset() {
        samples.removeAll()
        isResting = false
        restingAngle = nil
    }
}
