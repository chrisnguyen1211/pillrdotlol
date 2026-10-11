import XCTest
@testable import LidEffort

/// Two Claude rows say whose account each is, but not how to reach it: the
/// person types a command — `claude`, `claude-work`, an alias — and nothing on
/// the row said which command lands in which directory, nor which one plain
/// `claude` is. The commands are found by reading, never running, the small
/// wrapper scripts and aliases people write for this.
final class ClaudeLaunchCommandsTests: XCTestCase {
    private var root: URL!
    private var bin: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ClaudeLaunchCommandsTests.\(UUID().uuidString)")
        bin = root.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func script(_ name: String, _ body: String) throws {
        try ("#!/bin/zsh\n" + body).write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func find(rcFiles: [URL] = []) -> [String: [String]] {
        ClaudeLaunchCommands.find(home: root, searchDirectories: [bin], rcFiles: rcFiles)
    }

    private var main: String { root.appendingPathComponent(".claude").path }
    private var work: String { root.appendingPathComponent(".claude-work").path }

    func testPlainClaudeIsAlwaysTheDefault() {
        XCTAssertEqual(find()[main], ["claude"])
    }

    func testAWrapperSettingTheDirectoryBelongsToIt() throws {
        try script("claude-work", "export CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\"\nexec \"$HOME/.local/bin/claude\" \"$@\"\n")
        XCTAssertEqual(find()[work], ["claude-work"])
    }

    /// The user's own company wrapper: no directory of its own, so plain
    /// `claude`'s — it only clears the variable and runs it.
    func testAWrapperThatUnsetsTheDirectoryIsTheDefault() throws {
        try script("claude-company", "unset CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN\nexec \"$HOME/.local/bin/claude\" \"$@\"\n")
        XCTAssertEqual(find()[main], ["claude", "claude-company"])
    }

    func testTildeQuotedAndBracedHomeAllResolve() throws {
        try script("claude-a", "CLAUDE_CONFIG_DIR=~/.claude-work claude \"$@\"\n")
        try script("claude-b", "CLAUDE_CONFIG_DIR='\(work)' exec claude\n")
        try script("claude-c", "export CLAUDE_CONFIG_DIR=${HOME}/.claude-work; claude\n")
        XCTAssertEqual(find()[work], ["claude-a", "claude-b", "claude-c"])
    }

    func testAnAliasInAShellFileCounts() throws {
        let rc = root.appendingPathComponent(".zshrc")
        try """
        export PATH=$HOME/bin:$PATH
        alias cw='CLAUDE_CONFIG_DIR=~/.claude-work claude'
        # alias old='CLAUDE_CONFIG_DIR=~/.claude-old claude'
        alias ll='ls -l'
        """.write(to: rc, atomically: true, encoding: .utf8)
        let found = find(rcFiles: [rc])
        XCTAssertEqual(found[work], ["cw"])
        XCTAssertNil(found[root.appendingPathComponent(".claude-old").path], "a commented-out alias is not a command")
        XCTAssertEqual(found[main], ["claude"], "an alias that does not run claude is not listed")
    }

    /// Binaries and unrelated scripts are skipped, not misread.
    func testOnlyScriptsThatRunClaudeAreRead() throws {
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00]).write(to: bin.appendingPathComponent("claude-binary"))
        try script("claude-notes", "echo CLAUDE_CONFIG_DIR is for profiles\n")
        try script("other-work", "CLAUDE_CONFIG_DIR=~/.claude-work claude\n")
        XCTAssertEqual(find(), [main: ["claude"]])
    }
}

final class ClaudeLaunchLineTests: XCTestCase {
    func testTheDefaultSaysItIsTheDefault() {
        let home = URL(fileURLWithPath: "/Users/x")
        let main = ClaudeProfile.default(home: home)
        XCTAssertEqual(main.launchLine(commands: [main.configDirectory.path: ["claude", "claude-company"]]),
                       "Default login · open with claude, claude-company")
    }

    func testANamedLoginWithoutAWrapperGetsTheCommandThatAlwaysWorks() {
        let work = ClaudeProfile(slug: "work", configDirectory: URL(fileURLWithPath: "/Users/x/.claude-work"))
        XCTAssertEqual(work.launchLine(commands: [work.configDirectory.path: ["claude-work"]]), "Open with claude-work")
        XCTAssertEqual(work.launchLine(commands: [:]), "Open with CLAUDE_CONFIG_DIR='/Users/x/.claude-work' claude")
    }
}
