import XCTest
import SwiftUI
@testable import LidEffort

final class PendingPromptTests: XCTestCase {
    static let bash = #"{"session_id":"s-1","cwd":"/Users/me/app","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],"behavior":"allow","destination":"localSettings"}]}"#
    static let question = #"{"session_id":"s-2","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which colour?","header":"Colour","multiSelect":false,"options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}]},{"question":"Which sides?","header":"Sides","multiSelect":true,"options":[{"label":"Left"},{"label":"Right"}]}]}}"#

    func testAPermissionPromptIsReadWithItsCommandAndSuggestion() throws {
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(Self.bash.utf8)))
        XCTAssertEqual(prompt.toolName, "Bash")
        XCTAssertEqual(prompt.sessionID, "s-1")
        XCTAssertEqual(prompt.summary, "npm test")
        XCTAssertTrue(prompt.canRemember)
        XCTAssertFalse(prompt.isQuestion)
    }

    func testAFilePathIsShownRelativeToTheSession() throws {
        let json = #"{"tool_name":"Edit","cwd":"/Users/me/app","tool_input":{"file_path":"/Users/me/app/Sources/x.swift"}}"#
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        XCTAssertEqual(prompt.summary, "Edit Sources/x.swift")
    }

    func testAQuestionIsReadWithItsOptions() throws {
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(Self.question.utf8)))
        XCTAssertTrue(prompt.isQuestion)
        XCTAssertEqual(prompt.questions.count, 2)
        XCTAssertEqual(prompt.questions[0].options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(prompt.questions[0].options[1].description, "Cool")
        XCTAssertTrue(prompt.questions[1].multiSelect)
    }

    func testGarbageIsNotAPrompt() {
        XCTAssertNil(PendingPrompt(hookInput: Data("not json".utf8)))
        XCTAssertNil(PendingPrompt(hookInput: Data(#"{"session_id":"x"}"#.utf8)))
    }

    private func decision(_ data: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(output["decision"] as? [String: Any])
    }

    func testTheHookOutputForEachAnswer() throws {
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(Self.bash.utf8)))
        XCTAssertEqual(try decision(PromptResponse.json(for: .allow, prompt: prompt))["behavior"] as? String, "allow")
        let deny = try decision(PromptResponse.json(for: .deny, prompt: prompt))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertNotNil(deny["message"] as? String)
        let always = try decision(PromptResponse.json(for: .allowAlways, prompt: prompt))
        XCTAssertEqual((always["updatedPermissions"] as? [Any])?.count, 1)
        XCTAssertTrue(PromptResponse.json(for: .passThrough, prompt: prompt).isEmpty,
                      "no decision leaves Claude to ask in its own dialog")
    }

    func testAnswersGoBackInTheToolInputWithMultiSelectJoined() throws {
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(Self.question.utf8)))
        let data = PromptResponse.json(for: .answers(["Which colour?": ["Blue"], "Which sides?": ["Left", "Right"]]), prompt: prompt)
        let decision = try decision(data)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let input = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual((input["questions"] as? [Any])?.count, 2, "the questions are handed back as they came")
        XCTAssertEqual(input["answers"] as? [String: String], ["Which colour?": "Blue", "Which sides?": "Left, Right"])
    }
}

@MainActor
final class PromptBrokerTests: XCTestCase {
    private var path: String!
    private var broker: PromptBroker!

    override func setUp() async throws {
        path = "/tmp/lid-prompt-\(UUID().uuidString.prefix(8)).sock"
        broker = PromptBroker(path: path, patience: 5)
    }

    override func tearDown() async throws {
        broker.stop()
    }

    /// The hook's side, off the main actor: it blocks until answered.
    private func ask(_ json: String) async -> Data? {
        let path = self.path!
        return await Task.detached { PromptHookClient.exchange(Data(json.utf8), path: path) }.value
    }

    func testAHeldPromptIsAnsweredFromTheApp() async throws {
        var received: PendingPrompt?
        broker.onPrompt = { received = $0; return nil }
        try broker.start()
        let pending = Task { await ask(PendingPromptTests.bash) }
        // Wait for the prompt to arrive, then answer it as a click would.
        for _ in 0..<100 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
        let prompt = try XCTUnwrap(received)
        broker.answer(prompt.id, with: .allow)
        let reply = await pending.value
        let data = try XCTUnwrap(reply)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""behavior":"allow""#), text)
    }

    func testAPromptInViewIsHandedStraightBack() async throws {
        broker.onPrompt = { _ in .passThrough }
        try broker.start()
        let answered = await ask(PendingPromptTests.bash)
        let data = try XCTUnwrap(answered)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testNobodyRunningMeansNoAnswerAndNoStall() async {
        // No broker started: the hook must come back empty at once.
        let started = Date()
        let data = await ask(PendingPromptTests.bash)
        XCTAssertNil(data)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAHookThatGoesAwayWithdrawsItsPrompt() async throws {
        var received: PendingPrompt?
        var gone: UUID?
        broker.onPrompt = { received = $0; return nil }
        broker.onGone = { gone = $0 }
        try broker.start()

        // A client that sends and then hangs up, as a killed hook does.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = PromptBroker.address(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let line = Array((PendingPromptTests.bash + "\n").utf8)
        _ = write(fd, line, line.count)
        for _ in 0..<100 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
        close(fd)
        for _ in 0..<100 where gone == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(gone, received?.id)
    }

    func testAnUnansweredPromptIsLetGoAfterItsPatience() async throws {
        broker = PromptBroker(path: path, patience: 0.3)
        var gone = false
        broker.onPrompt = { _ in nil }
        broker.onGone = { _ in gone = true }
        try broker.start()
        let data = await ask(PendingPromptTests.bash)
        XCTAssertEqual(String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "")
        for _ in 0..<50 where !gone { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(gone)
    }
}

final class ClaudeHookInstallerTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testInstallAddsOneEntryAndKeepsEverythingElse() throws {
        let existing = #"{"effortLevel":"high","model":"opus","hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/mine"}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try existing.write(to: url, atomically: true, encoding: .utf8)

        try ClaudeHookInstaller.install(executable: "/Apps/Lid Effort.app/Contents/MacOS/LidEffort", at: url)
        try ClaudeHookInstaller.install(executable: "/Apps/Lid Effort.app/Contents/MacOS/LidEffort", at: url)

        let json = try read()
        XCTAssertEqual(json["effortLevel"] as? String, "high")
        XCTAssertEqual(json["model"] as? String, "opus")
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"], "other events are left alone")
        let groups = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2, "the person's own hook stays, and ours is there once")
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(at: url))
        let command = try XCTUnwrap(((groups.last?["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        XCTAssertEqual(command, "'/Apps/Lid Effort.app/Contents/MacOS/LidEffort' --prompt-hook")
    }

    func testRemoveTakesOnlyOurs() throws {
        let existing = #"{"hooks":{"PermissionRequest":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/mine"}]}]}}"#
        try existing.write(to: url, atomically: true, encoding: .utf8)
        try ClaudeHookInstaller.install(executable: "/x/LidEffort", at: url)
        try ClaudeHookInstaller.remove(at: url)
        let groups = try XCTUnwrap((try read()["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(at: url))
    }

    func testRemovingTheLastHookLeavesNoEmptyShells() throws {
        try #"{"effortLevel":"low"}"#.write(to: url, atomically: true, encoding: .utf8)
        try ClaudeHookInstaller.install(executable: "/x/LidEffort", at: url)
        try ClaudeHookInstaller.remove(at: url)
        let json = try read()
        XCTAssertNil(json["hooks"])
        XCTAssertEqual(json["effortLevel"] as? String, "low")
    }
}

@MainActor
final class PromptRenderTests: XCTestCase {
    func testThePromptCardsRender() throws {
        var bash = try XCTUnwrap(PendingPrompt(hookInput: Data(PendingPromptTests.bash.utf8)))
        bash.sessionName = "effort-lid-3c"
        var question = try XCTUnwrap(PendingPrompt(hookInput: Data(PendingPromptTests.question.utf8)))
        question.sessionName = "my-app-0a"
        let now = Date()
        let sessions: [AgentSession] = (0..<5).map { (i: Int) -> AgentSession in
            let name: String = i == 0 ? "effort-lid-3c" : "session-\(i)"
            let state: AgentSession.State = i == 0 ? .waiting : .idle
            return AgentSession(id: "s\(i)", name: name, detail: "Terminal · project",
                                state: state, waitingFor: nil, since: now.addingTimeInterval(-Double(i) * 900))
        }
        let snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                        status: .ok, windows: [LimitWindow(id: "s", label: "Current session", usedFraction: 0.29)])
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 16) {
                PromptCard(prompt: bash, draft: .constant(PromptDraft(questions: bash.questions)), direction: .trailing, onAnswer: { _ in }, onOpen: {})
                PromptCard(prompt: question, draft: .constant(PromptDraft(questions: question.questions)), direction: .trailing, onAnswer: { _ in }, onOpen: {})
            }
            TooltipCard(
                snapshot: snapshot,
                activity: ActivitySummary(sessions: sessions), now: now, sessionCap: 3,
                effortValue: "high", effortDots: EffortDotState(count: 4, filled: 3),
                prompt: bash)
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
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("prompts.png"))
        }
        XCTAssertGreaterThan(image.size.width, 2 * NotchLayout.cardWidth)
    }
}
