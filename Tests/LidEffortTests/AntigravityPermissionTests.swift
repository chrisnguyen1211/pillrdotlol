import XCTest
@testable import LidEffort

/// Antigravity: a permission it runs on its own passes through "waiting"
/// for an instant and must not bring a card up; and a session is named by
/// what you asked, not by the tags Antigravity wraps it in.
@MainActor
final class AntigravityPermissionTests: XCTestCase {
    private func session(_ state: AgentSession.State, _ waitingFor: String?) -> AgentSession {
        AgentSession(id: "antigravity.abc", name: "Antigravity", detail: waitingFor ?? "Working",
                     state: state, waitingFor: waitingFor, since: Date(timeIntervalSince1970: 0))
    }

    func testAPermissionThatPassesAtOnceIsNeverSaid() {
        var since: [String: Date] = [:]
        let start = Date(timeIntervalSince1970: 1_000)
        let waiting = [session(.waiting, L10n.t("Permission"))]
        let first = AntigravityActivityMonitor.settle(waiting, since: &since, now: start)
        XCTAssertEqual(first.first?.state, .busy, "just now: still working")
        let after = AntigravityActivityMonitor.settle([session(.busy, nil)], since: &since, now: start.addingTimeInterval(2))
        XCTAssertEqual(after.first?.state, .busy)
        XCTAssertTrue(since.isEmpty, "forgotten once it moved on")
        // Allowed by the person a moment later: waiting again starts afresh.
        XCTAssertEqual(AntigravityActivityMonitor.settle(waiting, since: &since, now: start.addingTimeInterval(3)).first?.state, .busy)
    }

    func testAPermissionThatStaysIsSaid() {
        var since: [String: Date] = [:]
        let start = Date(timeIntervalSince1970: 1_000)
        let waiting = [session(.waiting, L10n.t("Permission"))]
        _ = AntigravityActivityMonitor.settle(waiting, since: &since, now: start)
        let later = AntigravityActivityMonitor.settle(waiting, since: &since,
                                                      now: start.addingTimeInterval(AntigravityActivityMonitor.permissionHold + 0.5))
        XCTAssertEqual(later.first?.state, .waiting)
        XCTAssertEqual(later.first?.waitingFor, L10n.t("Permission"))
    }

    func testAQuestionIsSaidAtOnce() {
        var since: [String: Date] = [:]
        let asked = AntigravityActivityMonitor.settle([session(.waiting, L10n.t("Question"))], since: &since)
        XCTAssertEqual(asked.first?.state, .waiting, "a question is the agent's own words, not a status")
    }

    func testTheAskIsTakenOutOfAntigravitysTags() {
        let wrapped = """
        <USER_REQUEST>
        sửa lại phần thiếu sót: categories và labels
        </USER_REQUEST>
        <ADDITIONAL_METADATA>
        The current local time is: 2026-10-12T09:00:00+07:00.
        </ADDITIONAL_METADATA>
        """
        XCTAssertEqual(SessionContext.antigravityAsk(wrapped), "sửa lại phần thiếu sót: categories và labels")
        XCTAssertEqual(SessionContext.antigravityAsk("plain ask <ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>"), "plain ask")
        XCTAssertEqual(SessionContext.antigravityAsk("no tags at all"), "no tags at all")
        let context = SessionContext.antigravity(lines: [["type": "USER_INPUT", "source": "USER_EXPLICIT", "content": wrapped]])
        XCTAssertFalse((context.title ?? context.ask ?? "").contains("<USER_REQUEST>"))
    }

    /// Every agent's wrapping comes off the same way.
    func testNoAgentsWrappingReachesTheCard() {
        XCTAssertEqual(PromptContext.clean("<user_query>\nfix the login\n</user_query>"), "fix the login", "Cursor")
        XCTAssertEqual(PromptContext.clean("<environment_context>\n<cwd>/x</cwd>\n</environment_context>\nrun the tests"),
                       "run the tests", "Codex")
        XCTAssertEqual(PromptContext.clean("check this <system-reminder>be brief</system-reminder>"), "check this", "Claude Code")
        XCTAssertNil(PromptContext.clean("<local-command-stdout>ok</local-command-stdout>"), "nothing of yours: no ask")
        XCTAssertEqual(PromptContext.clean("make the <div>wider</div> please"), "make the <div>wider</div> please",
                       "a tag someone wrote stays")
    }
}
