import XCTest
import SwiftUI
@testable import LidEffort

/// "Something else…" has to take typing inside the real notch panel — a
/// borderless, non-activating panel that normally never takes the keyboard.
@MainActor
final class PromptTypingTests: XCTestCase {
    private func question() throws -> PendingPrompt {
        try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Colour?","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}]}]}}"#.utf8)))
    }

    private func click(_ window: NSWindow, at point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    func testTheAnswerFieldTakesTypingInTheNotchPanel() throws {
        let prompt = try question()
        final class Box { var draft: PromptDraft; init(_ d: PromptDraft) { draft = d } }
        let box = Box(PromptDraft(questions: prompt.questions))
        let size = CGSize(width: NotchLayout.cardWidth + 40, height: PromptCard.cardHeight(for: prompt) + 20)
        let panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height))
        panel.acceptsKeyboard = true
        let host = NotchHostingView(rootView: AnyView(
            PromptCard(prompt: prompt,
                       draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                       onAnswer: { _ in }, onOpen: {})
                .environment(\.notchSurfaceStyle, .solid)))
        host.frame = CGRect(origin: .zero, size: size)
        host.interactiveRects = [CGRect(origin: .zero, size: size)]
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // Find the field: sweep the card's lower half until a click makes a
        // text view first responder.
        var focused = false
        var y: CGFloat = 20
        while y < size.height / 2, !focused {
            click(panel, at: CGPoint(x: size.width / 2, y: y))
            focused = panel.firstResponder is NSTextView
            y += 8
        }
        print("panel key: \(panel.isKeyWindow), first responder: \(String(describing: panel.firstResponder))")
        XCTAssertTrue(focused, "a click on Something else… puts the caret in it")

        (panel.firstResponder as? NSTextView)?.insertText("Teal", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.draft.customText(for: prompt.questions[0]), "Teal", "what is typed is the answer")
    }
}

@MainActor
final class PromptQuestionClickMapTests: XCTestCase {
    func testEachRowOfAQuestionTakesItsOwnClicks() throws {
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should the sync job write to?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"The main cluster"},{"label":"SQLite","description":"A local file, for tests"},{"label":"Both","description":"Postgres, mirrored to SQLite"}]}]}}"#.utf8)))
        final class Box { var draft: PromptDraft; init(_ d: PromptDraft) { draft = d } }
        let box = Box(PromptDraft(questions: prompt.questions))
        let size = CGSize(width: NotchLayout.cardWidth + 40, height: PromptCard.cardHeight(for: prompt) + 20)
        let panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height))
        panel.acceptsKeyboard = true
        var answered: PromptAnswer?
        let host = NotchHostingView(rootView: AnyView(
            PromptCard(prompt: prompt, draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                       onAnswer: { answered = $0 }, onOpen: {})
                .environment(\.notchSurfaceStyle, .solid)))
        host.frame = CGRect(origin: .zero, size: size)
        host.interactiveRects = [CGRect(origin: .zero, size: size)]
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        var rows: [String] = []
        var y = size.height - 6
        while y > 0 {
            var row = ""
            var x: CGFloat = 6
            while x < size.width {
                box.draft = PromptDraft(questions: prompt.questions)
                answered = nil
                panel.makeFirstResponder(nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    panel.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: panel.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                let q = prompt.questions[0]
                if panel.firstResponder is NSTextView { row += "C" }
                else if box.draft.isPicked("Postgres", in: q) { row += "P" }
                else if box.draft.isPicked("SQLite", in: q) { row += "S" }
                else if box.draft.isPicked("Both", in: q) { row += "B" }
                else if answered == .passThrough { row += "X" }
                else { row += "." }
                x += 12
            }
            rows.append(row)
            y -= 12
        }
        if ProcessInfo.processInfo.environment["EFFORT_CLICK_MAP"] != nil { print(rows.joined(separator: "\n")) }
        let all = rows.joined()
        for mark in ["P", "S", "B", "C"] {
            XCTAssertGreaterThanOrEqual(all.filter { String($0) == mark }.count, 10, "row \(mark) takes its clicks")
        }
    }
}
