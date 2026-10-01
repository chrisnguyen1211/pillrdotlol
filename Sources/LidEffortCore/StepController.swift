import Foundation

/// Relative ("step") mode: the lid's absolute angle means nothing; a
/// deliberate push of at least `stepDegrees` from where it last rested
/// moves the level one step per `stepDegrees` (open = up, close = down),
/// and wherever it comes to rest becomes the new neutral. Small
/// viewing-angle adjustments re-anchor without changing anything, so the
/// lid can live at whatever angle is comfortable.
public struct StepController {
    public var stepDegrees: Double
    public private(set) var level: EffortLevel
    public private(set) var anchor: Double?

    public init(level: EffortLevel, stepDegrees: Double = 7) {
        self.level = level
        self.stepDegrees = stepDegrees
    }

    /// How many levels a travel of `ratio` steps moves: the whole steps,
    /// and one more once *more than half* of the next is covered. The bar
    /// that follows the lid is nearer the level ahead past halfway, and
    /// lands there; at or short of halfway it falls back to the one it
    /// left. Signed: a push closed counts down.
    public static func steps(for ratio: Double) -> Int {
        let whole = ratio.rounded(.towardZero)
        let rest = abs(ratio - whole)
        return Int(whole) + (rest > 0.5 ? (ratio < 0 ? -1 : 1) : 0)
    }

    /// Feed a *resting* angle. Returns true when the level changed.
    @discardableResult
    public mutating func settle(at angle: Double) -> Bool {
        guard let anchor else {
            self.anchor = angle
            return false
        }
        let steps = Self.steps(for: (angle - anchor) / stepDegrees)
        self.anchor = angle
        guard steps != 0 else { return false }
        let clamped = min(EffortLevel.allCases.count - 1, max(0, level.rawValue + steps))
        guard clamped != level.rawValue else { return false }
        level = EffortLevel(rawValue: clamped)!
        return true
    }

    /// Where the lid is *now*, in levels, before it has rested: the level
    /// plus the travel since the last rest, one level per `stepDegrees`,
    /// clamped to the scale. Continuous, for a bar that follows the hand;
    /// `settle` is what actually moves the level, by `steps(for:)` — past
    /// halfway to the next level the rest lands there, otherwise it falls
    /// back. Nil until the lid has rested once, since there is nothing to
    /// measure from.
    public func preview(at angle: Double) -> Double? {
        guard let anchor else { return nil }
        let raw = Double(level.rawValue) + (angle - anchor) / stepDegrees
        return min(Double(EffortLevel.allCases.count - 1), max(0, raw))
    }

    /// Drop the neutral point (after sleep, calibration, or a mode switch)
    /// so the next rest re-anchors instead of counting as a push.
    public mutating func reanchor() { anchor = nil }

    public mutating func set(level: EffortLevel) { self.level = level }
}
