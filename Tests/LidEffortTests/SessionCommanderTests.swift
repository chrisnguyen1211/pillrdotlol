import XCTest
@testable import LidEffort

/// Writing to a session from the notch: one line, nothing that can escape
/// the AppleScript string it is typed through.
final class SessionCommanderTests: XCTestCase {
    func testAMessageBecomesOneLine() {
        XCTAssertEqual(SessionCommander.oneLine("  fix the build\nthen run tests\t "), "fix the build then run tests")
        XCTAssertEqual(SessionCommander.oneLine("bell\u{7}less"), "bellless")
        XCTAssertNil(SessionCommander.oneLine(" \n\t "))
        XCTAssertEqual(SessionCommander.oneLine(String(repeating: "a", count: 5000))?.count, 4000)
    }

    func testTheAppleScriptLiteralCannotBeEscaped() throws {
        let nasty = #"ok" & (do shell script "touch /tmp/pwned") & "\ end \\ "quoted""#
        let source = "return " + SessionCommander.appleScriptLiteral(nasty)
        var error: NSDictionary?
        let result = try XCTUnwrap(NSAppleScript(source: source)).executeAndReturnError(&error)
        XCTAssertNil(error)
        XCTAssertEqual(result.stringValue, nasty, "the text comes back as text, never as script")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    @MainActor
    func testASessionWithoutAProcessCannotBeReachedOrStopped() {
        let session = AgentSession(id: "codex.x", name: "codex", detail: "", state: .busy, waitingFor: nil, since: Date())
        XCTAssertEqual(SessionCommander.reach(session), .none)
        XCTAssertFalse(SessionCommander.canStop(session))
    }

    @MainActor
    func testOnlyABusySessionCanBeStopped() {
        let idle = AgentSession(id: "claude.1", name: "x", detail: "", state: .idle, waitingFor: nil,
                                since: Date(), processID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(SessionCommander.canStop(idle))
    }
}

/// What the composer may take back out of the Claude app's message box:
/// only what pillr put there — never a draft of yours.
final class ComposerOwnershipTests: XCTestCase {
    func testOnlyOurOwnTextIsOurs() {
        XCTAssertTrue(ClaudeDesktopComposer.isOurs("hi", "hi"))
        XCTAssertTrue(ClaudeDesktopComposer.isOurs("hihi", "hi"), "a slow insert and a paste both landing")
        XCTAssertTrue(ClaudeDesktopComposer.isOurs("Add a te", "Add a test"), "part of it, still arriving")
        XCTAssertTrue(ClaudeDesktopComposer.isOurs("/effort high\n", "/effort high"))
        XCTAssertFalse(ClaudeDesktopComposer.isOurs("my own draft", "hi"))
        XCTAssertFalse(ClaudeDesktopComposer.isOurs("", "hi"))
    }
}

/// The reply panel sits beside the tooltip it came from, on the side away
/// from the pill's edge, and never off screen.
@MainActor
final class ReplyPanelPlacementTests: XCTestCase {
    private let size = CGSize(width: 460, height: 132)

    func testItSitsAwayFromThePillsEdge() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let f = screen.visibleFrame
        let right = CGRect(x: f.maxX - 300, y: f.midY - 200, width: 300, height: 400)
        let origin = ReplyPanelController.origin(size: size, anchor: (right, screen, .right),
                                                 pointer: CGPoint(x: right.midX, y: right.midY + 50))
        XCTAssertEqual(origin.x + size.width, right.minX - 12, accuracy: 0.5, "left of a tooltip on the right edge")
        XCTAssertEqual(origin.y + size.height / 2, right.midY + 50, accuracy: 0.5, "level with the row under the pointer")

        let left = CGRect(x: f.minX, y: f.midY - 200, width: 300, height: 400)
        XCTAssertEqual(ReplyPanelController.origin(size: size, anchor: (left, screen, .left), pointer: .zero).x,
                       left.maxX + 12, accuracy: 0.5)

        let top = CGRect(x: f.midX - 150, y: f.maxY - 300, width: 300, height: 300)
        let below = ReplyPanelController.origin(size: size, anchor: (top, screen, .top), pointer: .zero)
        XCTAssertEqual(below.y + size.height, top.minY - 12, accuracy: 0.5, "under a tooltip at the top")
    }

    func testItStaysOnScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let f = screen.visibleFrame
        let low = CGRect(x: f.maxX - 300, y: f.minY, width: 300, height: 60)
        let origin = ReplyPanelController.origin(size: size, anchor: (low, screen, .right), pointer: CGPoint(x: low.midX, y: f.minY + 2))
        XCTAssertGreaterThanOrEqual(origin.y, f.minY + 8)
        XCTAssertGreaterThanOrEqual(origin.x, f.minX + 8)
    }
}

/// A card or field about a session wears its agent's mark — never Claude's
/// for a Grok session just because Grok has no ring here.
final class AgentMarkTests: XCTestCase {
    private func session(_ id: String) -> AgentSession {
        AgentSession(id: id, name: "x", detail: "", state: .idle, waitingFor: nil, since: Date())
    }

    func testEachAgentHasItsOwnMark() {
        XCTAssertEqual(ProviderGlyph.forSession(session("claude.4527")), .claude)
        XCTAssertEqual(ProviderGlyph.forSession(session("grok.01a0f8aa")), .grok)
        XCTAssertEqual(ProviderGlyph.forSession(session("codex.rollout-1.jsonl")), .openai)
        XCTAssertEqual(ProviderGlyph.forSession(session("codex-work.desktop")), .openai)
        XCTAssertEqual(ProviderGlyph.forSession(session("cursor.abc")), .cursor)
        XCTAssertEqual(ProviderGlyph.forSession(session("kimi.s1")), .kimi)
        XCTAssertEqual(ProviderGlyph.forProvider("gemini-api"), .geminiSpark)
        XCTAssertEqual(ProviderGlyph.forProvider("claude-work"), .claude)
        XCTAssertEqual(ProviderGlyph.forProvider("grok")?.agentName, "Grok")
    }
}

/// The fixes from testing replies: `/effort` typed into its own tab only,
/// iTerm2's refusals told apart from a missing tab, a paste only where it
/// surely lands in the session's tab, and the clipboard put back only if it
/// is still ours.
@MainActor
final class ReplyDeliveryTests: XCTestCase {
    func testEffortIsTypedIntoTheTabWithThatTTYAndNoOther() {
        let script = EffortInjector.effortScript("/effort high", tty: "ttys01")
        XCTAssertTrue(script.contains(#"is "/dev/ttys01""#), script)
        XCTAssertFalse(script.contains("contains"), "a prefix match reached /dev/ttys010 too")
    }

    func testITermTellsARefusalFromAMissingTab() {
        let idle = "some output\n❯ "
        // The script failing — no Automation, or iTerm2 gone — is a refusal.
        XCTAssertEqual(ITermWriter.write("hi", tty: "ttys003", run: { _ in nil }), .appleScriptError("read"))
        XCTAssertEqual(ITermWriter.write("hi", tty: "ttys003", run: { _ in "\u{3}" }), .tabNotFound)
        XCTAssertEqual(ITermWriter.write("hi", tty: "ttys003", run: { _ in "✻ Working… (esc to interrupt)\n❯ " }),
                       .promptNotIdle)
        var calls = 0
        let sent = ITermWriter.write("hi", tty: "ttys003", run: { _ in
            calls += 1
            return calls == 1 ? idle : "sent"
        })
        XCTAssertEqual(sent, .sent)
        calls = 0
        XCTAssertEqual(ITermWriter.write("hi", tty: "ttys003", run: { _ in
            calls += 1
            return calls == 1 ? idle : nil
        }), .appleScriptError("write"))
        XCTAssertEqual(ITermWriter.write("hi", tty: "../etc", run: { _ in idle }), .noTTY)
    }

    func testAPasteGoesAheadOnlyWhereItSurelyLandsInTheSessionsTab() {
        let hints = ["checkout-redesign", "Fix the cart"]
        typealias W = PasteTarget.Window
        // The terminal chose the tab itself.
        XCTAssertTrue(PasteTarget.isSure(tabSelected: true, window: nil, hints: hints))
        // One window with no tabs: nothing else could be in front.
        XCTAssertTrue(PasteTarget.isSure(tabSelected: false, window: W(count: 1, hasTabs: false, title: "zsh"), hints: hints))
        // The window in front names the session's folder, or the session.
        XCTAssertTrue(PasteTarget.isSure(tabSelected: false, window: W(count: 3, hasTabs: true, title: "~/code/Checkout-Redesign — zsh"), hints: hints))
        XCTAssertTrue(PasteTarget.isSure(tabSelected: false, window: W(count: 2, hasTabs: false, title: "✳ Fix the cart"), hints: hints))
        // Anything else may be another tab: copied, not pasted.
        XCTAssertFalse(PasteTarget.isSure(tabSelected: false, window: W(count: 3, hasTabs: true, title: "other-project"), hints: hints))
        XCTAssertFalse(PasteTarget.isSure(tabSelected: false, window: W(count: 1, hasTabs: true, title: nil), hints: hints))
        XCTAssertFalse(PasteTarget.isSure(tabSelected: false, window: nil, hints: hints))
        // A hint too short to mean anything matches nothing.
        XCTAssertFalse(PasteTarget.isSure(tabSelected: false, window: W(count: 2, hasTabs: true, title: "a b"), hints: ["a"]))
    }

    func testTheHintsAreTheFolderAndTheSessionsName() {
        let session = AgentSession(id: "claude.1", name: "Fix the cart", detail: "", state: .idle,
                                   waitingFor: nil, since: Date())
        XCTAssertEqual(PasteTarget.hints(session: session, cwd: "/Users/me/code/shop"), ["shop", "Fix the cart"])
        XCTAssertEqual(PasteTarget.hints(session: session, cwd: "/"), ["Fix the cart"])
        XCTAssertEqual(PasteTarget.hints(session: session, cwd: nil), ["Fix the cart"])
    }

    func testTheClipboardIsPutBackOnlyIfNothingWasCopiedSince() {
        let board = NSPasteboard(name: NSPasteboard.Name("pillr-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = [[(.string, Data("what you had".utf8))]]

        board.clearContents()
        board.setString("the reply", forType: .string)
        let ours = board.changeCount
        XCTAssertTrue(SessionCommander.restore(saved, to: board, ifStill: ours))
        XCTAssertEqual(board.string(forType: .string), "what you had")

        board.clearContents()
        board.setString("the reply", forType: .string)
        let mine = board.changeCount
        board.clearContents()
        board.setString("copied by you meanwhile", forType: .string)
        XCTAssertFalse(SessionCommander.restore(saved, to: board, ifStill: mine))
        XCTAssertEqual(board.string(forType: .string), "copied by you meanwhile", "yours stays")
    }
}
