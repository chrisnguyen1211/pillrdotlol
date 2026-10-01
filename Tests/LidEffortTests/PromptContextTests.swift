import XCTest
@testable import LidEffort

/// Which session and which piece of work a prompt belongs to.
final class PromptContextTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    private func user(_ text: String, meta: Bool = false) -> String {
        line(["type": "user", "isMeta": meta, "message": ["role": "user", "content": text]])
    }
    private func toolResult() -> String {
        line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]])
    }
    private func assistant(_ text: String?, tool: Bool = false) -> String {
        var blocks: [[String: Any]] = []
        if let text { blocks.append(["type": "text", "text": text]) }
        if tool { blocks.append(["type": "tool_use", "name": "Bash"]) }
        return line(["type": "assistant", "message": ["role": "assistant", "content": blocks]])
    }

    func testYourLastMessageAndWhatClaudeSaidBeforeAsking() {
        let tail = [
            user("Fix the login bug"),
            assistant("Looking at auth.swift", tool: true),
            toolResult(),
            user("Now make the settings **Apple-like**, and smarter"),
            assistant("I'll start with the sidebar.", tool: true),
            toolResult(),
            assistant(nil, tool: true),
            toolResult(),
            assistant("Which layout should the panes use?", tool: true),
            line(["type": "last-prompt", "lastPrompt": "Now make the settings **Apple-like**, and smarter"]),
            line(["type": "custom-title", "customTitle": "PillLid"]),
        ].joined(separator: "\n")
        let context = PromptContext.parse(transcriptTail: tail)
        XCTAssertEqual(context.title, "PillLid")
        XCTAssertEqual(context.ask, "Now make the settings Apple-like, and smarter")
        XCTAssertEqual(context.lead, "Which layout should the panes use?", "the newest thing Claude said, not an earlier one")
    }

    func testClaudesWordsFromBeforeYourMessageAreNotItsReason() {
        let tail = [assistant("Done with the tests."), user("Deploy it"), assistant(nil, tool: true)].joined(separator: "\n")
        let context = PromptContext.parse(transcriptTail: tail)
        XCTAssertEqual(context.ask, "Deploy it")
        XCTAssertNil(context.lead, "that was said about the last request, not this one")
    }

    func testInjectedAndCommandMessagesAreNotYourAsk() {
        let tail = [user("Refactor the parser"), user("<command-name>/compact</command-name>"),
                    user("Caveat: generated", meta: true), assistant(nil, tool: true)].joined(separator: "\n")
        XCTAssertEqual(PromptContext.parse(transcriptTail: tail).ask, "Refactor the parser")
    }

    func testATailCutMidLineSkipsThePartialLine() {
        let tail = "sistant\",\"message\":{}}\n" + user("Ship it")
        XCTAssertEqual(PromptContext.parse(transcriptTail: tail).ask, "Ship it")
    }

    func testLongTextIsOneCardLine() {
        let long = String(repeating: "word ", count: 80)
        let cleaned = PromptContext.clean(long)!
        XCTAssertEqual(cleaned.count, 160)
        XCTAssertTrue(cleaned.hasSuffix("…"))
        XCTAssertEqual(PromptContext.clean("  * a\n\n  b  "), "a b")
        XCTAssertNil(PromptContext.clean("   "))
    }

    func testTheBranchIsReadFromHeadWithoutGit() throws {
        XCTAssertEqual(GitBranch.parse(head: "ref: refs/heads/feature/notch\n"), "feature/notch")
        XCTAssertEqual(GitBranch.parse(head: "3f9c2e1a0b8d7c6e5f4a3b2c1d0e9f8a7b6c5d4e\n"), "3f9c2e1")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("branch-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(GitBranch.read(at: nested.path), "main", "found from a folder inside the repository")

        // A worktree: `.git` is a file naming the real git dir.
        let worktree = root.appendingPathComponent("wt")
        let gitDir = root.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/abundance-stretch\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitBranch.read(at: worktree.path), "abundance-stretch")
    }

    func testAPromptCarriesItsTranscriptPath() throws {
        let json = #"{"session_id":"s","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        XCTAssertEqual(PendingPrompt(hookInput: Data(json.utf8))?.transcriptPath, "/tmp/t.jsonl")
    }

    /// Against a real transcript on this machine, when one is named.
    func testARealTranscript() throws {
        guard let path = ProcessInfo.processInfo.environment["EFFORT_TRANSCRIPT"] else { throw XCTSkip("no transcript named") }
        let context = try XCTUnwrap(PromptContext.load(transcript: path, cwd: ProcessInfo.processInfo.environment["EFFORT_CWD"]))
        print("CONTEXT title=\(context.title ?? "-") | branch=\(context.branch ?? "-")\nASK: \(context.ask ?? "-")\nLEAD: \(context.lead ?? "-")")
    }
}

import SwiftUI

@MainActor
final class PromptContextRenderTests: XCTestCase {
    func testTheCardSaysWhichWorkItIsAbout() throws {
        var ask = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"cwd":"/Users/me/Effort Lid","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layout should the settings panes use?","header":"Layout","multiSelect":false,"options":[{"label":"Sidebar","description":"System Settings style"},{"label":"Tabs","description":"Older preferences style"}]}]}}"#.utf8)))
        ask.sessionName = "PillLid"
        ask.pid = 2
        ask.context = PromptContext(title: "PillLid", ask: "Refactor the whole settings UI to be more Apple-like and smarter",
                                    lead: "I'll start with the sidebar and a search field.", branch: "main")
        var bash = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"cwd":"/Users/me/api","tool_name":"Bash","tool_input":{"command":"npm run migrate -- --env staging"}}"#.utf8)))
        bash.sessionName = "api-server"
        bash.context = PromptContext(title: nil, ask: "Add the invoices table and migrate staging",
                                     lead: "The migration is written; running it against staging now.", branch: "feat/invoices")
        let now = Date()
        let sessions = [
            AgentSession(id: "a", name: "api-server", detail: "Terminal · api", state: .busy, waitingFor: nil, since: now, processID: 1),
            AgentSession(id: "b", name: "PillLid", detail: "Desktop · Effort Lid", state: .idle, waitingFor: nil, since: now.addingTimeInterval(-600), processID: 2),
        ]
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 16) {
                PromptCard(prompt: ask, draft: .constant(PromptDraft(questions: ask.questions)), onAnswer: { _ in }, onOpen: {})
                PromptCard(prompt: bash, draft: .constant(PromptDraft(questions: [])), onAnswer: { _ in }, onOpen: {})
            }
            TooltipCard(
                snapshot: ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                           status: .ok, windows: [LimitWindow(id: "s", label: "Current session", usedFraction: 0.29)]),
                activity: ActivitySummary(sessions: sessions), now: now, sessionCap: 3,
                prompt: ask, promptWaiting: [2: now])
        }
        .padding(20).background(Color(white: 0.2))
        .environment(\.notchSurfaceStyle, .solid)
        .environment(\.colorScheme, .dark)
        .environment(\.drawsFieldsAsText, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("prompt-context.png"))
        }
        XCTAssertEqual(ask.subtitle, "PillLid · Effort Lid · ⎇ main")
        XCTAssertEqual(PromptLayout.contextRows(for: ask), 2)
        XCTAssertEqual(PromptLayout.contextAskLines(for: ask), 2, "a long ask gets its second line")
        XCTAssertGreaterThan(PromptCard.cardHeight(for: ask), PromptCard.cardHeight(for: { var p = ask; p.context = nil; return p }()),
                             "the card grows by the context it carries")
    }
}
