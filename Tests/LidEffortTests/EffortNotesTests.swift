import XCTest
import SwiftUI
@testable import LidEffort

/// In the Claude or Codex app a change that waits, or cannot reach the chat
/// at all, has to say so — or it reads as spyx being broken.
final class EffortNotesTests: XCTestCase {
    private let languages = ["en", "fr", "ja", "pt-BR", "ru", "zh-Hans"]

    func testEveryReasonTheClaudeAppDidNotTakeItIsNamed() {
        let busy = EffortNotes.claudeApp(nil, session: "spyx")
        XCTAssertTrue(busy.text.contains("replying"), busy.text)
        XCTAssertTrue(busy.waits)

        let draft = EffortNotes.claudeApp(.draft, session: "spyx")
        XCTAssertTrue(draft.text.contains("Draft"), draft.text)
        XCTAssertTrue(draft.waits)
        XCTAssertEqual(EffortNotes.claudeApp(.userTyping, session: "spyx"), draft)

        let sent = EffortNotes.claudeApp(.sent, session: "spyx")
        XCTAssertTrue(sent.isLive)
        XCTAssertFalse(sent.waits)

        // Waiting will not grant a permission or make Claude take a command
        // it refused: those say what to do, and stop.
        let trust = EffortNotes.claudeApp(.notTrusted, session: "spyx")
        XCTAssertTrue(trust.text.contains("Accessibility"), trust.text)
        XCTAssertFalse(trust.waits)
        XCTAssertFalse(EffortNotes.claudeApp(.notSent, session: "spyx").waits)
        XCTAssertTrue(EffortNotes.claudeApp(.noComposer, session: "spyx").waits)
    }

    func testCodexSaysItsChatsKeepTheirLevel() {
        let app = EffortNotes.codex(frontBundleID: EffortNotes.codexBundleID, cliInView: false, value: "high")
        XCTAssertEqual(app?.text, "Codex app keeps each chat's effort · new chats start at high")
        XCTAssertNotNil(EffortNotes.codex(frontBundleID: "com.apple.Terminal", cliInView: true, value: "high"))
        XCTAssertNil(EffortNotes.codex(frontBundleID: "com.apple.Terminal", cliInView: false, value: "high"))
    }

    func testEveryNoteIsTranslatedAndFitsTheCard() {
        let notes: [(String) -> String] = [
            { EffortNotes.claudeApp(nil, session: $0).text },
            { EffortNotes.claudeApp(.notFront, session: $0).text },
            { EffortNotes.claudeApp(.notTrusted, session: $0).text },
            { EffortNotes.claudeApp(.noComposer, session: $0).text },
            { EffortNotes.claudeApp(.draft, session: $0).text },
            { EffortNotes.claudeApp(.notSent, session: $0).text },
            { _ in EffortNotes.claudeAppUnreached(typingOn: true).text },
            { _ in EffortNotes.claudeAppUnreached(typingOn: false).text },
            { _ in EffortNotes.codex(frontBundleID: EffortNotes.codexBundleID, cliInView: false, value: "xhigh")!.text },
            { _ in EffortNotes.codex(frontBundleID: EffortNotes.codexBundleID, cliInView: false, value: nil)!.text },
            { _ in EffortNotes.codex(frontBundleID: nil, cliInView: true, value: nil)!.text },
            { EffortNotes.delivered(to: $0) },
        ]
        // A session named the way Claude names them: long.
        let session = "Fix the lid effort card on Desktop"
        let english = notes.map { $0(session) }
        let limit = CGFloat(EffortChangeCard.noteLines) * NotchLayout.cardBodyLineHeight
        for code in languages {
            L10n.testLocale = Locale(identifier: code)
            defer { L10n.testLocale = nil }
            for (index, note) in notes.enumerated() {
                let text = note(session)
                if code != "en" { XCTAssertNotEqual(text, english[index], "\(code): untranslated") }
                XCTAssertTrue(!text.contains("%@") && !text.contains("%lld"), "\(code): \(text)")
                XCTAssertLessThanOrEqual(NotchLayout.bodyTextHeight(text), limit, "\(code) clips: \(text)")
            }
        }
    }
}

/// Return goes only to the exact command: what an input method made of it
/// — Telex turns `/effort low` into `/efort lơ` — is never sent.
final class ComposerExactnessTests: XCTestCase {
    func testOnlyTheExactCommandIsSent() {
        XCTAssertTrue(ClaudeDesktopComposer.holdsExactly("/effort low\n", "/effort low"))
        XCTAssertFalse(ClaudeDesktopComposer.holdsExactly("/efort lơ", "/effort low"))
        XCTAssertFalse(ClaudeDesktopComposer.holdsExactly("/effort ", "/effort low"))
        XCTAssertFalse(ClaudeDesktopComposer.holdsExactly("/effort lowx", "/effort low"))
        XCTAssertFalse(ClaudeDesktopComposer.holdsExactly("", "/effort low"))
    }
}

/// The Claude session on screen is read from Claude Desktop's window — the
/// page's address names it — not from its records' "last focused" time,
/// which is written late and named the session just left.
final class ClaudeAppViewTests: XCTestCase {
    func testTheSessionIdComesFromThePageAddress() {
        XCTAssertEqual(ClaudeDesktopComposer.hostSessionID(inAddress: "https://claude.ai/epitaxy/local_bc18f79e-676e-417b-ac3d-a2e80f577e0e"),
                       "local_bc18f79e-676e-417b-ac3d-a2e80f577e0e")
        XCTAssertEqual(ClaudeDesktopComposer.hostSessionID(inAddress: "https://claude.ai/epitaxy/local_bc18f79e-676e-417b-ac3d-a2e80f577e0e?tab=diff"),
                       "local_bc18f79e-676e-417b-ac3d-a2e80f577e0e")
        XCTAssertNil(ClaudeDesktopComposer.hostSessionID(inAddress: "https://claude.ai/chat/0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"))
        XCTAssertNil(ClaudeDesktopComposer.hostSessionID(inAddress: "http://localhost:3200/login"))
    }

    func testADesktopSessionCarriesItsIdAndTitle() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeAppViewTests-\(UUID().uuidString)")
        let sessions = home.appendingPathComponent(".claude/sessions")
        let records = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions/acct/org")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let pid = ProcessInfo.processInfo.processIdentifier
        try #"{"pid":\#(pid),"sessionId":"s1","entrypoint":"claude-desktop","hostSessionId":"local_abc","status":"idle"}"#
            .write(to: sessions.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        try #"{"title":"Fix the card","lastFocusedAt":1,"model":"claude-opus-5-5"}"#
            .write(to: records.appendingPathComponent("local_abc.json"), atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(SessionModels.desktop(hostSessionID: "local_abc", home: home))
        XCTAssertEqual(session.pid, pid)
        XCTAssertEqual(session.hostSessionID, "local_abc")
        XCTAssertEqual(session.title, "Fix the card")
        XCTAssertNil(SessionModels.desktop(hostSessionID: "local_other", home: home))
    }
}
