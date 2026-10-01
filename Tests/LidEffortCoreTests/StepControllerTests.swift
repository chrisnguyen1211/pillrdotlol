import Testing
@testable import LidEffortCore

struct StepControllerTests {
    @Test func firstRestOnlyAnchors() {
        var step = StepController(level: .medium, stepDegrees: 8)
        let changed = step.settle(at: 110)
        #expect(!changed)
        #expect(step.anchor == 110)
        #expect(step.level == .medium)
    }

    @Test func pushOpenPastThresholdStepsUp() {
        var step = StepController(level: .medium, stepDegrees: 8)
        step.settle(at: 110)
        let changed = step.settle(at: 119)
        #expect(changed)
        #expect(step.level == .high)
        #expect(step.anchor == 119, "resting spot becomes the new neutral")
    }

    @Test func pushClosedStepsDownAndBigPushesTakeSeveralSteps() {
        var step = StepController(level: .max, stepDegrees: 8)
        step.settle(at: 150)
        let changed = step.settle(at: 133) // 17° = 2 steps
        #expect(changed)
        #expect(step.level == .high)
    }

    @Test func smallViewingAngleNudgesReanchorWithoutChangingLevel() {
        var step = StepController(level: .xhigh, stepDegrees: 8)
        step.settle(at: 110)
        let first = step.settle(at: 113)
        let second = step.settle(at: 117) // creeping 3° + 4° never counts as a push
        #expect(!first)
        #expect(!second)
        #expect(step.level == .xhigh)
        #expect(step.anchor == 117)
    }

    @Test func pastHalfwayLandsAheadAtOrShortOfHalfwayFallsBack() {
        // A rest is a choice between the level left and the one ahead: the
        // bar that followed the lid goes to whichever it is nearer.
        var step = StepController(level: .medium, stepDegrees: 8)
        step.settle(at: 100)
        let halfway = step.settle(at: 104)
        #expect(!halfway, "exactly halfway falls back")
        #expect(step.level == .medium)
        let past = step.settle(at: 108.5)
        #expect(past, "just past halfway lands ahead")
        #expect(step.level == .high)
        let down = step.settle(at: 104)
        #expect(down, "and the same going back down")
        #expect(step.level == .medium)

        #expect(StepController.steps(for: 0.5) == 0)
        #expect(StepController.steps(for: 0.51) == 1)
        #expect(StepController.steps(for: 1.5) == 1)
        #expect(StepController.steps(for: 1.6) == 2)
        #expect(StepController.steps(for: -0.6) == -1)
        #expect(StepController.steps(for: -1.5) == -1)
    }

    @Test func repeatedRestingAtTheSameSpotIsANoop() {
        var step = StepController(level: .low, stepDegrees: 8)
        step.settle(at: 100)
        step.settle(at: 110)
        #expect(step.level == .medium)
        let again = step.settle(at: 110)
        let jitter = step.settle(at: 110.4)
        #expect(!again)
        #expect(!jitter)
        #expect(step.level == .medium)
    }

    @Test func clampsAtBothEnds() {
        var step = StepController(level: .max, stepDegrees: 8)
        step.settle(at: 100)
        let up = step.settle(at: 140)
        #expect(!up, "already at max: a push up changes nothing")
        #expect(step.level == .max)
        var low = StepController(level: .low, stepDegrees: 8)
        low.settle(at: 140)
        let down = low.settle(at: 100)
        #expect(!down)
        #expect(low.level == .low)
    }

    @Test func reanchorMakesTheNextRestNeutralAgain() {
        var step = StepController(level: .medium, stepDegrees: 8)
        step.settle(at: 100)
        step.reanchor()
        let changed = step.settle(at: 140)
        #expect(!changed, "after wake/calibration the new position must not count as a push")
        #expect(step.level == .medium)
    }
}
