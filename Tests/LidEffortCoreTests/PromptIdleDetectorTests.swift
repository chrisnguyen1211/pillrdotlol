import Testing
@testable import LidEffortCore

struct PromptIdleDetectorTests {
    @Test func idleEmptyPromptIsIdle() {
        let screen = """
        ╰──────────────────────────────────────────────────╯
        ● high · /effort
        ────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────
        ⏵⏵ auto mode on (shift+tab to cycle)
        """
        #expect(PromptIdleDetector.isIdle(screenText: screen))
    }

    @Test func promptWithTrailingSpaceIsStillIdle() {
        #expect(PromptIdleDetector.isIdle(screenText: "some earlier output\n❯ \nfooter"))
    }

    @Test func typedTextIsNotIdle() {
        #expect(!PromptIdleDetector.isIdle(screenText: "some earlier output\n❯ please refactor this file\nfooter"))
    }

    @Test func openDialogSelectionIsNotIdle() {
        let screen = """
        Quick safety check: is this a project you trust?

        ❯ 1. Yes, I trust this folder
          2. No, exit

        Enter to confirm · Esc to cancel
        """
        #expect(!PromptIdleDetector.isIdle(screenText: screen))
    }

    @Test func noPromptMarkerAtAllIsNotIdle() {
        #expect(!PromptIdleDetector.isIdle(screenText: "just a plain shell prompt with no ink UI\n$ "))
    }

    @Test func onlyTheLastPromptLineMatters() {
        let screen = """
        ❯
        assistant said something
        ❯ half-typed comman
        """
        #expect(!PromptIdleDetector.isIdle(screenText: screen))
    }

    @Test func runningTurnIsNotIdleEvenWithAnEmptyPrompt() {
        // Claude Code keeps the input line open while a turn runs; a
        // command typed now would be queued behind it, not applied.
        let screen = """
        ✻ Thinking… (esc to interrupt)

        ❯
        """
        #expect(!PromptIdleDetector.isIdle(screenText: screen))
    }
}
