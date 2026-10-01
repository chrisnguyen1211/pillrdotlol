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
