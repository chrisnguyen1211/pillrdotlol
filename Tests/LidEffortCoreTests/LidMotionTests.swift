import Testing
@testable import LidEffortCore

struct LidMotionTests {
    @Test func needsAFullWindowBeforeItCanRest() {
        var motion = LidMotion(closedBelow: 90)
        motion.add(angle: 120, now: 0.0)
        motion.add(angle: 120, now: 0.2)
        #expect(!motion.isResting)
        motion.add(angle: 120, now: 0.4)
        motion.add(angle: 120, now: 0.65)
        #expect(motion.isResting)
        #expect(motion.restingAngle == 120)
    }

    @Test func movingThroughAnglesIsNotResting() {
        var motion = LidMotion(closedBelow: 90)
        for (i, angle) in [100.0, 106, 112, 118, 124].enumerated() {
            motion.add(angle: angle, now: Double(i) * 0.2)
        }
        #expect(!motion.isResting)
    }

    @Test func jitterWithinToleranceStillRests() {
        var motion = LidMotion(closedBelow: 90, restTolerance: 1.5)
        for (i, angle) in [130.0, 131, 130.5, 129.8, 130.9].enumerated() {
            motion.add(angle: angle, now: Double(i) * 0.2)
        }
        #expect(motion.isResting)
        // Mean of whatever is still inside the window (the t=0 sample has
        // aged out), so ~130.5 rather than the mean of all five.
        #expect(abs((motion.restingAngle ?? 0) - 130.5) < 0.2)
    }

    @Test func closedIsDetectedFromTheLatestSample() {
        var motion = LidMotion(closedBelow: 90)
        motion.add(angle: 120, now: 0)
        #expect(!motion.isClosed)
        motion.add(angle: 12, now: 0.2)
        #expect(motion.isClosed)
    }

    @Test func resetForgetsHistory() {
        var motion = LidMotion(closedBelow: 90)
        for i in 0..<5 { motion.add(angle: 120, now: Double(i) * 0.2) }
        #expect(motion.isResting)
        motion.reset()
        #expect(!motion.isResting)
        #expect(!motion.isClosed)
    }
}
