import XCTest
import SwiftUI
@testable import LidEffort

/// The prompt sits under the session that is asking, not above the list.
@MainActor
final class SessionListPlanTests: XCTestCase {
    private let now = Date()

    private func session(_ name: String, _ state: AgentSession.State, minutesAgo: Double, pid: pid_t?) -> AgentSession {
        AgentSession(id: name, name: name, detail: "Terminal · \(name)", state: state, waitingFor: nil,
                     since: now.addingTimeInterval(-minutesAgo * 60), processID: pid)
    }

    private func bash(pid: pid_t?) throws -> PendingPrompt {
        var p = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"tool_name":"Bash","tool_input":{"command":"npm test"}}"#.utf8), now: now))
        p.pid = pid
        return p
    }

    private var sessions: [AgentSession] {
        [session("pill-lid", .busy, minutesAgo: 0, pid: 10),
         session("nas-fix", .idle, minutesAgo: 39, pid: 20),
         session("abundance", .idle, minutesAgo: 52, pid: 30),
         session("old", .idle, minutesAgo: 90, pid: 40)]
    }

    func testTheAskingSessionComesFirstMarkedWaitingWithThePromptUnderIt() throws {
        let plan = SessionListPlan(sessions: sessions, cap: 3, prompt: try bash(pid: 20))
        XCTAssertEqual(plan.rows.map(\.name), ["nas-fix", "pill-lid", "abundance"])
        XCTAssertEqual(plan.promptOwner, "nas-fix")
        XCTAssertEqual(plan.rows[0].state, .waiting, "its registry says idle, but it is waiting on you")
        XCTAssertEqual(plan.rows[0].since, now, "waiting since the prompt came in")
        XCTAssertNil(plan.rows[0].waitingFor, "the second line keeps saying where it runs")
        XCTAssertEqual(plan.rows[0].detail, "Terminal · nas-fix")
        XCTAssertEqual(plan.active, 2)
        XCTAssertEqual(plan.hidden, 1)
    }

    func testEvenAOneRowListKeepsTheAsker() throws {
        let plan = SessionListPlan(sessions: sessions, cap: 1, prompt: try bash(pid: 40))
        XCTAssertEqual(plan.rows.map(\.name), ["old"])
        XCTAssertEqual(plan.promptOwner, "old")
    }

    func testAPromptFromASessionTheListDoesNotKnowStaysAboveIt() throws {
        let unknown = SessionListPlan(sessions: sessions, cap: 3, prompt: try bash(pid: 99))
        XCTAssertNil(unknown.promptOwner)
        let noPID = SessionListPlan(sessions: sessions, cap: 3, prompt: try bash(pid: nil))
        XCTAssertNil(noPID.promptOwner)
        XCTAssertEqual(noPID.rows.map(\.name), ["pill-lid", "nas-fix", "abundance"], "order as before")
    }

    func testASessionWaitingOnAnotherPromptIsMarkedToo() throws {
        let later = now.addingTimeInterval(-5)
        let plan = SessionListPlan(sessions: sessions, cap: 4, prompt: try bash(pid: 20), waiting: [20: now, 30: later])
        XCTAssertEqual(plan.rows.map(\.name), ["nas-fix", "abundance", "pill-lid", "old"],
                       "the asker, then the other waiting one, then what runs")
        XCTAssertEqual(plan.rows[1].state, .waiting)
        XCTAssertEqual(plan.active, 3)
    }

    func testNoPromptChangesNothing() {
        let plan = SessionListPlan(sessions: sessions, cap: 6, prompt: nil)
        XCTAssertEqual(plan.rows, sessions.sorted { a, b in
            (a.state == .busy ? 0 : 1, -a.since.timeIntervalSince1970) < (b.state == .busy ? 0 : 1, -b.since.timeIntervalSince1970)
        })
        XCTAssertNil(plan.promptOwner)
    }

    func testTheTooltipRendersThePromptUnderItsSession() throws {
        let prompt = try bash(pid: 20)
        func card(_ prompt: PendingPrompt) -> some View {
            TooltipCard(
                snapshot: ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                           status: .ok, windows: [LimitWindow(id: "s", label: "Current session", usedFraction: 0.29)]),
                activity: ActivitySummary(sessions: sessions), now: now, sessionCap: 3,
                effortValue: "high", effortDots: EffortDotState(count: 4, filled: 3),
                prompt: prompt, promptWaiting: prompt.pid.map { [$0: now] } ?? [:])
        }
        let unowned = try bash(pid: nil)
        let view = HStack(alignment: .top, spacing: 24) {
            card(prompt)
            card(unowned)
        }
        .padding(20).background(Color(white: 0.2))
        .environment(\.notchSurfaceStyle, .solid)
        .environment(\.colorScheme, .dark)
        .environment(\.drawsFieldsAsText, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("prompt-under-session.png"))
        }
        XCTAssertGreaterThan(image.size.width, 2 * NotchLayout.cardWidth)
    }
}

final class PixelLoaderTests: XCTestCase {
    func testTheChevronDrivesRight() {
        // Middle row leads, the corners follow a step behind, left to right.
        XCTAssertEqual(PixelLoader.delay(cell: 3), 0, accuracy: 1e-9)          // middle-left
        XCTAssertEqual(PixelLoader.delay(cell: 0), 0.09, accuracy: 1e-9)       // top-left
        XCTAssertEqual(PixelLoader.delay(cell: 6), 0.09, accuracy: 1e-9)       // bottom-left
        XCTAssertEqual(PixelLoader.delay(cell: 5), 0.18, accuracy: 1e-9)       // middle-right
        XCTAssertEqual(PixelLoader.delay(cell: 8), 0.27, accuracy: 1e-9)       // bottom-right
    }

    func testACellPulsesFromDimToFullOncePerCycle() {
        let start = 1000 * PixelLoader.cycle
        XCTAssertEqual(PixelLoader.opacity(cell: 3, at: start), PixelLoader.dim, accuracy: 1e-6)
        XCTAssertEqual(PixelLoader.opacity(cell: 3, at: start + PixelLoader.cycle / 2), 1, accuracy: 1e-6)
        XCTAssertEqual(PixelLoader.opacity(cell: 3, at: start + PixelLoader.cycle), PixelLoader.dim, accuracy: 1e-6)
        // Two fronts in flight: the sweep (0.27 s + a cycle) outlasts one cycle.
        XCTAssertLessThan(PixelLoader.cycle, PixelLoader.delay(cell: 8) + PixelLoader.cycle)
    }

    func testTheClockReadsInTenthsThenMinutesThenHours() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ElapsedCopy.clock(since: t0, now: t0.addingTimeInterval(4.27)), "4.2s")
        XCTAssertEqual(ElapsedCopy.clock(since: t0, now: t0.addingTimeInterval(64.2)), "1m 4.2s")
        XCTAssertEqual(ElapsedCopy.clock(since: t0, now: t0.addingTimeInterval(2 * 3600 + 5 * 60 + 9)), "2h 05m")
        XCTAssertEqual(ElapsedCopy.clock(since: t0, now: t0.addingTimeInterval(-3)), "0.0s", "never negative")
    }
}
