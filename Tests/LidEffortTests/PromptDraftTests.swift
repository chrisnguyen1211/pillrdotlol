import XCTest
import SwiftUI
@testable import LidEffort

/// Every shape of question Claude can ask: one choice, several choices,
/// several questions in a row — and the answer each hands back.
final class PromptDraftTests: XCTestCase {
    private func q(_ text: String, _ labels: [String], multi: Bool = false) -> PendingPrompt.Question {
        .init(question: text, header: nil, options: labels.map { .init(label: $0, description: nil) }, multiSelect: multi)
    }

    func testASingleChoiceIsSentOnlyBySend() {
        var draft = PromptDraft(questions: [q("Colour?", ["Red", "Blue"])])
        XCTAssertFalse(draft.hasAnswer, "Send is off until something is picked")
        XCTAssertNil(draft.advance())
        draft.toggle("Red")
        draft.toggle("Blue")
        XCTAssertFalse(draft.isPicked("Red"), "one choice: the second pick replaces the first")
        XCTAssertEqual(draft.advance(), .answers(["Colour?": ["Blue"]]))
    }

    func testAMultipleChoiceQuestionWaitsForSendAndKeepsOfferedOrder() {
        var draft = PromptDraft(questions: [q("Sides?", ["Top", "Right", "Bottom", "Left"], multi: true)])
        XCTAssertFalse(draft.hasAnswer)
        XCTAssertNil(draft.advance())
        draft.toggle("Left")
        draft.toggle("Top")
        draft.toggle("Right")
        XCTAssertTrue(draft.isPicked("Top"))
        XCTAssertTrue(draft.hasAnswer)
        XCTAssertEqual(draft.advance(), .answers(["Sides?": ["Top", "Right", "Left"]]),
                       "in the order offered, not the order clicked")
    }

    func testUnpickingEverythingTurnsSendOffAgain() {
        var draft = PromptDraft(questions: [q("Sides?", ["Top", "Left"], multi: true)])
        draft.toggle("Top")
        draft.toggle("Top")
        XCTAssertFalse(draft.isPicked("Top"))
        XCTAssertFalse(draft.hasAnswer)
        XCTAssertNil(draft.advance())
    }

    func testSeveralQuestionsStepThroughAndSendTogether() {
        var draft = PromptDraft(questions: [
            q("Colour?", ["Red", "Blue"]),
            q("Sides?", ["Top", "Left"], multi: true),
            q("Size?", ["S", "M", "L"]),
        ])
        XCTAssertEqual(draft.position, "1 / 3")
        draft.toggle("Red")
        XCTAssertNil(draft.advance(), "Continue, not Send")
        XCTAssertEqual(draft.position, "2 / 3")
        XCTAssertEqual(draft.current?.question, "Sides?")
        draft.toggle("Left")
        XCTAssertNil(draft.advance())
        XCTAssertTrue(draft.isLast)
        draft.toggle("M")
        XCTAssertEqual(draft.advance(), .answers(["Colour?": ["Red"], "Sides?": ["Left"], "Size?": ["M"]]))
    }

    func testTheArrowsMoveFreelyAndKeepWhatWasPicked() {
        var draft = PromptDraft(questions: [q("Colour?", ["Red", "Blue"]), q("Sides?", ["Top", "Left"], multi: true)])
        XCTAssertFalse(draft.canGoBack)
        XCTAssertTrue(draft.canGoForward)
        draft.go(by: 1)
        XCTAssertEqual(draft.current?.question, "Sides?", "on without answering")
        XCTAssertFalse(draft.canGoForward)
        draft.go(by: 1)
        XCTAssertEqual(draft.position, "2 / 2", "not past the last")
        draft.toggle("Top")
        draft.back()
        XCTAssertEqual(draft.current?.question, "Colour?")
        draft.toggle("Blue")
        _ = draft.advance()
        XCTAssertTrue(draft.isPicked("Top"), "the pick on the way past is still there")
        draft.go(by: -5)
        XCTAssertEqual(draft.position, "1 / 2")
        XCTAssertTrue(draft.isPicked("Blue"))
    }

    func testSomethingElseIsAnAnswerOfItsOwn() {
        var draft = PromptDraft(questions: [q("Colour?", ["Red", "Blue"]), q("Sides?", ["Top", "Left"], multi: true)])
        draft.toggle("Red")
        draft.setCustom("   ")
        XCTAssertTrue(draft.isPicked("Red"), "blank typing replaces nothing")
        draft.setCustom("Teal, please")
        XCTAssertFalse(draft.isPicked("Red"), "one choice: typed text replaces the pick")
        XCTAssertTrue(draft.hasAnswer)
        _ = draft.advance()
        draft.toggle("Left")
        draft.setCustom("Bottom too")
        XCTAssertTrue(draft.isPicked("Left"), "several choices: typed text is one more")
        XCTAssertEqual(draft.advance(), .answers(["Colour?": ["Teal, please"], "Sides?": ["Left", "Bottom too"]]))
    }

    func testPickingAfterTypingClearsTheTypingOnASingleChoice() {
        var draft = PromptDraft(questions: [q("Colour?", ["Red", "Blue"])])
        draft.setCustom("Teal")
        draft.toggle("Blue")
        XCTAssertEqual(draft.customText(for: draft.questions[0]), "")
        XCTAssertEqual(draft.advance(), .answers(["Colour?": ["Blue"]]))
    }

    func testSkipMovesOnAndTheLastSkipSendsWhatThereIs() {
        var draft = PromptDraft(questions: [q("Colour?", ["Red", "Blue"]), q("Size?", ["S", "M"])])
        XCTAssertNil(draft.skip(), "on to the next question")
        XCTAssertEqual(draft.position, "2 / 2")
        draft.toggle("M")
        XCTAssertEqual(draft.skip(), .answers(["Size?": ["M"]]), "a skipped question is left out")

        var nothing = PromptDraft(questions: [q("Colour?", ["Red", "Blue"])])
        XCTAssertEqual(nothing.skip(), .passThrough, "nothing to send: Claude asks in its own dialog")
    }

    func testTheHookGetsEveryAnswerWithMultipleChoicesJoined() throws {
        let json = #"{"session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Colour?","header":"Colour","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}]},{"question":"Sides?","header":"Sides","multiSelect":true,"options":[{"label":"Top"},{"label":"Left"},{"label":"Right"}]}]}}"#
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        var draft = PromptDraft(questions: prompt.questions)
        draft.toggle("Blue")
        _ = draft.advance()
        draft.toggle("Right")
        draft.toggle("Top")
        draft.setCustom("Bottom")
        let answer = try XCTUnwrap(draft.advance())
        let data = PromptResponse.json(for: answer, prompt: prompt)
        let output = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hookSpecificOutput"] as? [String: Any])
        let input = try XCTUnwrap((output["decision"] as? [String: Any])?["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String], ["Colour?": "Blue", "Sides?": "Top, Right, Bottom"])
    }

    func testTheCardFitsTheQuestionOnScreen() throws {
        let json = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"A?","options":[{"label":"1"},{"label":"2"}]},{"question":"B?","multiSelect":true,"options":[{"label":"1"},{"label":"2"},{"label":"3"},{"label":"4"},{"label":"5"}]}]}}"#
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        let line = PromptLayout.headingLineHeight
        func rows(_ n: CGFloat) -> CGFloat { n * PromptLayout.optionHeight + (n - 1) * PromptLayout.optionGap }
        // Two options and "Something else…"; then four (the most shown) and it.
        XCTAssertEqual(PromptLayout.bodyHeight(for: prompt, index: 0), line + PromptLayout.headingGap + rows(3), accuracy: 0.5)
        XCTAssertEqual(PromptLayout.bodyHeight(for: prompt, index: 1), line + PromptLayout.headingGap + rows(5), accuracy: 0.5)
        XCTAssertLessThan(PromptCard.cardHeight(for: prompt, index: 0), PromptCard.cardHeight(for: prompt, index: 1),
                          "the card grows for the longer question")
        XCTAssertEqual(PromptPanel.maxHeight(for: prompt), PromptPanel.height(for: prompt, index: 1))
        XCTAssertEqual(PromptLayout.offset(for: prompt, index: 1),
                       PromptLayout.questionHeight(prompt.questions[0]) + PromptLayout.slideGap, accuracy: 0.5,
                       "the second question slides up from right under the first")
    }

    func testALongQuestionIsShownWhole() {
        let short = PromptLayout.headingHeight("Colour?")
        let long = String(repeating: "Which of these should we ship first and why ", count: 3)
        let endless = String(repeating: long, count: 10)
        XCTAssertEqual(short, PromptLayout.headingLineHeight, accuracy: 0.5)
        XCTAssertGreaterThan(PromptLayout.headingLines(long), 3, "no longer cut to its first three lines")
        XCTAssertLessThan(PromptLayout.headingLines(long), PromptLayout.headingMaxLines)
        XCTAssertEqual(PromptLayout.headingLines(endless), PromptLayout.headingMaxLines)
    }

    func testAChoiceShowsWhatItMeans() throws {
        let json = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which way?","options":[{"label":"Short"},{"label":"Keep the glass, and switch to a blur over the desktop (Recommended)","description":"Real Liquid Glass where there is a window behind; over the desktop, a blur of the screen instead. Best looking with a window behind, but it polls the window list."}]}]}}"#
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        let (plain, described) = (prompt.questions[0].options[0], prompt.questions[0].options[1])
        XCTAssertEqual(PromptLayout.optionRowHeight(plain), PromptLayout.optionHeight, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(PromptLayout.optionDetailLines(described), 2, "the meaning gets lines of its own")
        XCTAssertGreaterThan(PromptLayout.optionRowHeight(described), 2 * PromptLayout.optionHeight)
    }

    func testAPermissionSaysWhyAndShowsTheWholeCommand() throws {
        let command = String(repeating: "git -C ~/project log --oneline -5 && ", count: 4) + "echo done"
        let json = #"{"tool_name":"Bash","tool_input":{"command":"\#(command)","description":"Show recent history"}}"#
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        XCTAssertEqual(prompt.purpose, "Show recent history")
        XCTAssertGreaterThan(PromptLayout.codeLines(for: prompt), 2, "the command is no longer cut to two lines")
        let bare = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)))
        XCTAssertNil(bare.purpose)
        XCTAssertLessThan(PromptLayout.approvalBodyHeight(for: bare), PromptLayout.approvalBodyHeight(for: prompt))
    }

    func testTheEchoSaysWhatHappened() throws {
        var p = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)))
        p.pid = 42
        XCTAssertEqual(PromptEcho(answer: .allow, prompt: p).text, "Allowed")
        XCTAssertEqual(PromptEcho(answer: .deny, prompt: p).tone, .declined)
        XCTAssertEqual(PromptEcho(answer: .answers([:]), prompt: p).text, "Answers sent")
        XCTAssertEqual(PromptEcho(answer: .passThrough, prompt: p).tone, .handedBack)
        XCTAssertEqual(PromptEcho(answer: .allow, prompt: p).pid, 42)
    }
}

@MainActor
final class WaitingCardTests: XCTestCase {
    private func event(_ reason: SessionCompletionWatcher.Reason) -> SessionCompletionWatcher.Event {
        let session = AgentSession(id: "s", name: "effort-lid", detail: "Terminal", state: reason == .blocked ? .waiting : .idle,
                                   waitingFor: nil, since: Date(), processID: 777)
        return .init(session: session, reason: reason, providerID: "claude")
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAFinishedCardGoesAfterItsTime() {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.showDoneToast(event(.finished), duration: 0.2)
        pump(0.5)
        XCTAssertNil(controller.model.activeDoneToast)
    }

    func testAWaitingCardStaysUntilTheSessionStopsWaiting() {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.showDoneToast(event(.blocked), duration: 0.2)
        pump(0.5)
        XCTAssertNotNil(controller.model.activeDoneToast, "a session waiting on you is not stale news")
        controller.resolveWaiting(waitingPIDs: [777])
        XCTAssertNotNil(controller.model.activeDoneToast, "still waiting")
        controller.resolveWaiting(waitingPIDs: [])
        XCTAssertNil(controller.model.activeDoneToast, "answered somewhere: the card goes")
    }
}

@MainActor
final class PromptDesignRenderTests: XCTestCase {
    private func prompt(_ json: String, name: String = "effort-lid-3c") throws -> PendingPrompt {
        var p = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        p.sessionName = name
        return p
    }

    func testEveryStateBesideTheDoneCard() throws {
        let bash = try prompt(#"{"cwd":"/Users/me/Effort Lid","tool_name":"Bash","tool_input":{"command":"swift test --filter PromptDraftTests"},"permission_suggestions":[{"type":"addRules"}]}"#)
        let single = try prompt(#"{"cwd":"/Users/me/Effort Lid","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should the sync job write to?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"The main cluster"},{"label":"SQLite","description":"A local file, for tests"},{"label":"Both","description":"Postgres, mirrored to SQLite"}]}]}}"#)
        let multiJSON = #"{"cwd":"/Users/me/Effort Lid","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which platforms should ship first?","header":"Platforms","multiSelect":true,"options":[{"label":"macOS","description":"The notch app"},{"label":"iOS","description":"Widget"},{"label":"Web","description":"Dashboard"},{"label":"CLI","description":"Terminal only"}]},{"question":"Release channel?","header":"Channel","multiSelect":false,"options":[{"label":"Beta"},{"label":"Stable"}]}]}}"#
        let multi = try prompt(multiJSON)
        var picked = PromptDraft(questions: multi.questions)
        picked.toggle("macOS")
        picked.toggle("CLI")
        var second = picked
        _ = second.advance()
        var typed = PromptDraft(questions: single.questions)
        typed.setCustom("Postgres, but read replicas only")

        let done = DoneToast(event: .init(session: AgentSession(id: "d", name: "effort-lid-3c", detail: "Terminal · Effort Lid",
                                                                state: .idle, waitingFor: nil, since: Date(), processID: 1),
                                          reason: .finished, providerID: "claude"), glyph: .claude)
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                DoneToastView(toast: done)
                PromptCard(prompt: bash, draft: .constant(PromptDraft(questions: [])), onAnswer: { _ in }, onOpen: {})
                PromptCard(prompt: single, draft: .constant(PromptDraft(questions: single.questions)), onAnswer: { _ in }, onOpen: {})
            }
            VStack(alignment: .leading, spacing: 16) {
                PromptCard(prompt: multi, draft: .constant(picked), onAnswer: { _ in }, onOpen: {}, queue: PromptQueuePosition(index: 0, count: 2), onPage: { _ in })
                PromptCard(prompt: multi, draft: .constant(second), onAnswer: { _ in }, onOpen: {})
            }
            VStack(alignment: .leading, spacing: 16) {
                PromptPanel(prompt: multi, draft: .constant(PromptDraft(questions: multi.questions)), onAnswer: { _ in }, onOpen: {}, queue: PromptQueuePosition(index: 1, count: 2), onPage: { _ in })
                    .frame(width: NotchLayout.cardWidth - 2 * NotchLayout.cardPadding)
                    .padding(NotchLayout.cardPadding)
                    .background(RoundedRectangle(cornerRadius: NotchLayout.cardCorner).fill(Color.black))
                PromptCard(prompt: single, draft: .constant(typed), onAnswer: { _ in }, onOpen: {})
                HStack(spacing: 12) {
                    PromptEchoPill(echo: PromptEcho(answer: .answers([:]), prompt: single))
                    PromptEchoPill(echo: PromptEcho(answer: .deny, prompt: bash))
                }
            }
        }
        .padding(24).background(Color(white: 0.22))
        .environment(\.notchSurfaceStyle, .solid)
        .environment(\.colorScheme, .dark)
        .environment(\.drawsFieldsAsText, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("prompt-states.png"))
        }
        XCTAssertGreaterThan(image.size.width, 3 * NotchLayout.cardWidth)
    }
}

final class PromptDraftCopyTests: XCTestCase {
    func testTitleAndStatusFollowTheQuestionOnScreen() throws {
        let json = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Platforms?","header":"Platforms","multiSelect":true,"options":[{"label":"macOS"},{"label":"iOS"}]},{"question":"Channel?","header":"Channel","multiSelect":false,"options":[{"label":"Beta"},{"label":"Stable"}]}]}}"#
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        var draft = PromptDraft(questions: prompt.questions)
        XCTAssertEqual(draft.title(for: prompt), "Platforms")
        XCTAssertEqual(draft.status(for: prompt), "Pick one or more")
        draft.toggle("iOS")
        _ = draft.advance()
        XCTAssertEqual(draft.title(for: prompt), "Channel")
        XCTAssertEqual(draft.status(for: prompt), "Pick one")
    }
}
