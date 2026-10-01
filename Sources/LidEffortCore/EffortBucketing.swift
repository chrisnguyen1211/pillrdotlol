import Foundation

/// Maps a continuous lid angle onto one of five effort levels, with hysteresis
/// and a stability delay so sensor noise or a hand passing through a band
/// boundary can't flap the result or trigger a write.
public struct EffortBucketing {
    public var minAngle: Double
    public var maxAngle: Double
    /// Degrees the angle must clear past a band edge before a transition is
    /// even considered, so it doesn't flap right at the boundary.
    public var deadBandDegrees: Double
    /// Seconds a candidate level must hold before it becomes `current`.
    public var stabilizeSeconds: Double
    public private(set) var current: EffortLevel

    private var pending: EffortLevel?
    private var pendingSince: TimeInterval = 0

    public init(
        minAngle: Double,
        maxAngle: Double,
        deadBandDegrees: Double = 2.0,
        stabilizeSeconds: Double = 0.3,
        initial: EffortLevel = .medium
    ) {
        self.minAngle = minAngle
        self.maxAngle = maxAngle
        self.deadBandDegrees = deadBandDegrees
        self.stabilizeSeconds = stabilizeSeconds
        self.current = initial
    }

    private var bandWidth: Double {
        max(0.001, (maxAngle - minAngle) / Double(EffortLevel.allCases.count))
    }

    private func upperEdge(of level: EffortLevel) -> Double {
        minAngle + bandWidth * Double(level.rawValue + 1)
    }

    private func lowerEdge(of level: EffortLevel) -> Double {
        minAngle + bandWidth * Double(level.rawValue)
    }

    /// The level implied purely by angle, ignoring hysteresis and debounce.
    public func rawLevel(for angle: Double) -> EffortLevel {
        let index = Int(((angle - minAngle) / bandWidth).rounded(.down))
        let clamped = min(EffortLevel.allCases.count - 1, max(0, index))
        return EffortLevel(rawValue: clamped)!
    }

    /// Feeds a new sensor reading. Returns true if `current` changed.
    @discardableResult
    public mutating func update(angle: Double, now: TimeInterval) -> Bool {
        let raw = rawLevel(for: angle)
        let candidate: EffortLevel
        if raw > current {
            candidate = angle >= upperEdge(of: current) + deadBandDegrees ? raw : current
        } else if raw < current {
            candidate = angle <= lowerEdge(of: current) - deadBandDegrees ? raw : current
        } else {
            candidate = current
        }
        guard candidate != current else {
            pending = nil
            return false
        }
        if pending != candidate {
            pending = candidate
            pendingSince = now
        }
        guard now - pendingSince >= stabilizeSeconds else { return false }
        current = candidate
        pending = nil
        return true
    }

    /// Forces `current` immediately, e.g. after recalibration. Clears any
    /// in-flight debounce so a stale pending level can't fire later.
    public mutating func reset(to level: EffortLevel) {
        current = level
        pending = nil
    }
}
