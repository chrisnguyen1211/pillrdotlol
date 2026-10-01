import XCTest
import SwiftUI
@testable import LidEffort

/// Two sessions blocked on you at once, and answering a multi-step question
/// in the tooltip without it folding away.
@MainActor
final class PromptQueueTests: XCTestCase {
    private func prompt(_ session: String, _ json: String) throws -> PendingPrompt {
        var p = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        p.sessionName = session
        return p
    }

    private static let twoStep = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Colour?","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}]},{"question":"Sides?","multiSelect":true,"options":[{"label":"Top"},{"label":"Left"}]}]}}"#
    private static let bash = #"{"tool_name":"Bash","tool_input":{"command":"make"}}"#

    func testTwoWaitingSessionsArePagedAndKeepTheirOwnPicks() throws {
        let model = NotchViewModel()
        let a = try prompt("session-a", Self.twoStep)
        let b = try prompt("session-b", Self.bash)
        model.prompts = [a, b]
        XCTAssertEqual(model.currentPrompt?.id, a.id, "oldest first")
        XCTAssertEqual(model.promptQueue, PromptQueuePosition(index: 0, count: 2))

        // Half-way through A's questions…
        let draftA = model.draft(for: a)
        var d = draftA.wrappedValue
        d.toggle("Blue")
        _ = d.advance()
        draftA.wrappedValue = d
        XCTAssertEqual(model.draft(for: a).wrappedValue.index, 1)

        // …look at B, and come back: A is where it was left.
        model.pagePrompt(by: 1)
        XCTAssertEqual(model.currentPrompt?.id, b.id)
        model.pagePrompt(by: 1)
        XCTAssertEqual(model.currentPrompt?.id, a.id, "paging wraps round")
        XCTAssertEqual(model.draft(for: a).wrappedValue.index, 1)
        XCTAssertTrue(model.draft(for: a).wrappedValue.questions.count == 2)
    }

    /// The tour's demo prompts are answered with the tour's own card, and
    /// no "Answers sent" line over it — nothing was sent. A real one still
    /// says it.
    func testAQuietPromptIsAnsweredWithoutTheSentLine() throws {
        let model = NotchViewModel()
        let demo = try prompt("demo", Self.bash)
        let real = try prompt("real", Self.bash)
        model.prompts = [demo, real]
        model.quietPrompts = [demo.id]
        var answered: [UUID] = []
        model.onAnswerPrompt = { id, _ in answered.append(id) }

        model.answer(demo.id, with: .allow, from: .tooltip)
        XCTAssertNil(model.promptEcho)
        XCTAssertEqual(answered, [demo.id], "the answer still goes to whoever handles it")

        model.answer(real.id, with: .allow, from: .tooltip)
        XCTAssertEqual(model.promptEcho?.text, "Allowed")
    }

    func testAnsweringOneLeavesTheOtherOnScreen() throws {
        let model = NotchViewModel()
        let a = try prompt("session-a", Self.bash)
        let b = try prompt("session-b", Self.twoStep)
        let c = try prompt("session-c", Self.bash)
        model.prompts = [a, b, c]
        model.pagePrompt(by: 1)
        XCTAssertEqual(model.currentPrompt?.id, b.id)
        // A is answered elsewhere: B stays the one in view, now 1 of 2.
        model.prompts = [b, c]
        XCTAssertEqual(model.currentPrompt?.id, b.id)
        XCTAssertEqual(model.promptQueue, PromptQueuePosition(index: 0, count: 2))
        // B is answered: the next one comes up, and the queue goes when one is left.
        model.prompts = [c]
        XCTAssertEqual(model.currentPrompt?.id, c.id)
        XCTAssertNil(model.promptQueue)
        XCTAssertTrue(model.drafts.keys.allSatisfy { $0 == c.id }, "picks for answered prompts are dropped")
    }

    func testAClickInTheTooltipNeverFoldsTheNotchOrJumpsToTheTerminal() throws {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        var focused: pid_t?
        controller.model.onFocusSession = { focused = $0 }

        // A session is waiting on you — the card that says so is up…
        let waiting = AgentSession(id: "w", name: "session-a", detail: "Terminal", state: .waiting,
                                   waitingFor: nil, since: Date(), processID: 4321)
        controller.showDoneToast(.init(session: waiting, reason: .blocked, providerID: "claude"), duration: 5)
        // …and you open the notch and click inside the tooltip, as choosing
        // the first answer does.
        controller.model.isExpanded = true
        controller.model.hoveredIndex = 0
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let card = try XCTUnwrap(controller.tooltipRectForTesting(index: 0))
        controller.handleClick(at: CGPoint(x: card.midX, y: frame.height - card.midY))

        XCTAssertTrue(controller.model.isExpanded, "the tooltip stays open for the next question")
        XCTAssertEqual(controller.model.hoveredIndex, 0)
        XCTAssertNil(focused, "an answer is not a request to open the session")
    }

    /// The prompt tooltip goes away when it is answered, not when the
    /// pointer drifts off it.
    func testAnOpenQuestionHoldsTheNotchUntilItIsAnswered() async throws {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { false }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        let cell = try XCTUnwrap(controller.model.snapshots.firstIndex { $0.providerID == ClaudeProfile.defaultID && $0.localModel == nil })

        controller.model.prompts = [try prompt("session-a", Self.twoStep)]
        controller.model.isExpanded = true
        XCTAssertEqual(controller.model.promptCellIndex, cell)

        // The pointer leaves for somewhere else on the screen entirely.
        let away = CGPoint(x: -4000, y: -4000)
        controller.pointerMovedForTesting(toLocal: away)
        XCTAssertEqual(controller.model.hoveredIndex, cell, "the prompt's tooltip is up without hovering")
        try await Task.sleep(for: .milliseconds(900))
        controller.pointerMovedForTesting(toLocal: away)
        XCTAssertTrue(controller.model.isExpanded, "no hover fold while the question waits")
        XCTAssertEqual(controller.model.hoveredIndex, cell)

        // Answered: the ordinary hover fold takes over again.
        controller.model.prompts = []
        XCTAssertFalse(controller.model.holdsForPrompt)
        controller.pointerMovedForTesting(toLocal: away)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(controller.model.isExpanded)
    }

    /// "Answers sent" and the tooltip it is in go together: the tooltip is
    /// held up for the line, and folds in the same moment the line goes —
    /// never first, leaving the line hanging on its own.
    func testTheTooltipFoldsWithItsAnswersSentLine() async throws {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { false }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        let cell = try XCTUnwrap(controller.model.promptCellIndex ?? controller.model.snapshots.firstIndex {
            $0.providerID == ClaudeProfile.defaultID && $0.localModel == nil })
        let asked = try prompt("session-a", Self.bash)
        controller.model.prompts = [asked]
        controller.model.isExpanded = true
        let away = CGPoint(x: -4000, y: -4000)
        controller.pointerMovedForTesting(toLocal: away)

        controller.model.answer(asked.id, with: .allow, from: .tooltip)
        controller.model.prompts = []   // the broker lets it go at once
        controller.pointerMovedForTesting(toLocal: away)
        try await Task.sleep(for: .milliseconds(900))   // past the hover fold's grace
        controller.pointerMovedForTesting(toLocal: away)
        XCTAssertNotNil(controller.model.promptEcho)
        XCTAssertTrue(controller.model.isExpanded, "the tooltip stays up while its line shows")
        XCTAssertEqual(controller.model.hoveredIndex, cell)

        // The line's time is up — waited for rather than slept past, so a
        // loaded machine running the whole suite cannot make it flaky.
        for _ in 0..<60 where controller.model.promptEcho != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(controller.model.promptEcho)
        XCTAssertNil(controller.model.hoveredIndex, "the tooltip went with it")
        XCTAssertFalse(controller.model.isExpanded)
    }

    /// The tour's first step holds a ring's tooltip open — limits and
    /// sessions on screen — however the pointer wanders, and lets it go after.
    func testTheTourHoldsATooltipOpenThenLetsItGo() async throws {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { false }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.holdTooltip(index: 0)
        controller.model.isExpanded = true
        let away = CGPoint(x: -4000, y: -4000)
        controller.pointerMovedForTesting(toLocal: away)
        try await Task.sleep(for: .milliseconds(900))
        controller.pointerMovedForTesting(toLocal: away)
        XCTAssertTrue(controller.model.isExpanded, "folded under the tour")
        XCTAssertEqual(controller.model.hoveredIndex, 0, "the tooltip went")

        controller.holdTooltip(index: nil)
        XCTAssertFalse(controller.model.holdsForPrompt)
        controller.pointerMovedForTesting(toLocal: away)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(controller.model.isExpanded, "still held after the tour let go")
    }

    func testAnotherRingStillShowsItsOwnCardThenTheQuestionComesBack() throws {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { false }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.model.prompts = [try prompt("session-a", Self.bash)]
        controller.model.isExpanded = true
        let cell = try XCTUnwrap(controller.model.promptCellIndex)
        let other = try XCTUnwrap(controller.model.snapshots.indices.first { $0 != cell })

        controller.pointerMovedForTesting(toLocal: controller.cellPointForTesting(index: other))
        XCTAssertEqual(controller.model.hoveredIndex, other, "pointing at another ring shows that ring")

        controller.pointerMovedForTesting(toLocal: CGPoint(x: -4000, y: -4000))
        XCTAssertEqual(controller.model.hoveredIndex, cell, "and leaving it brings the question back, not nothing")
    }

    func testAClickOnTheFoldedCardNeitherOpensTheNotchNorTheSession() throws {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        var focused: pid_t?
        controller.model.onFocusSession = { focused = $0 }
        var p = try prompt("session-a", Self.bash)
        p.pid = 4321
        controller.model.prompts = [p]
        XCTAssertFalse(controller.model.isExpanded)

        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let card = controller.promptCardRectForTesting(p)
        controller.handleClick(at: CGPoint(x: card.midX, y: frame.height - card.midY))

        XCTAssertFalse(controller.model.isExpanded, "the card's buttons take the click; the notch stays folded")
        XCTAssertNil(focused)
        XCTAssertEqual(controller.model.prompts.count, 1, "a click that is not on a button answers nothing")
    }

    func testTheTooltipsAnswerLeavesWithTheTooltipAndACardsAfterAMoment() async throws {
        let model = NotchViewModel()
        let a = try prompt("a", Self.bash), b = try prompt("b", Self.bash)
        model.prompts = [a, b]
        model.isExpanded = true

        model.answer(a.id, with: .allow, from: .tooltip)
        XCTAssertEqual(model.promptEcho?.text, "Allowed")
        model.isExpanded = false
        XCTAssertNil(model.promptEcho, "the tooltip closed, and its answer went with it")

        model.answer(b.id, with: .deny, from: .card)
        XCTAssertEqual(model.promptEcho?.origin, .card)
        model.isExpanded = true
        model.isExpanded = false
        XCTAssertNotNil(model.promptEcho, "a card's answer is not the tooltip's to take away")
        try await Task.sleep(for: PromptEcho.lasts + .milliseconds(300))
        XCTAssertNil(model.promptEcho, "and it goes by itself")
    }

    func testThePagerWrapsBothWays() throws {
        let model = NotchViewModel()
        let a = try prompt("a", Self.bash), b = try prompt("b", Self.bash), c = try prompt("c", Self.bash)
        model.prompts = [a, b, c]
        model.pagePrompt(by: -1)
        XCTAssertEqual(model.currentPrompt?.id, c.id)
        XCTAssertEqual(model.promptQueue, PromptQueuePosition(index: 2, count: 3))
        model.pagePrompt(by: 1)
        XCTAssertEqual(model.currentPrompt?.id, a.id)
    }

    func testOnlyTheDefaultClaudeProfileCarriesThePrompt() throws {
        let model = NotchViewModel()
        model.updateSnapshots(Fixtures.snapshots())
        model.prompts = [try prompt("a", Self.bash)]
        let claude = try XCTUnwrap(model.snapshots.first { $0.providerID == ClaudeProfile.defaultID })
        let codex = try XCTUnwrap(model.snapshots.first { $0.providerID != ClaudeProfile.defaultID })
        XCTAssertNotNil(model.prompt(for: claude))
        XCTAssertNil(model.prompt(for: codex))

        // No default-profile Claude ring on the notch: nothing to hold open for.
        model.updateSnapshots(model.snapshots.filter { $0.providerID != ClaudeProfile.defaultID })
        model.isExpanded = true
        XCTAssertNil(model.promptCellIndex)
        XCTAssertFalse(model.holdsForPrompt)
    }

    func testAFreshScreenOfChoicesIsArmedAgain() throws {
        let a = try prompt("a", Self.twoStep), b = try prompt("b", Self.twoStep)
        var draft = PromptDraft(questions: a.questions)
        let first = PromptArming.key(prompt: a, draft: draft)
        XCTAssertEqual(first, PromptArming.key(prompt: a, draft: draft), "nothing changed, nothing re-arms")
        draft.toggle("Red")
        XCTAssertEqual(first, PromptArming.key(prompt: a, draft: draft), "a pick is not a new screen")
        _ = draft.advance()
        XCTAssertNotEqual(first, PromptArming.key(prompt: a, draft: draft), "the next question re-arms")
        XCTAssertNotEqual(first, PromptArming.key(prompt: b, draft: PromptDraft(questions: b.questions)), "another session re-arms")
        XCTAssertGreaterThanOrEqual(PromptArming.delay, .milliseconds(500))
    }

    func testAFullScreenAppDoesNotFoldAWaitingQuestionAway() throws {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { true }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.model.prompts = [try prompt("session-a", Self.bash)]
        controller.model.isExpanded = true

        controller.foldForFullScreen()
        XCTAssertTrue(controller.model.isExpanded)

        controller.model.prompts = []
        controller.foldForFullScreen()
        XCTAssertFalse(controller.model.isExpanded)
    }
}

@MainActor
final class PromptBrokerConcurrencyTests: XCTestCase {
    func testTwoSessionsAreAnsweredIndependently() async throws {
        let path = "/tmp/lid-prompt-\(UUID().uuidString.prefix(8)).sock"
        let broker = PromptBroker(path: path, patience: 10)
        defer { broker.stop() }
        var received: [PendingPrompt] = []
        broker.onPrompt = { received.append($0); return nil }
        try broker.start()

        let first = #"{"session_id":"one","tool_name":"Bash","tool_input":{"command":"make one"}}"#
        let second = #"{"session_id":"two","tool_name":"Bash","tool_input":{"command":"make two"}}"#
        let a = Task.detached { PromptHookClient.exchange(Data(first.utf8), path: path) }
        let b = Task.detached { PromptHookClient.exchange(Data(second.utf8), path: path) }
        for _ in 0..<150 where received.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(received.count, 2, "both are held at once")

        // Answered the other way round from how they came in.
        let one = try XCTUnwrap(received.first { $0.sessionID == "one" })
        let two = try XCTUnwrap(received.first { $0.sessionID == "two" })
        broker.answer(two.id, with: .deny)
        broker.answer(one.id, with: .allow)
        let replyOne = String(decoding: await a.value ?? Data(), as: UTF8.self)
        let replyTwo = String(decoding: await b.value ?? Data(), as: UTF8.self)
        XCTAssertTrue(replyOne.contains(#""behavior":"allow""#), replyOne)
        XCTAssertTrue(replyTwo.contains(#""behavior":"deny""#), replyTwo)
    }
}
