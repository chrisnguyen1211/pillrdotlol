import Testing
@testable import LidEffortCore

struct EffortBucketingTests {
    @Test func rawLevelSpansFullRange() {
        let bucketing = EffortBucketing(minAngle: 100, maxAngle: 160)
        #expect(bucketing.rawLevel(for: 90) == .low)
        #expect(bucketing.rawLevel(for: 100) == .low)
        #expect(bucketing.rawLevel(for: 112) == .medium)
        #expect(bucketing.rawLevel(for: 124) == .high)
        #expect(bucketing.rawLevel(for: 136) == .xhigh)
        #expect(bucketing.rawLevel(for: 148) == .max)
        #expect(bucketing.rawLevel(for: 170) == .max)
    }

    @Test func stableAngleNeverChangesLevel() {
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, initial: .low)
        for tick in 0..<20 {
            let changed = bucketing.update(angle: 101, now: Double(tick) * 0.2)
            #expect(!changed)
        }
        #expect(bucketing.current == .low)
    }

    @Test func crossingRequiresClearingDeadBand() {
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, deadBandDegrees: 2, stabilizeSeconds: 0, initial: .low)
        // Boundary between low/medium is 112. Landing exactly on it, without
        // clearing by the dead band, must not trigger a transition.
        let onBoundary = bucketing.update(angle: 112, now: 0)
        #expect(!onBoundary)
        #expect(bucketing.current == .low)
        let pastBoundary = bucketing.update(angle: 114.1, now: 1)
        #expect(pastBoundary)
        #expect(bucketing.current == .medium)
    }

    @Test func transitionRequiresStabilizeDelay() {
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, deadBandDegrees: 0, stabilizeSeconds: 0.3, initial: .low)
        var changed = bucketing.update(angle: 130, now: 0.0)
        #expect(!changed)
        #expect(bucketing.current == .low)
        changed = bucketing.update(angle: 130, now: 0.2)
        #expect(!changed)
        #expect(bucketing.current == .low)
        changed = bucketing.update(angle: 130, now: 0.31)
        #expect(changed)
        #expect(bucketing.current == .high)
    }

    @Test func flickerNearBoundaryResetsThePendingTimer() {
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, deadBandDegrees: 0, stabilizeSeconds: 0.3, initial: .low)
        var changed = bucketing.update(angle: 115, now: 0.0) // candidate: medium, pending starts
        #expect(!changed)
        changed = bucketing.update(angle: 100, now: 0.1) // back to low: cancels pending
        #expect(!changed)
        changed = bucketing.update(angle: 115, now: 0.2) // candidate: medium again, pending restarts
        #expect(!changed)
        changed = bucketing.update(angle: 115, now: 0.4) // only 0.2s since the restart
        #expect(!changed)
        changed = bucketing.update(angle: 115, now: 0.51)
        #expect(changed)
        #expect(bucketing.current == .medium)
    }

    @Test func resetClearsPendingTransition() {
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, deadBandDegrees: 0, stabilizeSeconds: 0.3, initial: .low)
        let changed = bucketing.update(angle: 130, now: 0)
        #expect(!changed)
        bucketing.reset(to: .max)
        #expect(bucketing.current == .max)
        let afterReset = bucketing.update(angle: 130, now: 0.31) // pre-reset pending candidate must not fire
        #expect(!afterReset)
        #expect(bucketing.current == .max)
    }

    @Test func anglesClampBeyondCalibratedRange() {
        var bucketing = EffortBucketing(minAngle: 100, maxAngle: 160, deadBandDegrees: 0, stabilizeSeconds: 0, initial: .max)
        let changed = bucketing.update(angle: 500, now: 0)
        #expect(!changed)
        #expect(bucketing.current == .max)
    }
}
