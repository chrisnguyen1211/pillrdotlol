import XCTest
@testable import LidEffort

/// A second Claude Code login often shares the first one's configuration:
/// `~/.claude-work/settings.json`, `projects` and the rest are symlinks into
/// `~/.claude`, while `.claude.json` and `sessions` stay its own. Everything
/// pillr does per profile has to hold up on that layout — find the second
/// login's sessions, write through the links rather than over them, and count
/// a shared transcript folder once.
final class ClaudeSharedProfileTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ClaudeSharedProfileTests.\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// `~/.claude` with real files, `~/.claude-work` linking its settings and
    /// projects there and keeping its own sessions.
    private func sharedHome() throws -> (main: ClaudeProfile, work: ClaudeProfile) {
        let main = ClaudeProfile.default(home: root)
        let work = ClaudeProfile(slug: "work", configDirectory: root.appendingPathComponent(".claude-work"))
        try fm.createDirectory(at: main.projectsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: main.sessionsDirectory, withIntermediateDirectories: true)
        try "{}\n".write(to: main.settingsURL, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: work.sessionsDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: work.settingsURL, withDestinationURL: main.settingsURL)
        try fm.createSymbolicLink(at: work.projectsDirectory, withDestinationURL: main.projectsDirectory)
        return (main, work)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // MARK: - Writing through a link

    /// Replacing a symlinked file must update what it points at, not swap the
    /// link for a regular file — that would silently stop the second login
    /// sharing the first one's settings.
    func testReplacingASymlinkedFileKeepsTheLink() throws {
        let (main, work) = try sharedHome()
        try EffortTargetWriter.replaceContents(of: work.settingsURL, with: "{\"model\":\"opus\"}\n")
        XCTAssertTrue(isSymlink(work.settingsURL), "the link is still a link")
        XCTAssertEqual(try String(contentsOf: main.settingsURL, encoding: .utf8), "{\"model\":\"opus\"}\n")
    }

    func testReplacingARegularFileStillWorks() throws {
        let url = root.appendingPathComponent("plain.json")
        try "old".write(to: url, atomically: true, encoding: .utf8)
        try EffortTargetWriter.replaceContents(of: url, with: "new")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertFalse(isSymlink(url))
    }

    func testInstallingHooksThroughALinkKeepsTheLink() throws {
        let (main, work) = try sharedHome()
        try ClaudeHookInstaller.installStop(executable: "/A/pillr", at: work.settingsURL)
        XCTAssertTrue(isSymlink(work.settingsURL))
        XCTAssertTrue(ClaudeHookInstaller.isStopInstalled(at: main.settingsURL))
    }

    // MARK: - One settings file, one install

    func testProfilesSharingASettingsFileAreHookedOnce() throws {
        let (main, work) = try sharedHome()
        XCTAssertEqual(ClaudeHookInstaller.settingsURLs(profiles: [main, work]), [main.settingsURL])
    }

    func testProfilesWithTheirOwnSettingsAreHookedEach() throws {
        let main = ClaudeProfile.default(home: root)
        let work = ClaudeProfile(slug: "work", configDirectory: root.appendingPathComponent(".claude-work"))
        try fm.createDirectory(at: main.configDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: work.configDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeHookInstaller.settingsURLs(profiles: [main, work]),
                       [main.settingsURL, work.settingsURL])
    }

    func testInstallAndRemoveCoverEverySettingsFile() throws {
        let a = root.appendingPathComponent("a.json"), b = root.appendingPathComponent("b.json")
        try ClaudeHookInstaller.install(executable: "/A/pillr", at: [a, b])
        XCTAssertTrue(ClaudeHookInstaller.isInstalled(at: [a, b]))
        try ClaudeHookInstaller.remove(at: [a])
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(at: [a, b]), "installed in only one is not installed")
        try ClaudeHookInstaller.remove(at: [a, b])
        XCTAssertFalse(ClaudeHookInstaller.isInstalled(at: b))
    }

    /// One unreadable file must not cost the other logins their hook — nor,
    /// on uninstall, leave theirs pointing at an app that is gone.
    func testAFailingFileDoesNotStopTheOthers() throws {
        let broken = root.appendingPathComponent("broken.json"), good = root.appendingPathComponent("good.json")
        try "{ trailing, }".write(to: broken, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeHookInstaller.installStop(executable: "/A/pillr", at: [broken, good]))
        XCTAssertTrue(ClaudeHookInstaller.isStopInstalled(at: good), "the file after the broken one still gets it")
        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "{ trailing, }", "the broken one is left alone")
    }

    /// A link into a store that cannot be written (a dotfile manager's) keeps
    /// working the way it did before: the link is replaced by the new file.
    func testAReadOnlyTargetFallsBackToReplacingTheLink() throws {
        let store = root.appendingPathComponent("store")
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let target = store.appendingPathComponent("config.toml")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.path) }
        let link = root.appendingPathComponent("config.toml")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        try EffortTargetWriter.replaceContents(of: link, with: "new")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old")
    }

    func testRemovingLeavesAFileWithoutOurHookUntouched() throws {
        let url = root.appendingPathComponent("theirs.json")
        let text = "{ \"model\" : \"opus\" }"
        try text.write(to: url, atomically: true, encoding: .utf8)
        try ClaudeHookInstaller.remove(at: [url])
        try ClaudeHookInstaller.removeStop(at: [url])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "not even reformatted")
    }

    // MARK: - Sessions in every profile

    /// A hook names a session; the second login's sessions live in its own
    /// registry, which the lookup used to skip — so its prompts never reached
    /// the session that asked.
    func testASessionIsFoundInTheSecondProfilesRegistry() throws {
        let (main, work) = try sharedHome()
        let record = #"{"pid":4242,"sessionId":"work-session"}"#
        try record.write(to: work.sessionsDirectory.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessionLookup.pid(forSessionID: "work-session",
                                               in: [main.sessionsDirectory, work.sessionsDirectory]), 4242)
        XCTAssertNil(ClaudeSessionLookup.pid(forSessionID: "missing",
                                             in: [main.sessionsDirectory, work.sessionsDirectory]))
    }

    func testEveryProfileDirectoryIsListedByNameAlone() throws {
        try fm.createDirectory(at: root.appendingPathComponent(".claude-work"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".claude-b"), withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent(".claude-file").path, contents: Data())
        let names = ClaudeProfile.configDirectories(home: root).map(\.lastPathComponent)
        XCTAssertEqual(names, [".claude", ".claude-b", ".claude-work"])
    }

    // MARK: - A shared transcript folder counts once

    func testDistinctByResolvedPathDropsLinksToTheSameFolder() throws {
        let (main, work) = try sharedHome()
        let distinct = ClaudeProfile.distinctByResolvedPath([main.projectsDirectory, work.projectsDirectory])
        XCTAssertEqual(distinct, [main.projectsDirectory])
    }

    func testOnlyTheFirstAccountOnASharedFolderIndexesIt() throws {
        let (main, work) = try sharedHome()
        let own = root.appendingPathComponent(".claude-own")
        try fm.createDirectory(at: own.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let accounts = [
            CostAccount(id: "claude", provider: "claude", name: "Claude", configDirectory: main.configDirectory),
            CostAccount(id: "claude-work", provider: "claude", name: "Claude (work)", configDirectory: work.configDirectory),
            CostAccount(id: "claude-own", provider: "claude", name: "Claude (own)", configDirectory: own),
        ]
        XCTAssertTrue(accounts[0].indexesTranscripts(among: accounts))
        XCTAssertFalse(accounts[1].indexesTranscripts(among: accounts), "same folder as the first: counted there")
        XCTAssertTrue(accounts[2].indexesTranscripts(among: accounts))
        XCTAssertEqual(accounts[1].transcriptOwner(among: accounts)?.name, "Claude",
                       "named in Settings as where its turns are counted")
        XCTAssertNil(accounts[2].transcriptOwner(among: accounts))
    }
}
