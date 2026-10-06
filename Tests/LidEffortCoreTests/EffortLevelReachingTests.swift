import Testing
@testable import LidEffortCore

@Suite("A value dragged to by hand becomes a lid level")
struct EffortLevelReachingTests {
    @Test func exactHitsWin() {
        let claude = BuiltInTargets.claude
        #expect(claude.level(reaching: "low", model: nil) == .low)
        #expect(claude.level(reaching: "high", model: nil) == .high)
    }

    @Test func aValueTwoBandsShareTakesTheLowerBand() {
        // Claude's top two bands both write xhigh; dragging to it must not
        // claim the lid is at max, which the next push down would then
        // step from.
        #expect(BuiltInTargets.claude.level(reaching: "xhigh", model: nil) == .xhigh)
    }

    @Test func aValueNoBandReachesTakesTheNearest() {
        // Codex sol: scale low…max…ultra, bands skip max. Nearest is a tie
        // between xhigh (below) and max/ultra (above); the lower wins.
        let level = BuiltInTargets.codex.level(reaching: "max", model: "gpt-5.6-sol")
        #expect(level == .xhigh)
        // Hermes's minimal sits below every band: low is the nearest.
        #expect(BuiltInTargets.hermes.level(reaching: "minimal", model: nil) == .low)
    }

    @Test func theTopOfAFullScaleIsMax() {
        #expect(BuiltInTargets.codex.level(reaching: "ultra", model: "gpt-5.6-sol") == .max)
        #expect(BuiltInTargets.claude.level(reaching: "max", model: nil) == .max)
        // Past max, it is still the lid's top — the controller types
        // ultracode itself rather than going through a level.
        #expect(BuiltInTargets.claude.level(reaching: "ultracode", model: nil) == .max)
    }

    @Test func aValueOffTheScaleIsNothing() {
        #expect(BuiltInTargets.claude.level(reaching: "ultra", model: nil) == nil)
    }
}
