import XCTest
@testable import LidEffort
import LidEffortCore

/// Replies typed into real terminals and multiplexers, around a stand-in
/// agent that draws Claude Code's input box and writes down every line it
/// gets. Opt-in, as they start tools and windows:
///
///     EFFORT_LIVE_HOSTS=1 swift test --filter LiveHostsTests
final class LiveHostsTests: XCTestCase {
    static let dir = "/tmp/pillr-live"
    static let agent = "/tmp/pillr-live/agent.sh"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EFFORT_LIVE_HOSTS"] == "1", "live hosts are opt-in")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.agent), "the stand-in agent is missing")
    }

    /// A tool run to its end. `detached` for one that leaves a server
    /// behind, which would hold a pipe open forever.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], detached: Bool = false,
                    environment: [String: String] = [:]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        if detached {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            return ""
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
        // Read before waiting: a long answer (ps) would fill the pipe and
        // wait on us while we waited on it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func received(_ name: String) -> [String] {
        ((try? String(contentsOfFile: "\(dir)/received-\(name)", encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    }

    static func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    static func note(_ text: String) {
        let url = URL(fileURLWithPath: "\(dir)/notes")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data("\(Date()) \(text)\n".utf8)); try? handle.close()
        } else { try? Data("\(Date()) \(text)\n".utf8).write(to: url) }
    }

    /// What a reply has to survive: a shell would run all of this.
    static let tricky = #"a; rm -rf ~/nothing $(echo x) `id` && "q" 'q' \n end;"#

    /// The checks every host gets once its pane is found.
    func exercise(_ host: PaneHost, name: String, typeDraft: (String) -> Void,
                  file: StaticString = #filePath, line: UInt = #line) {
        Self.note("write 1")
        XCTAssertEqual(PaneHosts.write("hello from pillr", stashKey: nil, to: host), .sent, "idle prompt", file: file, line: line)
        Self.wait(0.6)
        XCTAssertEqual(Self.received(name).last, "hello from pillr", file: file, line: line)

        XCTAssertEqual(PaneHosts.write(Self.tricky, stashKey: nil, to: host), .sent, file: file, line: line)
        Self.wait(0.6)
        XCTAssertEqual(Self.received(name).last, Self.tricky, "typed as text, never run", file: file, line: line)

        typeDraft("my draft")
        Self.wait(0.6)
        XCTAssertEqual(PaneHosts.write("over a draft", stashKey: nil, to: host), .busy,
                       "a draft and no stash: left alone", file: file, line: line)
        XCTAssertEqual(PaneHosts.write("over a draft", stashKey: "\u{13}", to: host), .sent,
                       "Claude Code's stash goes first", file: file, line: line)
        Self.wait(0.6)
        XCTAssertEqual(Self.received(name).last, "my draft\u{13}over a draft",
                       "the stash key reaches the agent ahead of the reply", file: file, line: line)

        XCTAssertTrue(PaneHosts.focus(host).selected, "focus", file: file, line: line)
    }

    // MARK: tmux

    func testTmux() throws {
        let tmux = "/opt/homebrew/bin/tmux"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tmux))
        Self.run(tmux, ["kill-session", "-t", "pillrlive"])
        Self.run(tmux, ["new-session", "-d", "-s", "pillrlive", "-x", "120", "-y", "30", "\(Self.agent) tmux"])
        defer { Self.run(tmux, ["kill-session", "-t", "pillrlive"]) }
        Self.wait(1)
        let pid = try XCTUnwrap(pid_t(Self.run(tmux, ["list-panes", "-t", "pillrlive", "-F", "#{pane_pid}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)), "the pane's process")
        let host = try XCTUnwrap(PaneHosts.locate(pid: pid, bundleID: nil, bundleURL: nil), "pillr finds the pane")
        guard case .tmux = host else { return XCTFail("found as \(host.name)") }
        exercise(host, name: "tmux") { draft in Self.run(tmux, ["send-keys", "-t", "pillrlive", "-l", draft]) }
    }

    // MARK: Zellij

    func testZellij() throws {
        let zellij = "/opt/homebrew/bin/zellij"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: zellij))
        Self.note("delete old")
        Self.run(zellij, ["delete-session", "pillrlive", "--force"], detached: true)
        Self.note("attach")
        // The stand-in agent as the session's shell: its first pane.
        Self.run(zellij, ["attach", "--create-background", "pillrlive"], detached: true,
                 environment: ["SHELL": Self.agent, "PILLR_AGENT_NAME": "zellij"])
        Self.note("attached")
        defer {
            Self.run(zellij, ["kill-session", "pillrlive"], detached: true)
            Self.run(zellij, ["delete-session", "pillrlive", "--force"], detached: true)
        }
        Self.wait(1.5)
        Self.wait(1.5)
        let line = Self.run("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n")
            .first { $0.hasSuffix(" /bin/bash \(Self.agent)") }
        let pid = try XCTUnwrap(line.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") },
                                "the stand-in agent's process")
        let host = try XCTUnwrap(PaneHosts.locate(pid: pid, bundleID: nil, bundleURL: nil), "pillr finds the pane")
        guard case .zellij = host else { return XCTFail("found as \(host.name)") }
        guard case .zellij(let pane) = host else { return }
        exercise(host, name: "zellij") { draft in
            Self.run(zellij, ["--session", "pillrlive", "action", "write-chars", "--pane-id", pane.paneID, "--", draft], detached: true)
        }
    }

    // MARK: Windows of their own

    /// The stand-in agent's process, started under some terminal as `name`.
    static func agentPID(_ name: String, within seconds: Double = 8) -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let line = run("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n")
                .first { $0.hasSuffix(" /bin/bash \(agent) \(name)") }
            if let line, let pid = pid_t(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") { return pid }
            wait(0.3)
        }
        return nil
    }

    static func launch(_ tool: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
        return process
    }

    func testKitty() throws {
        let kitty = "/Applications/kitty.app/Contents/MacOS/kitty"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: kitty))
        let socket = "\(Self.dir)/kitty.sock"
        try? FileManager.default.removeItem(atPath: socket)
        let app = Self.launch(kitty, ["--single-instance=no", "--listen-on", "unix:\(socket)",
                                      "-o", "allow_remote_control=yes", "-o", "confirm_os_window_close=0",
                                      Self.agent, "kitty"])
        defer { app.terminate() }
        let pid = try XCTUnwrap(Self.agentPID("kitty"), "the stand-in agent in kitty")
        Self.wait(1.5)
        let host = try XCTUnwrap(PaneHosts.locate(pid: pid, bundleID: PaneHosts.kittyBundleID,
                                                  bundleURL: URL(fileURLWithPath: "/Applications/kitty.app")),
                                 "pillr finds the window")
        guard case .kitty(let window) = host else { return XCTFail("found as \(host.name)") }
        exercise(host, name: "kitty") { draft in
            Self.run("/Applications/kitty.app/Contents/MacOS/kitten",
                     ["@", "--to", window.socket, "send-text", "--match", "pid:\(pid)", "--", draft])
        }
    }

    func testWezTerm() throws {
        let wezterm = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: wezterm))
        let app = Self.launch(wezterm, ["start", "--always-new-process", "--", Self.agent, "wezterm"])
        defer { app.terminate(); Self.run("/usr/bin/pkill", ["-f", "wezterm-gui start --always-new-process"]) }
        let pid = try XCTUnwrap(Self.agentPID("wezterm", within: 15), "the stand-in agent in WezTerm")
        Self.wait(1.5)
        let host = try XCTUnwrap(PaneHosts.locate(pid: pid, bundleID: PaneHosts.weztermBundleID,
                                                  bundleURL: URL(fileURLWithPath: "/Applications/WezTerm.app")),
                                 "pillr finds the pane")
        guard case .wezterm(let found) = host else { return XCTFail("found as \(host.name)") }
        let socket = ["WEZTERM_UNIX_SOCKET": found.socket ?? ""]
        let tty = SessionFocus.tty(of: pid).map(ProcessTable.normalizeTTY)
        let paneID = WezTerm.parseList(Self.run(wezterm, ["cli", "--no-auto-start", "list", "--format", "json"], environment: socket))
            .first { $0.tty == tty }?.paneID
        XCTAssertNotNil(paneID, "the pane, by its tty")
        exercise(host, name: "wezterm") { draft in
            guard let paneID else { return }
            Self.run(wezterm, ["cli", "--no-auto-start", "send-text", "--no-paste", "--pane-id", String(paneID), draft],
                     environment: socket)
        }
    }
}
