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

    // MARK: A draft, told apart from a turn running and from a picker

    @Test func aDraftInTheInputBoxIsADraft() {
        let screen = """
        ● Done.
        ────────────────────────────────────────────────────
        ❯ also bump the version and write
          the release notes
        ────────────────────────────────────────────────────
        ⏵⏵ auto mode on (shift+tab to cycle)
        """
        #expect(PromptIdleDetector.state(screenText: screen) == .draft)
        #expect(!PromptIdleDetector.isIdle(screenText: screen))
    }

    @Test func aDraftWhileATurnRunsIsBusy() {
        let screen = """
        ✻ Thinking… (esc to interrupt)
        ────────────────────────────────────────────────────
        ❯ also bump the version
        ────────────────────────────────────────────────────
        """
        #expect(PromptIdleDetector.state(screenText: screen) == .busy)
    }

    @Test func aPickerRowIsNotADraft() {
        // /resume: the highlighted session carries the same marker.
        let screen = """
        Resume a conversation
          Fix the login flow
        ❯ Dashboard under a real sky
          Release 1.2.1
        """
        #expect(PromptIdleDetector.state(screenText: screen) == .busy)
        #expect(PromptIdleDetector.state(screenText: "────\n❯ 1. Yes, I trust this folder\n  2. No") == .busy)
    }

    @Test func anEmptyBoxIsIdle() {
        #expect(PromptIdleDetector.state(screenText: "────\n❯ \n────") == .idle)
    }
}
