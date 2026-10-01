import Testing
@testable import LidEffortCore

struct ProcessTableTests {
    // Verbatim shape of `ps -axo pid=,ppid=,tty=,comm=` on macOS: right-
    // aligned pids, double-space column padding, spaces inside comm.
    static let sample = """
        1     0 ??       /sbin/launchd
    16680     1 ??       /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
    16681 16680 ttys000  login
    16682 16681 ttys000  -zsh
    16704 16682 ttys000  grok
    35649     1 ??       /Applications/Claude.app/Contents/MacOS/Claude
    48079 35649 ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper
    54527 48079 ttys006  /bin/zsh
    56011 54527 ttys006  claude
    56766 48079 ttys007  /bin/zsh
    56788 56766 ttys007  claude
    40786 16680 ttys004  login
    40787 40786 ttys004  -zsh
    40790 40787 ttys004  claude
    40800 40787 ttys009  /Users/x/.local/bin/codex
      123   122 ??       /Users/x/Library/Application Support/Claude/claude-code/2.1.266/claude.app/Contents/MacOS/claude
    """

    @Test func parsesPaddedColumnsAndSpacesInCommand() {
        let table = ProcessTable(psOutput: Self.sample)
        let helper = table.rows.first { $0.pid == 48079 }
        #expect(helper?.command == "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper")
        let claude = table.rows.first { $0.pid == 56011 }
        #expect(claude?.command == "claude")
        #expect(claude?.tty == "ttys006")
        #expect(table.rows.first { $0.pid == 123 }?.ppid == 122)
    }

    @Test func doubleSpacePaddingDoesNotLeakIntoCommand() {
        let table = ProcessTable(psOutput: "56011 54527 ttys006  claude")
        #expect(table.rows.first?.command == "claude")
    }

    @Test func findsClaudeSessionsOnlyOnRealTTYs() {
        let sessions = ProcessTable(psOutput: Self.sample).interactiveSessions(command: "claude")
        #expect(sessions.map(\.tty).sorted() == ["ttys004", "ttys006", "ttys007"])
        #expect(!sessions.contains { $0.pid == 123 })
    }

    @Test func registryFindsEveryKnownAgentWithItsName() {
        let sessions = ProcessTable(psOutput: Self.sample).interactiveSessions(commands: ProcessTable.knownAgents)
        let byTTY = Dictionary(uniqueKeysWithValues: sessions.map { ($0.tty, $0.agent) })
        #expect(byTTY["ttys000"] == "grok")
        #expect(byTTY["ttys009"] == "codex", "full-path executables resolve by last path component")
        #expect(byTTY["ttys006"] == "claude")
        #expect(sessions.count == 5)
    }

    @Test func resolvesHostAppFromParentChain() {
        let table = ProcessTable(psOutput: Self.sample)
        #expect(table.hostApp(of: 56011) == "Claude")
        #expect(table.hostApp(of: 40790) == "Terminal")
        #expect(table.hostApp(of: 1) == nil)
    }

    @Test func normalizesDevPrefix() {
        #expect(ProcessTable.normalizeTTY("/dev/ttys006") == "ttys006")
        #expect(ProcessTable.normalizeTTY("ttys006") == "ttys006")
    }
}
