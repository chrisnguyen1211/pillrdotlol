import XCTest
import SwiftUI
@testable import LidEffort

/// Several sessions can run in one folder. The done card names which one
/// finished, from its transcript, so the right one gets the reply.
@MainActor
final class DoneToastContextTests: XCTestCase {
    private func session(_ name: String = "shop-web", state: AgentSession.State = .success,
                         waitingFor: String? = nil) -> AgentSession {
        AgentSession(id: "claude.1", name: name, detail: "Terminal", state: state,
                     waitingFor: waitingFor, since: Date(timeIntervalSince1970: 1_000), processID: 1)
    }

    private func toast(_ session: AgentSession, blocked: Bool = false, context: PromptContext?) -> DoneToast {
        DoneToast(event: .init(session: session, reason: blocked ? .blocked : .finished, providerID: "claude"),
                  glyph: .claude, context: context)
    }

    func testTheCardSaysWhatYouAskedAndWhatTheAgentSaidLast() {
        let card = toast(session(), context: PromptContext(ask: "fix the login redirect", lead: "Fixed it: the callback kept the old host."))
        XCTAssertEqual(card.title, "“fix the login redirect”")
        XCTAssertEqual(card.status, "Fixed it: the callback kept the old host.")
        XCTAssertEqual(card.subtitle, "shop-web · Terminal")
    }

    func testANamedSessionLeadsWithItsName() {
        let card = toast(session(), context: PromptContext(title: "Checkout redesign", ask: "make the button blue", lead: "Done."))
        XCTAssertEqual(card.title, "Checkout redesign")
    }

    func testWhatChangedStillComesFirst() {
        var card = toast(session(), context: PromptContext(ask: "x", lead: "All tests pass."))
        card.changes = "3 files · +42 −7"
        XCTAssertEqual(card.status, "3 files · +42 −7 · All tests pass.")
    }

    func testAWaitingCardKeepsItsQuestionAndNamesTheSession() {
        let card = toast(session(state: .waiting, waitingFor: "Run the migration?"), blocked: true,
                         context: PromptContext(ask: "move users to the new table", lead: "Ready to migrate."))
        XCTAssertEqual(card.title, "“move users to the new table”")
        XCTAssertTrue(card.status.contains("Run the migration?"), card.status)
    }

    func testWithoutATranscriptTheCardIsAsBefore() {
        let plain = toast(session(), context: nil)
        XCTAssertTrue(DoneCheer.finished.map(\.title).contains(plain.title))
    }

    /// The end of a finished turn: your message, then the agent's work and
    /// its last words, which are what the card shows.
    func testAFinishedTurnReadsAsYourAskAndTheLastWords() {
        let tail = [
            #"{"type":"user","message":{"role":"user","content":"fix the login redirect"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the callback."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"**Fixed**: the callback kept the old host."}]}}"#,
        ].joined(separator: "\n")
        let context = PromptContext.parse(transcriptTail: tail)
        XCTAssertEqual(context.ask, "fix the login redirect")
        XCTAssertEqual(context.lead, "Fixed: the callback kept the old host.")
    }

    func testTheCardRenders() throws {
        let cards = VStack(spacing: 16) {
            DoneToastView(toast: toast(session(), context: PromptContext(ask: "fix the login redirect after OAuth",
                                                                         lead: "Fixed: the callback kept the old host. Tests pass.")))
            DoneToastView(toast: toast(session("shop-web"), context: PromptContext(title: "Checkout redesign", ask: "x",
                                                                                   lead: "Moved the pay button above the fold.")))
        }
        .environment(\.notchSurfaceStyle, .solid)
        .padding(20).background(Color(red: 0.12, green: 0.13, blue: 0.2))
        let renderer = ImageRenderer(content: cards.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("done-card-context.png"))
        }
    }

    /// An Antigravity session has no process of its own; its card opens
    /// Antigravity. Others with no process open nothing.
    func testAnAntigravityCardOpensAntigravity() {
        XCTAssertEqual(DoneToast.app(forSessionID: "antigravity.abc123"), "com.google.antigravity")
        XCTAssertNil(DoneToast.app(forSessionID: "claude.abc"))
        XCTAssertNil(DoneToast.app(forSessionID: "codex.abc"))
    }
}
