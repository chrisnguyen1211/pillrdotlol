import Testing
@testable import LidEffortCore

@Suite("The bar follows the lid before it rests")
struct StepPreviewTests {
    @Test func nothingToShowBeforeTheFirstRest() {
        let step = StepController(level: .medium)
        #expect(step.preview(at: 100) == nil)
    }

    @Test func aPushIsMeasuredFromTheLastRestInLevels() {
        // high is the middle of the scale: low 0, medium 1, high 2.
        var step = StepController(level: .high, stepDegrees: 8)
        step.settle(at: 100)
        #expect(step.preview(at: 100) == 2)
        #expect(step.preview(at: 104) == 2.5)
        #expect(step.preview(at: 108) == 3)
        #expect(step.preview(at: 92) == 1)
    }

    @Test func thePreviewStopsAtTheEndsOfTheScale() {
        var step = StepController(level: .max, stepDegrees: 8)
        step.settle(at: 100)
        #expect(step.preview(at: 140) == 4)
        #expect(step.preview(at: 60) == 0)
    }

    @Test func restingLandsWhereThePreviewIsNearer() {
        var step = StepController(level: .high, stepDegrees: 8)
        step.settle(at: 100)
        #expect(step.preview(at: 107) == 2.875)
        let landed = step.settle(at: 107)
        #expect(landed, "seven eighths of the way: lands on xhigh")
        #expect(step.level == .xhigh)
        #expect(step.preview(at: 107) == 3)

        #expect(step.preview(at: 104) == 2.625)
        let stayed = step.settle(at: 104)
        #expect(!stayed, "three eighths back: stays")
        #expect(step.level == .xhigh)
    }
}
