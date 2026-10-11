import XCTest
import LidEffortCore
@testable import LidEffort

/// A command runner that answers from a script and remembers what it was
/// asked, so no test ever starts tmux, Zellij, kitty or WezTerm.
private final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [HostCommand] = []
    private let answer: (HostCommand) -> HostCommand.Result?

    init(_ answer: @escaping (HostCommand) -> HostCommand.Result?) { self.answer = answer }

    var commands: [HostCommand] { lock.lock(); defer { lock.unlock() }; return log }
    var arguments: [[String]] { commands.map(\.arguments) }

    var run: HostCommand.Runner {
        { [self] command in
            lock.lock()
            log.append(command)
            lock.unlock()
            return answer(command)
        }
    }

    static func ok(_ output: String = "") -> HostCommand.Result { .init(status: 0, output: output) }
    static let failed = HostCommand.Result(status: 1, output: "")
}

/// A made-up process tree: parents, environments, binaries and ttys.
private struct FakeTree {
    var parents: [pid_t: pid_t] = [:]
    var env: [pid_t: [String]] = [:]
    var paths: [pid_t: String] = [:]
    var ttys: [pid_t: String] = [:]

    var facts: ProcessFacts {
        let parents = parents, env = env, paths = paths, ttys = ttys
        return ProcessFacts(
            ancestry: { pid in
                var chain: [pid_t] = []
                var current: pid_t? = pid
                while let p = current, p > 1, chain.count < 12 {
                    chain.append(p)
                    current = parents[p]
                }
                return chain
            },
            environment: { env[$0] ?? [] },
            executablePath: { paths[$0] },
            tty: { ttys[$0] }
        )
    }
}

private let anyTool: (String) -> Bool = { _ in true }
private let noPause: @Sendable () -> Void = {}
private let idleScreen = "● Done.\n╭──────────────╮\n│ ❯            │\n╰──────────────╯\n  ? for shortcuts"
private let draftScreen = "● Done.\n────────────────\n❯ half a thought\n────────────────"
private let busyScreen = "✻ Working… (esc to interrupt)\n────────────────\n❯ \n────────────────"

// MARK: - Running tools

final class HostCommandTests: XCTestCase {
    /// Arguments reach the tool as they are: no shell sees them.
    func testArgumentsAreNeverReadByAShell() throws {
        let marker = NSTemporaryDirectory() + "pillr-pwned-\(UUID().uuidString)"
        let nasty = "$(touch \(marker)); `touch \(marker)` && echo 'x' | rm -rf ~ \"q\""
        let result = try XCTUnwrap(HostCommand(tool: "/bin/echo", arguments: ["-n", nasty]).run())
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, nasty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testInputGoesToStdinAsIs() throws {
        let text = "fix the build; then `ls` $HOME \\n"
        let result = try XCTUnwrap(HostCommand(tool: "/bin/cat", arguments: [], input: text).run())
        XCTAssertEqual(result.output, text)
    }

    func testEnvironmentIsAddedForTheRunOnly() throws {
        let result = try XCTUnwrap(HostCommand(tool: "/usr/bin/env", arguments: [],
                                               environment: ["PILLR_TEST_SOCKET": "/tmp/x"]).run())
        XCTAssertTrue(result.output.contains("PILLR_TEST_SOCKET=/tmp/x"))
        XCTAssertNil(ProcessInfo.processInfo.environment["PILLR_TEST_SOCKET"])
    }

    func testATimedOutToolIsEndedAndAnswersNil() {
        let start = Date()
        XCTAssertNil(HostCommand(tool: "/bin/sleep", arguments: ["5"], timeout: 0.3).run())
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testAFailingToolReportsItsStatus() {
        XCTAssertEqual(HostCommand(tool: "/usr/bin/false", arguments: []).run()?.status, 1)
        XCTAssertNil(HostCommand(tool: "/nonexistent/tool", arguments: []).run())
    }

    func testOnlySafeExecutablesAreTrusted() throws {
        XCTAssertTrue(HostTools.isSafeExecutable("/bin/ls"))
        XCTAssertFalse(HostTools.isSafeExecutable("ls"), "a relative path is never run")
        XCTAssertFalse(HostTools.isSafeExecutable("/nonexistent/tmux"))
        XCTAssertFalse(HostTools.isSafeExecutable("/bin"), "a folder is not a tool")
        let path = NSTemporaryDirectory() + "pillr-tool-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        chmod(path, 0o755)
        XCTAssertTrue(HostTools.isSafeExecutable(path))
        chmod(path, 0o777)
        XCTAssertFalse(HostTools.isSafeExecutable(path), "anyone could rewrite it")
        chmod(path, 0o644)
        XCTAssertFalse(HostTools.isSafeExecutable(path), "not executable")
    }

    func testToolsResolvePreferredPathsFirstThenTheUsualPlaces() {
        XCTAssertEqual(HostTools.resolve("tmux", preferring: ["/srv/tmux"], isSafe: { $0 == "/srv/tmux" }), "/srv/tmux")
        XCTAssertEqual(HostTools.resolve("tmux", preferring: ["/gone/tmux"], isSafe: { $0 == "/usr/local/bin/tmux" }),
                       "/usr/local/bin/tmux")
        XCTAssertEqual(HostTools.resolve("tmux", isSafe: { $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/usr/local/") }),
                       "/opt/homebrew/bin/tmux", "Homebrew on Apple silicon before Intel's")
        XCTAssertNil(HostTools.resolve("tmux", isSafe: { _ in false }))
    }

    func testInheritedVariablesComeFromTheNearestProcessThatHasThem() {
        var tree = FakeTree()
        tree.parents = [500: 400, 400: 300]
        tree.env = [500: ["PATH=/bin"], 400: ["TMUX_PANE=%3", "TMUX="], 300: ["TMUX_PANE=%9"]]
        let facts = tree.facts
        XCTAssertEqual(facts.inherited("TMUX_PANE", from: 500)?.value, "%3")
        XCTAssertEqual(facts.inherited("TMUX_PANE", from: 500)?.pid, 400)
        XCTAssertNil(facts.inherited("TMUX", from: 500), "an empty value is no value")
    }
}

// MARK: - tmux

final class TmuxTests: XCTestCase {
    static let socket = "/private/tmp/tmux-501/default"

    /// claude 500 ← zsh 400 ← tmux server 300 (daemonized, under launchd).
    private func tree(env: [String]? = nil) -> FakeTree {
        var tree = FakeTree()
        tree.parents = [500: 400, 400: 300, 300: 1]
        tree.env = [400: env ?? ["TMUX=\(Self.socket),300,0", "TMUX_PANE=%3"], 500: ["TERM=tmux-256color"]]
        tree.paths = [500: "/Users/x/.local/bin/claude", 400: "/bin/zsh", 300: "/opt/homebrew/Cellar/tmux/3.5a/bin/tmux"]
        tree.ttys = [500: "ttys004", 400: "ttys004"]
        return tree
    }

    private var pane: TmuxPane {
        TmuxPane(tool: "/opt/homebrew/bin/tmux", socket: Self.socket, paneID: "%3", tty: "ttys004",
                 ancestry: [500, 400, 300])
    }

    static let panes = """
    %0 /dev/ttys001 1200 @0 0 main
    %3 /dev/ttys004 400 @1 0 work stuff
    %5 /dev/ttys006 1400 @2 1 other
    """

    func testFindsThePaneFromTheVariablesTmuxExports() throws {
        let found = try XCTUnwrap(Tmux.locate(pid: 500, facts: tree().facts, isSafe: anyTool))
        XCTAssertEqual(found.socket, Self.socket)
        XCTAssertEqual(found.paneID, "%3")
        XCTAssertEqual(found.tty, "ttys004")
        XCTAssertEqual(found.tool, "/opt/homebrew/Cellar/tmux/3.5a/bin/tmux", "the running server's own binary")
    }

    func testAnInheritedTMUXWithoutItsServerUpTheTreeIsNotTmux() {
        // kitty started from a tmux shell: its panes inherit $TMUX, but the
        // agent runs in kitty, not in tmux.
        var tree = tree()
        tree.parents = [500: 400, 400: 350, 350: 1]
        tree.paths[350] = "/Applications/kitty.app/Contents/MacOS/kitty"
        XCTAssertNil(Tmux.locate(pid: 500, facts: tree.facts, isSafe: anyTool))
    }

    func testAScrubbedEnvironmentStillFindsTheServerByItsBinary() throws {
        let found = try XCTUnwrap(Tmux.locate(pid: 500, facts: tree(env: []).facts, isSafe: anyTool))
        XCTAssertNil(found.socket, "the default socket")
        XCTAssertNil(found.paneID, "found later by tty")
    }

    func testNoTmuxNoPane() {
        var tree = FakeTree()
        tree.parents = [500: 400, 400: 1]
        tree.paths = [400: "/bin/zsh"]
        XCTAssertNil(Tmux.locate(pid: 500, facts: tree.facts, isSafe: anyTool))
        XCTAssertNil(Tmux.locate(pid: 500, facts: self.tree().facts, isSafe: { _ in false }), "no tool, no reach")
    }

    func testTheTMUXVariableIsSplitFromTheEnd() {
        XCTAssertEqual(Tmux.parseTMUX("/tmp/a,b/default,4242,1")?.socket, "/tmp/a,b/default")
        XCTAssertEqual(Tmux.parseTMUX("/tmp/a,b/default,4242,1")?.serverPID, 4242)
        XCTAssertNil(Tmux.parseTMUX("garbage"))
        XCTAssertNil(Tmux.parseTMUX("relative,12,0"))
    }

    func testPanesAreParsedAndMatched() throws {
        let rows = Tmux.parsePanes(Self.panes + "\nnot a pane line\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], Tmux.Pane(id: "%3", tty: "ttys004", pid: 400, windowID: "@1", inMode: false, session: "work stuff"))
        XCTAssertTrue(rows[2].inMode)
        XCTAssertEqual(Tmux.match(rows, pane: pane)?.id, "%3")
        // $TMUX_PANE says %0 but its tty is not the agent's: the tty wins.
        let stale = TmuxPane(tool: "t", socket: nil, paneID: "%0", tty: "ttys004", ancestry: [500])
        XCTAssertEqual(Tmux.match(rows, pane: stale)?.id, "%3")
        // Nothing but a parent's pid to go by.
        let byPID = TmuxPane(tool: "t", socket: nil, paneID: nil, tty: nil, ancestry: [9000, 1400])
        XCTAssertEqual(Tmux.match(rows, pane: byPID)?.id, "%5")
        let lost = TmuxPane(tool: "t", socket: nil, paneID: "%8", tty: "ttys099", ancestry: [9000])
        XCTAssertNil(Tmux.match(rows, pane: lost))
    }

    func testTextIsTypedLiterallyAfterADoubleDash() {
        let commands = Tmux.type("-v means verbose", pane: pane, target: "%3")
        XCTAssertEqual(commands.map(\.arguments),
                       [["-S", Self.socket, "send-keys", "-t", "%3", "-l", "--", "-v means verbose"]])
        XCTAssertEqual(commands.first?.tool, "/opt/homebrew/bin/tmux")
    }

    /// tmux takes an argument ending in `;` as the end of a command.
    func testTrailingSemicolonsAreSentAsBytes() {
        let commands = Tmux.type("run it;;", pane: pane, target: "%3")
        XCTAssertEqual(commands.map(\.arguments), [
            ["-S", Self.socket, "send-keys", "-t", "%3", "-l", "--", "run it"],
            ["-S", Self.socket, "send-keys", "-t", "%3", "-H", "3b", "3b"],
        ])
        XCTAssertEqual(Tmux.type(";", pane: pane, target: "%3").map(\.arguments),
                       [["-S", Self.socket, "send-keys", "-t", "%3", "-H", "3b"]])
        XCTAssertEqual(Tmux.type(#"a\;"#, pane: pane, target: "%3").first?.arguments.last, #"a\"#)
    }

    func testKeys() {
        XCTAssertEqual(Tmux.key(.enter, pane: pane, target: "%3").arguments.suffix(1), ["Enter"])
        XCTAssertEqual(Tmux.key(.escape, pane: pane, target: "%3").arguments.suffix(1), ["Escape"])
        XCTAssertEqual(Tmux.key(.control("\u{13}"), pane: pane, target: "%3").arguments.suffix(2), ["-H", "13"])
        let noSocket = TmuxPane(tool: "/t", socket: nil, paneID: nil, tty: nil, ancestry: [])
        XCTAssertEqual(Tmux.capture(noSocket, target: "%1").arguments, ["capture-pane", "-p", "-t", "%1"])
    }

    private func runner(screen: String, list: String = TmuxTests.panes) -> FakeRunner {
        FakeRunner { command in
            switch command.arguments.dropFirst(2).first {
            case "list-panes": return FakeRunner.ok(list)
            case "capture-pane": return FakeRunner.ok(screen)
            case "send-keys": return FakeRunner.ok()
            default: return FakeRunner.failed
            }
        }
    }

    func testAnIdlePromptGetsTheLineThenReturn() {
        let fake = runner(screen: idleScreen)
        XCTAssertEqual(Tmux.write("ship it", stashKey: nil, pane: pane, run: fake.run, pause: noPause), .sent)
        XCTAssertEqual(fake.arguments.map { Array($0.dropFirst(2)) }, [
            ["list-panes", "-a", "-F", Tmux.paneFormat],
            ["capture-pane", "-p", "-t", "%3"],
            ["send-keys", "-t", "%3", "-l", "--", "ship it"],
            ["send-keys", "-t", "%3", "Enter"],
        ])
    }

    func testABusyPaneIsNotTypedInto() {
        let fake = runner(screen: busyScreen)
        XCTAssertEqual(Tmux.write("ship it", stashKey: "\u{13}", pane: pane, run: fake.run, pause: noPause), .busy)
        XCTAssertFalse(fake.arguments.contains { $0.contains("send-keys") })
    }

    func testADraftIsStashedFirstOnlyWhereTheAgentCanStashIt() {
        let claude = runner(screen: draftScreen)
        XCTAssertEqual(Tmux.write("ship it", stashKey: "\u{13}", pane: pane, run: claude.run, pause: noPause), .sent)
        let sends = claude.arguments.filter { $0.contains("send-keys") }.map { Array($0.suffix(2)) }
        XCTAssertEqual(sends, [["-H", "13"], ["--", "ship it"], ["%3", "Enter"]])

        let codex = runner(screen: draftScreen)
        XCTAssertEqual(Tmux.write("ship it", stashKey: nil, pane: pane, run: codex.run, pause: noPause), .busy)
        XCTAssertFalse(codex.arguments.contains { $0.contains("send-keys") })
    }

    func testAPaneInCopyModeIsBusy() {
        let inMode = "%3 /dev/ttys004 400 @1 1 work"
        let fake = runner(screen: idleScreen, list: inMode)
        XCTAssertEqual(Tmux.write("ship it", stashKey: nil, pane: pane, run: fake.run, pause: noPause), .busy)
    }

    func testAGoneServerOrPaneIsSaidSo() {
        let gone = FakeRunner { _ in FakeRunner.failed }
        XCTAssertEqual(Tmux.write("x", stashKey: nil, pane: pane, run: gone.run, pause: noPause), .unreadable)
        let other = runner(screen: idleScreen, list: "%0 /dev/ttys001 1200 @0 0 main")
        XCTAssertEqual(Tmux.write("x", stashKey: nil, pane: pane, run: other.run, pause: noPause), .notFound)
        let unreadable = FakeRunner { $0.arguments.contains("list-panes") ? FakeRunner.ok(TmuxTests.panes) : FakeRunner.failed }
        XCTAssertEqual(Tmux.write("x", stashKey: nil, pane: pane, run: unreadable.run, pause: noPause), .unreadable)
    }

    func testAFailedReturnIsARefusal() {
        let fake = FakeRunner { command in
            if command.arguments.contains("list-panes") { return FakeRunner.ok(TmuxTests.panes) }
            if command.arguments.contains("capture-pane") { return FakeRunner.ok(idleScreen) }
            return command.arguments.last == "Enter" ? FakeRunner.failed : FakeRunner.ok()
        }
        XCTAssertEqual(Tmux.write("x", stashKey: nil, pane: pane, run: fake.run, pause: noPause), .refused)
    }

    func testStopIsEscInThePane() {
        let fake = runner(screen: busyScreen)
        XCTAssertTrue(Tmux.press(.escape, pane: pane, run: fake.run))
        XCTAssertEqual(fake.arguments.last.map { Array($0.dropFirst(2)) }, ["send-keys", "-t", "%3", "Escape"])
    }

    func testClientsAreParsedAndTheOneOnTheSessionIsChosen() {
        let clients = Tmux.parseClients("""
        7001 /dev/ttys010 1700000000 main
        7002 /dev/ttys011 1700000500 work stuff
        7003 /dev/ttys012 1700000900 main
        """)
        XCTAssertEqual(clients.count, 3)
        XCTAssertEqual(Tmux.client(for: "work stuff", among: clients)?.client.pid, 7002)
        XCTAssertEqual(Tmux.client(for: "work stuff", among: clients)?.switchTo, false)
        let elsewhere = Tmux.client(for: "detached", among: clients)
        XCTAssertEqual(elsewhere?.client.pid, 7003, "the most recently used client")
        XCTAssertEqual(elsewhere?.switchTo, true)
        XCTAssertNil(Tmux.client(for: "x", among: []))
    }

    func testFocusSelectsThePaneAndNamesTheClientsTerminal() {
        let fake = FakeRunner { command in
            switch command.arguments.dropFirst(2).first {
            case "list-panes": return FakeRunner.ok(TmuxTests.panes)
            case "list-clients": return FakeRunner.ok("7009 /dev/ttys020 1700000000 main\n")
            default: return FakeRunner.ok()
            }
        }
        let focus = Tmux.focus(pane, run: fake.run)
        XCTAssertEqual(focus, PaneFocus(selected: true, clientPID: 7009, clientTTY: "ttys020"))
        XCTAssertEqual(fake.arguments.map { Array($0.dropFirst(2)) }, [
            ["list-panes", "-a", "-F", Tmux.paneFormat],
            ["select-window", "-t", "%3"],
            ["select-pane", "-t", "%3"],
            ["list-clients", "-F", Tmux.clientFormat],
            ["switch-client", "-c", "/dev/ttys020", "-t", "%3"],
        ])
    }
}

// MARK: - Zellij

final class ZellijTests: XCTestCase {
    private var pane: ZellijPane {
        ZellijPane(tool: "/opt/homebrew/bin/zellij", session: "quiet-otter", paneID: "3", socketDir: nil)
    }

    func testFindsThePaneFromZellijsVariables() throws {
        var tree = FakeTree()
        tree.parents = [500: 400, 400: 300, 300: 1]
        tree.env = [400: ["ZELLIJ=0", "ZELLIJ_SESSION_NAME=quiet-otter", "ZELLIJ_PANE_ID=3"]]
        tree.paths = [300: "/opt/homebrew/Cellar/zellij/0.44.3/bin/zellij"]
        let found = try XCTUnwrap(Zellij.locate(pid: 500, facts: tree.facts, isSafe: anyTool))
        XCTAssertEqual(found, ZellijPane(tool: "/opt/homebrew/Cellar/zellij/0.44.3/bin/zellij",
                                         session: "quiet-otter", paneID: "3", socketDir: nil))
        // The variables alone, with no Zellij server up the tree, are not enough.
        tree.paths = [:]
        XCTAssertNil(Zellij.locate(pid: 500, facts: tree.facts, isSafe: anyTool))
    }

    func testEveryActionNamesTheSessionAndThePane() {
        XCTAssertEqual(Zellij.dump(pane).arguments,
                       ["--session=quiet-otter", "action", "dump-screen", "--pane-id", "3"])
        XCTAssertEqual(Zellij.type("-rf everything", pane: pane).arguments,
                       ["--session=quiet-otter", "action", "write-chars", "--pane-id", "3", "--", "-rf everything"])
        XCTAssertEqual(Zellij.key(.enter, pane: pane).arguments.suffix(3), ["--pane-id", "3", "13"])
        XCTAssertEqual(Zellij.key(.escape, pane: pane).arguments.last, "27")
        XCTAssertEqual(Zellij.key(.control("\u{13}"), pane: pane).arguments.last, "19")
        let custom = ZellijPane(tool: "/z", session: "s", paneID: "terminal_2", socketDir: "/tmp/zs")
        XCTAssertEqual(Zellij.dump(custom).environment, ["ZELLIJ_SOCKET_DIR": "/tmp/zs"])
        XCTAssertTrue(Zellij.isPaneID("terminal_2"))
        XCTAssertFalse(Zellij.isPaneID("plugin_1"), "a plugin pane runs no agent")
    }

    func testWritesOnlyAtAnIdlePrompt() {
        let fake = FakeRunner { $0.arguments.contains("dump-screen") ? FakeRunner.ok(idleScreen) : FakeRunner.ok() }
        XCTAssertEqual(Zellij.write("go on", stashKey: nil, pane: pane, run: fake.run, pause: noPause), .sent)
        XCTAssertEqual(fake.arguments.map { Array($0.dropFirst(2)) }, [
            ["dump-screen", "--pane-id", "3"],
            ["write-chars", "--pane-id", "3", "--", "go on"],
            ["write", "--pane-id", "3", "13"],
        ])
        let busy = FakeRunner { $0.arguments.contains("dump-screen") ? FakeRunner.ok(busyScreen) : FakeRunner.ok() }
        XCTAssertEqual(Zellij.write("go on", stashKey: nil, pane: pane, run: busy.run, pause: noPause), .busy)
        // Before 0.44 `--pane-id` is unknown: the read is refused, nothing typed.
        let old = FakeRunner { _ in FakeRunner.failed }
        XCTAssertEqual(Zellij.write("go on", stashKey: nil, pane: pane, run: old.run, pause: noPause), .unreadable)
        XCTAssertEqual(old.commands.count, 1)
    }

    func testTheClientIsTheZellijProcessWithATerminal() {
        let table = ProcessTable(psOutput: """
          300     1 ??       /opt/homebrew/bin/zellij
          810   800 ttys002  zellij
          820   815 ttys003  /opt/homebrew/bin/zellij
        """)
        var tree = FakeTree()
        tree.env = [810: ["zellij", "attach", "other"], 820: ["/opt/homebrew/bin/zellij", "--session=quiet-otter"]]
        XCTAssertEqual(Zellij.client(of: "quiet-otter", in: table, facts: tree.facts)?.pid, 820)
        XCTAssertNil(Zellij.client(of: "nobody", in: table, facts: tree.facts), "several, none named: no guess")
        let one = ProcessTable(psOutput: "  300 1 ?? zellij\n  810 800 ttys002 zellij")
        XCTAssertEqual(Zellij.client(of: "any", in: one, facts: tree.facts)?.tty, "ttys002")
    }
}

// MARK: - kitty

final class KittyTests: XCTestCase {
    private var window: KittyWindow {
        KittyWindow(tool: "/Applications/kitty.app/Contents/MacOS/kitten", socket: "unix:/tmp/kitty-4242",
                    windowID: 7, ancestry: [500, 400, 4242])
    }

    static let ls = """
    [{"id": 1, "is_focused": true, "tabs": [
      {"id": 1, "title": "zsh", "windows": [
        {"id": 1, "pid": 3100, "cwd": "/Users/x", "foreground_processes": [{"pid": 3100, "cmdline": ["-zsh"]}]},
        {"id": 7, "pid": 400, "cwd": "/Users/x/app", "foreground_processes": [{"pid": 500, "cmdline": ["claude"]}]}
      ]},
      {"id": 2, "title": "logs", "windows": [
        {"id": 9, "pid": 3300, "foreground_processes": [{"pid": 3333, "cmdline": ["tail"]}]}
      ]}
    ]}]
    """

    func testFindsTheWindowWhenRemoteControlListens() throws {
        var tree = FakeTree()
        tree.parents = [500: 400, 400: 4242]
        tree.env = [400: ["KITTY_WINDOW_ID=7", "KITTY_LISTEN_ON=unix:/tmp/kitty-4242", "KITTY_PID=4242"]]
        let bundle = URL(fileURLWithPath: "/Applications/kitty.app")
        let found = try XCTUnwrap(Kitty.locate(pid: 500, bundleURL: bundle, facts: tree.facts, isSafe: anyTool))
        XCTAssertEqual(found.tool, "/Applications/kitty.app/Contents/MacOS/kitten")
        XCTAssertEqual(found.socket, "unix:/tmp/kitty-4242")
        XCTAssertEqual(found.windowID, 7)
        // No socket to talk to: remote control is off, and kitty is pasted into.
        tree.env = [400: ["KITTY_WINDOW_ID=7"]]
        XCTAssertNil(Kitty.locate(pid: 500, bundleURL: bundle, facts: tree.facts, isSafe: anyTool))
    }

    func testTheWindowIsFoundInLsByItsProcesses() {
        XCTAssertEqual(Kitty.windowID(inList: Self.ls, ancestry: [500, 400]), 7)
        XCTAssertEqual(Kitty.windowID(inList: Self.ls, ancestry: [500]), 7, "the agent in the foreground")
        XCTAssertNil(Kitty.windowID(inList: Self.ls, ancestry: [8000, 7000]))
        XCTAssertNil(Kitty.windowID(inList: "not json", ancestry: [500]))
    }

    func testTextGoesThroughStdinSoKittyReadsNoEscapes() {
        let send = Kitty.sendText(#"say \e[31m hi"#, window: window, id: 7)
        XCTAssertEqual(send.arguments, ["@", "--to", "unix:/tmp/kitty-4242", "send-text", "--match", "id:7", "--stdin"])
        XCTAssertEqual(send.input, #"say \e[31m hi"#)
        XCTAssertEqual(Kitty.key(.enter, window: window, id: 7).input, "\r")
        XCTAssertEqual(Kitty.key(.escape, window: window, id: 7).input, "\u{1b}")
        XCTAssertEqual(Kitty.getText(window, id: 7).arguments.suffix(4), ["--match", "id:7", "--extent", "screen"])
        XCTAssertEqual(Kitty.focusWindow(window, id: 7).arguments.suffix(3), ["focus-window", "--match", "id:7"])
    }

    func testWriteReadsThenTypesThenReturns() {
        let fake = FakeRunner { $0.arguments.contains("get-text") ? FakeRunner.ok(idleScreen) : FakeRunner.ok() }
        XCTAssertEqual(Kitty.write("next", stashKey: nil, window: window, run: fake.run, pause: noPause), .sent)
        XCTAssertEqual(fake.commands.map { $0.arguments[3] }, ["get-text", "send-text", "send-text"])
        XCTAssertEqual(fake.commands.map(\.input), [nil, "next", "\r"])
    }

    func testWithoutAWindowIdLsFindsIt() {
        let unnamed = KittyWindow(tool: "/k", socket: "unix:/tmp/k", windowID: nil, ancestry: [500, 400])
        let fake = FakeRunner { command in
            switch command.arguments[3] {
            case "ls": return FakeRunner.ok(KittyTests.ls)
            case "get-text": return FakeRunner.ok(idleScreen)
            default: return FakeRunner.ok()
            }
        }
        XCTAssertTrue(Kitty.focus(unnamed, run: fake.run))
        XCTAssertEqual(fake.arguments.last, ["@", "--to", "unix:/tmp/k", "focus-window", "--match", "id:7"])
        let refused = FakeRunner { _ in FakeRunner.failed }
        XCTAssertEqual(Kitty.write("x", stashKey: nil, window: unnamed, run: refused.run, pause: noPause), .notFound)
        XCTAssertEqual(Kitty.write("x", stashKey: nil, window: window, run: refused.run, pause: noPause), .unreadable)
    }
}

// MARK: - WezTerm

final class WezTermTests: XCTestCase {
    private var pane: WezTermPane {
        WezTermPane(tool: "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                    socket: "/Users/x/.local/share/wezterm/gui-sock-900", paneID: 4, tty: "ttys007")
    }

    static let list = """
    [
      {"window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default", "size": {"rows": 24, "cols": 80},
       "title": "zsh", "cwd": "file://mac/Users/x/", "tty_name": "/dev/ttys005"},
      {"window_id": 0, "tab_id": 2, "pane_id": 4, "workspace": "default", "size": {"rows": 40, "cols": 120},
       "title": "claude", "cwd": "file://mac/Users/x/app/", "tty_name": "/dev/ttys007"},
      {"window_id": 1, "tab_id": 3, "pane_id": 6, "workspace": "default", "title": "old wezterm, no tty"}
    ]
    """

    func testFindsThePaneFromWezTermsVariables() throws {
        var tree = FakeTree()
        tree.parents = [500: 400, 400: 900]
        tree.env = [400: ["WEZTERM_PANE=4", "WEZTERM_UNIX_SOCKET=/Users/x/.local/share/wezterm/gui-sock-900"]]
        tree.ttys = [500: "ttys007"]
        let bundle = URL(fileURLWithPath: "/Applications/WezTerm.app")
        let found = try XCTUnwrap(WezTerm.locate(pid: 500, bundleURL: bundle, facts: tree.facts, isSafe: anyTool))
        XCTAssertEqual(found, pane)
    }

    func testTheListIsParsedAndMatchedByPaneThenTty() {
        let rows = WezTerm.parseList(Self.list)
        XCTAssertEqual(rows, [WezTerm.Pane(paneID: 0, tabID: 0, tty: "ttys005"),
                              WezTerm.Pane(paneID: 4, tabID: 2, tty: "ttys007"),
                              WezTerm.Pane(paneID: 6, tabID: 3, tty: nil)])
        XCTAssertEqual(WezTerm.match(rows, pane: pane)?.paneID, 4)
        let stale = WezTermPane(tool: "/w", socket: nil, paneID: 0, tty: "ttys007")
        XCTAssertEqual(WezTerm.match(rows, pane: stale)?.paneID, 4, "the pane's tty is not the agent's")
        let noTTYKnown = WezTermPane(tool: "/w", socket: nil, paneID: 6, tty: "ttys009")
        XCTAssertEqual(WezTerm.match(rows, pane: noTTYKnown)?.paneID, 6)
        XCTAssertNil(WezTerm.match(rows, pane: WezTermPane(tool: "/w", socket: nil, paneID: nil, tty: "ttys099")))
    }

    func testCommandsTalkToThatInstanceAndNeverStartOne() {
        let send = WezTerm.sendText("--help me", pane: pane, id: 4)
        XCTAssertEqual(send.arguments, ["cli", "--no-auto-start", "send-text", "--pane-id", "4", "--no-paste"])
        XCTAssertEqual(send.input, "--help me", "from stdin, never read as an option")
        XCTAssertEqual(send.environment, ["WEZTERM_UNIX_SOCKET": "/Users/x/.local/share/wezterm/gui-sock-900"])
        XCTAssertEqual(WezTerm.getText(pane, id: 4).arguments, ["cli", "--no-auto-start", "get-text", "--pane-id", "4"])
        XCTAssertEqual(WezTerm.key(.enter, pane: pane, id: 4).input, "\r")
    }

    func testFocusActivatesTheTabThenThePane() {
        let fake = FakeRunner { $0.arguments.contains("list") ? FakeRunner.ok(WezTermTests.list) : FakeRunner.ok() }
        XCTAssertTrue(WezTerm.focus(pane, run: fake.run))
        XCTAssertEqual(fake.arguments.dropFirst().map { Array($0.dropFirst(2)) }, [
            ["activate-tab", "--tab-id", "2"],
            ["activate-pane", "--pane-id", "4"],
        ])
    }

    func testWriteAtAnIdlePromptAndNotOverADraft() {
        func runner(_ screen: String) -> FakeRunner {
            FakeRunner { command in
                if command.arguments.contains("list") { return FakeRunner.ok(WezTermTests.list) }
                if command.arguments.contains("get-text") { return FakeRunner.ok(screen) }
                return FakeRunner.ok()
            }
        }
        let idle = runner(idleScreen)
        XCTAssertEqual(WezTerm.write("go", stashKey: nil, pane: pane, run: idle.run, pause: noPause), .sent)
        XCTAssertEqual(idle.commands.compactMap(\.input), ["go", "\r"])
        let draft = runner(draftScreen)
        XCTAssertEqual(WezTerm.write("go", stashKey: nil, pane: pane, run: draft.run, pause: noPause), .busy)
        let stashed = runner(draftScreen)
        XCTAssertEqual(WezTerm.write("go", stashKey: "\u{13}", pane: pane, run: stashed.run, pause: noPause), .sent)
        XCTAssertEqual(stashed.commands.compactMap(\.input), ["\u{13}", "go", "\r"])
        let gone = FakeRunner { _ in FakeRunner.failed }
        XCTAssertEqual(WezTerm.write("go", stashKey: nil, pane: pane, run: gone.run, pause: noPause), .notFound)
    }
}

// MARK: - Choosing the way in

@MainActor
final class PaneReachTests: XCTestCase {
    /// claude 500 ← zsh 400 ← kitty 4242, with tmux's variables or not.
    private func kittyTree(inTmux: Bool) -> FakeTree {
        var tree = FakeTree()
        if inTmux {
            tree.parents = [500: 400, 400: 300, 300: 1]
            tree.env = [400: ["TMUX=/tmp/tmux-501/default,300,0", "TMUX_PANE=%1",
                              "KITTY_WINDOW_ID=2", "KITTY_LISTEN_ON=unix:/tmp/k-4242"]]
            tree.paths = [300: "/opt/homebrew/bin/tmux"]
        } else {
            tree.parents = [500: 400, 400: 4242, 4242: 1]
            tree.env = [400: ["KITTY_WINDOW_ID=2", "KITTY_LISTEN_ON=unix:/tmp/k-4242"]]
        }
        tree.ttys = [500: "ttys003"]
        return tree
    }

    func testAMultiplexerWinsOverTheTerminalAroundIt() {
        let kitty = URL(fileURLWithPath: "/Applications/kitty.app")
        let inTmux = PaneHosts.locate(pid: 500, bundleID: PaneHosts.kittyBundleID, bundleURL: kitty,
                                      facts: kittyTree(inTmux: true).facts, isSafe: anyTool)
        guard case .tmux(let pane) = inTmux else { return XCTFail("\(String(describing: inTmux))") }
        XCTAssertEqual(pane.paneID, "%1")
        XCTAssertTrue(inTmux?.isMultiplexer == true)

        let bare = PaneHosts.locate(pid: 500, bundleID: PaneHosts.kittyBundleID, bundleURL: kitty,
                                    facts: kittyTree(inTmux: false).facts, isSafe: anyTool)
        guard case .kitty(let window) = bare else { return XCTFail("\(String(describing: bare))") }
        XCTAssertEqual(window.windowID, 2)
        XCTAssertEqual(bare?.isMultiplexer, false)
    }

    func testTerminalsWithoutARemoteAreNotPanes() {
        let facts = kittyTree(inTmux: false).facts
        XCTAssertNil(PaneHosts.locate(pid: 500, bundleID: "com.apple.Terminal", bundleURL: nil, facts: facts, isSafe: anyTool))
        XCTAssertNil(PaneHosts.locate(pid: 500, bundleID: "com.mitchellh.ghostty", bundleURL: nil, facts: facts, isSafe: anyTool))
        XCTAssertNil(PaneHosts.locate(pid: 500, bundleID: nil, bundleURL: nil, facts: FakeTree().facts, isSafe: anyTool))
    }

    func testReachIsChosenInOrder() {
        let tmux = PaneHost.tmux(TmuxPane(tool: "/t", socket: nil, paneID: "%1", tty: "ttys003", ancestry: []))
        typealias C = SessionCommander
        XCTAssertEqual(C.chooseReach(supersetV2: true, pane: tmux, bundleID: "com.apple.Terminal", appName: "Terminal",
                                     tty: "ttys003", claudeHost: nil), .superset)
        XCTAssertEqual(C.chooseReach(supersetV2: false, pane: tmux, bundleID: "com.apple.Terminal", appName: "Terminal",
                                     tty: "ttys003", claudeHost: nil), .pane(tmux),
                       "in tmux, Terminal's tab is tmux's client, not the agent")
        XCTAssertEqual(C.chooseReach(supersetV2: false, pane: nil, bundleID: "com.apple.Terminal", appName: "Terminal",
                                     tty: "ttys003", claudeHost: nil), .terminal(tty: "ttys003"))
        XCTAssertEqual(C.chooseReach(supersetV2: false, pane: nil, bundleID: "com.googlecode.iterm2", appName: "iTerm2",
                                     tty: "ttys003", claudeHost: nil), .iterm(tty: "ttys003"))
        XCTAssertEqual(C.chooseReach(supersetV2: false, pane: nil, bundleID: ClaudeDesktopComposer.bundleID,
                                     appName: "Claude", tty: nil, claudeHost: "local_1"), .claudeApp(hostSessionID: "local_1"))
        XCTAssertEqual(C.chooseReach(supersetV2: false, pane: nil, bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
                                     tty: "ttys003", claudeHost: nil), .pasteInto(app: "Ghostty"))
        XCTAssertEqual(C.chooseReach(supersetV2: false, pane: nil, bundleID: nil, appName: nil, tty: nil, claudeHost: nil),
                       .none, "a tmux session with no tmux tool, under launchd")
    }

    func testOutcomesSayWhichHostAndWhy() {
        let zellij = PaneHost.zellij(ZellijPane(tool: "/z", session: "s", paneID: "1", socketDir: nil))
        let tmux = PaneHost.tmux(TmuxPane(tool: "/t", socket: nil, paneID: nil, tty: nil, ancestry: []))
        XCTAssertEqual(SessionCommander.outcome(.sent, host: tmux), .sent)
        XCTAssertEqual(SessionCommander.outcome(.busy, host: tmux), .busy)
        XCTAssertEqual(SessionCommander.outcome(.notFound, host: tmux), .failed(L10n.t("Its \("tmux") pane wasn't found")))
        XCTAssertEqual(SessionCommander.outcome(.refused, host: tmux), .failed(L10n.t("\("tmux") refused the message")))
        XCTAssertEqual(SessionCommander.outcome(.unreadable, host: zellij),
                       .failed(L10n.t("Zellij refused the message. Replies need Zellij 0.44 or newer")))
    }

    func testThePaneStringsAreTranslated() {
        for code in ["fr", "ja", "pt-BR", "ru", "zh-Hans"] {
            let locale = Locale(identifier: code)
            let host = "tmux"
            XCTAssertNotEqual(L10n.t("Its \(host) pane wasn't found", locale: locale), "Its tmux pane wasn't found", code)
            XCTAssertTrue(L10n.t("Its \(host) pane wasn't found", locale: locale).contains("tmux"), code)
            XCTAssertNotEqual(L10n.t("\(host) wouldn't let pillr read the pane", locale: locale),
                              "tmux wouldn't let pillr read the pane", code)
        }
    }
}

// MARK: - Windows and tabs without a remote

final class WindowFocusTests: XCTestCase {
    func testOnlyAWindowThatAloneNamesTheSessionIsChosen() {
        let titles: [String?] = ["main.swift — pillr", "README.md — legalos", nil, "Welcome"]
        XCTAssertEqual(WindowFocus.choose(titles: titles, hints: ["pillr"]), 0)
        XCTAssertEqual(WindowFocus.choose(titles: titles, hints: ["LegalOS"]), 1)
        XCTAssertNil(WindowFocus.choose(titles: titles, hints: ["l"]), "too short to mean anything")
        XCTAssertEqual(WindowFocus.choose(titles: titles, hints: ["readme"]), 1)
        XCTAssertNil(WindowFocus.choose(titles: ["a — app", "b — app"], hints: ["app"]), "two could be meant")
        XCTAssertNil(WindowFocus.choose(titles: titles, hints: []))
    }

    func testFolderHintsNameTheFolderAndItsRepository() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pillr-repo-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(WindowFocus.folderHints(cwd: sub.path), ["App", root.lastPathComponent])
        XCTAssertEqual(WindowFocus.folderHints(cwd: root.path), [root.lastPathComponent])
        XCTAssertEqual(WindowFocus.folderHints(cwd: "/"), [])
        XCTAssertEqual(WindowFocus.folderHints(cwd: nil), [])
    }

    func testAnEditorIsPastedIntoOnlyWhileItsTerminalHasTheKeyboard() {
        let window = PasteTarget.Window(count: 1, hasTabs: false, title: "app")
        XCTAssertFalse(PasteTarget.isSure(tabSelected: true, window: window, hints: ["app"], terminalFocused: false))
        XCTAssertTrue(PasteTarget.isSure(tabSelected: false, window: window, hints: ["app"], terminalFocused: true))
        XCTAssertTrue(PasteTarget.isSure(tabSelected: false, window: window, hints: ["app"]), "a terminal is not asked")
        XCTAssertTrue(PasteTarget.isEditor("com.microsoft.VSCode"))
        XCTAssertTrue(PasteTarget.isEditor("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(PasteTarget.isEditor("com.jetbrains.intellij"))
        XCTAssertTrue(PasteTarget.isEditor("dev.zed.Zed"))
        XCTAssertFalse(PasteTarget.isEditor("com.mitchellh.ghostty"))
        XCTAssertFalse(PasteTarget.isEditor(nil))
        XCTAssertTrue(PasteTarget.describesTerminal(["Terminal 1, zsh"]))
        XCTAssertTrue(PasteTarget.describesTerminal(["xterm-helper-textarea"]))
        XCTAssertFalse(PasteTarget.describesTerminal(["main.swift", "editor content"]))
    }

    func testGhosttyIsAskedByTtyThenByAFolderNoOtherTerminalShares() {
        let script = TerminalTabFocus.ghosttyScript(tty: "ttys004", cwdCandidates: ["/Users/x/a \"b\"", "/private/Users/x/a"])
        XCTAssertTrue(script.contains(#"theTTY is "/dev/ttys004" or theTTY is "ttys004""#), script)
        XCTAssertTrue(script.contains(#"{"/Users/x/a \"b\"", "/private/Users/x/a"}"#), "quotes escaped")
        XCTAssertTrue(script.contains(#"if (count of cwdHits) is not 1 then return "ambiguous""#))
        XCTAssertFalse(TerminalTabFocus.ghosttyScript(tty: nil, cwdCandidates: ["/a"]).contains("tty of term"))
        XCTAssertTrue(TerminalTabFocus.selectableBundleIDs.contains("com.mitchellh.ghostty"))
        XCTAssertFalse(TerminalTabFocus.selectableBundleIDs.contains("dev.warp.Warp-Stable"))
    }

    func testTheGhosttyScriptCompiles() throws {
        // Compiled against the system's own dictionary: what matters is that
        // the generated text parses, whatever the folder name holds.
        let source = TerminalTabFocus.ghosttyScript(tty: "ttys004", cwdCandidates: [#"/tmp/"q" \ end tell"#])
            .replacingOccurrences(of: "tell application \"Ghostty\"", with: "if false then")
            .replacingOccurrences(of: "end tell", with: "end if")
            .replacingOccurrences(of: "select tab (item 2 of ttyHit)", with: "")
            .replacingOccurrences(of: "focus (item 3 of ttyHit)", with: "")
            .replacingOccurrences(of: "activate window (item 1 of ttyHit)", with: "")
            .replacingOccurrences(of: "working directory of term", with: "workingDirectory of term")
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }
}


/// Finding a pane where the agent's environment can't be read: macOS 27
/// keeps a system shell's (`/bin/bash`, `/bin/zsh`) to itself.
final class PaneWithoutEnvironmentTests: XCTestCase {
    func testZellijsSessionIsItsServersSocketName() {
        XCTAssertEqual(Zellij.sessionName(serverArguments: ["/opt/homebrew/bin/zellij", "--server",
            "/var/folders/x/T/zellij-501/contract_version_1/work"]), "work")
        XCTAssertNil(Zellij.sessionName(serverArguments: ["zellij", "attach"]))
    }

    func testZellijsPaneIsTheOneRunningTheAgent() {
        let json = """
        [{"id":0,"is_plugin":true,"pane_command":null},
         {"id":0,"is_plugin":false,"exited":false,"pane_command":"/bin/zsh","pane_cwd":"/Users/me"},
         {"id":2,"is_plugin":false,"exited":false,"pane_command":"claude --resume","pane_cwd":"/Users/me/app"},
         {"id":3,"is_plugin":false,"exited":false,"pane_command":"claude --resume","pane_cwd":"/Users/me/other"}]
        """
        XCTAssertEqual(Zellij.pane(in: json, arguments: ["claude", "--resume"], cwd: "/Users/me/app"), "terminal_2")
        XCTAssertNil(Zellij.pane(in: json, arguments: ["claude", "--resume"], cwd: nil), "two alike and no folder: none")
        XCTAssertNil(Zellij.pane(in: json, arguments: ["codex"], cwd: "/Users/me/app"))
    }

    func testKittysSocketFromItsArgumentsOrConfig() {
        XCTAssertEqual(Kitty.listenOn(arguments: ["kitty", "--listen-on", "unix:/tmp/k"], config: nil, kittyPID: 9).compactMap { $0 },
                       ["unix:/tmp/k"])
        XCTAssertEqual(Kitty.listenOn(arguments: ["kitty", "--listen-on=unix:/tmp/k"], config: nil, kittyPID: 9).compactMap { $0 },
                       ["unix:/tmp/k"])
        XCTAssertEqual(Kitty.listenOn(arguments: ["kitty"], config: "allow_remote_control yes\nlisten_on unix:/tmp/mykitty",
                                      kittyPID: 42).compactMap { $0 },
                       ["unix:/tmp/mykitty", "unix:/tmp/mykitty-42"], "kitty adds its pid to a configured socket")
    }

    func testWezTermsGUISocketIsFoundByItsPID() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wez-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".local/share/wezterm")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("gui-sock-777").path, contents: Data())
        XCTAssertEqual(WezTerm.guiSocket(pid: 777, home: home), dir.appendingPathComponent("gui-sock-777").path)
        XCTAssertNil(WezTerm.guiSocket(pid: 778, home: home))
    }
}
