import AppKit
import Darwin
import Foundation

/// Brings the window an agent is running in to the front.
///
/// A session knows its own pid and nothing else — Claude Code publishes no
/// window, tab or tty. What it does have is a parent: the shell that launched
/// it, whose parent is the terminal application. So the app is found by walking
/// up the process tree until something turns up that macOS considers an
/// application, and that is what gets raised.
///
/// Raising the app is the answer every terminal gets. Selecting the *tab*
/// inside it needs the terminal's own scripting interface and there is no
/// general one: cmux, Ghostty, Terminal.app and iTerm2 answer over
/// AppleScript, kitty and WezTerm through their remote control, tmux and
/// Zellij through their own command lines (and then the terminal their
/// client runs in is the app); Warp and the editors publish nothing, and
/// get the window that names the session's folder raised. `focus` tries the
/// tab and settles for the app; `activateApp` is the app-only route.
enum SessionFocus {
    /// Where focusing got to: the app brought forward, and whether the
    /// session's own tab was chosen in it — which only some terminals allow.
    struct Focused: Equatable {
        let activated: Bool
        let tabSelected: Bool
    }

    /// Select the tab this process runs in where the terminal allows it, then
    /// raise the owning application either way.
    ///
    /// The tab selection runs off the calling actor: cmux's CLI and osascript
    /// are subprocesses that would otherwise stall the notch's tap handling.
    @discardableResult
    static func focus(pid: pid_t) async -> Bool {
        guard let place = await focusTab(pid: pid) else { return false }
        return place.activated || place.tabSelected
    }

    /// The link that opens a session with no process of its own in the app
    /// that holds it: a Codex app thread, `codex://threads/<id>`.
    static func link(for session: AgentSession) -> URL? {
        guard session.processID == nil, let thread = session.appThreadID else { return nil }
        return CodexDesktopComposer.link(toThread: thread)
    }

    /// Opens such a session by its link: the Codex app comes forward on
    /// that very thread (started if need be), which an app that isn't
    /// active (the notch never is) may not ask for by activating it.
    @MainActor
    @discardableResult
    static func openByLink(_ session: AgentSession) -> Bool {
        guard let url = link(for: session) else { return false }
        let opened = NSWorkspace.shared.open(url)
        Log.usage.notice("focus: opened a Codex app thread by its link: \(opened, privacy: .public)")
        return opened
    }

    /// `focus(pid:)`, telling the app apart from the tab. Nil when nothing
    /// owns the process.
    static func focusTab(pid: pid_t) async -> Focused? {
        // A Superset pane: its own deep link opens the workspace with that
        // very terminal in front, which no window-level raise can.
        if Superset.place(of: pid) != nil, await MainActor.run(body: { Superset.focus(pid: pid) }) {
            return Focused(activated: true, tabSelected: true)
        }
        let app = owningApp(of: pid)
        // A Claude app session: the app's own link opens that very session
        // and brings the window forward, which an app that isn't active
        // (the notch never is) may not ask for itself.
        // An older Claude app that doesn't know the link leaves the window
        // as it was: then the usual way below, the app brought forward.
        if app?.bundleIdentifier == ClaudeDesktopComposer.bundleID,
           let host = await MainActor.run(body: { SessionModels.desktop(pid: pid)?.hostSessionID }),
           ClaudeDesktopComposer.link(toHostSession: host) != nil,
           await ClaudeDesktopComposer.open(hostSession: host) {
            Log.usage.notice("focus pid \(pid, privacy: .public): opened its Claude app session by link")
            return Focused(activated: true, tabSelected: true)
        }
        let cwd = currentDirectory(of: pid)
        // In tmux or Zellij the pane is chosen in the multiplexer, and the
        // terminal to raise is the one its client runs in: the agent's own
        // tree ends at a server that belongs to no app.
        var hostPID = pid
        var hostTTY = tty(of: pid)
        var paneSelected = true
        // (No bundle given: only a multiplexer is looked for here; kitty and
        // WezTerm choose their tab in `selectTab` like any terminal.)
        if let pane = PaneHosts.locate(pid: pid, bundleID: nil, bundleURL: nil), pane.isMultiplexer {
            let chosen = await Task.detached(priority: .userInitiated) { PaneHosts.focus(pane) }.value
            Log.usage.notice("focus pid \(pid, privacy: .public): \(pane.name, privacy: .public) pane \(chosen.selected, privacy: .public), client \(chosen.clientPID ?? 0, privacy: .public)")
            paneSelected = chosen.selected
            guard let client = chosen.clientPID else { return nil }
            hostPID = client
            hostTTY = chosen.clientTTY
        }
        let host = hostPID == pid ? app : owningApp(of: hostPID)
        let tty = hostTTY
        Log.usage.notice("focus pid \(pid, privacy: .public): app \(host?.localizedName ?? "none", privacy: .public) (\(host?.bundleIdentifier ?? "-", privacy: .public)), tty \(tty ?? "-", privacy: .public)")
        let selectPID = hostPID
        var selected = await Task.detached(priority: .userInitiated) {
            TerminalTabFocus.selectTab(bundleID: host?.bundleIdentifier, pid: selectPID, tty: tty, cwd: cwd)
        }.value
        guard let app = host else {
            Log.usage.notice("no owning app for pid \(pid, privacy: .public)")
            return nil
        }
        // No tab to name: the window that names the session's folder, where
        // there is exactly one.
        if !selected, !TerminalTabFocus.selectableBundleIDs.contains(app.bundleIdentifier ?? "") {
            let hints = WindowFocus.folderHints(cwd: cwd)
            let raised = await MainActor.run { WindowFocus.raise(appPID: app.processIdentifier, hints: hints) }
            Log.usage.notice("focus pid \(pid, privacy: .public): window raised \(raised, privacy: .public)")
        }
        selected = selected && paneSelected
        // Since macOS 14 an app that is not itself active may be refused
        // when it asks to activate another — and this one never is active;
        // its panel does not take key. Asking the workspace to open the
        // app is the route that is always honoured: an app already running
        // is simply brought to the front.
        let activated = await MainActor.run { app.activate() }
        if !activated, let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        Log.usage.notice("focus pid \(pid, privacy: .public): tab \(selected, privacy: .public), activate \(activated, privacy: .public)")
        return Focused(activated: activated, tabSelected: selected)
    }

    /// The process's controlling terminal, named the way ps prints it
    /// (`ttys014`). Nil when it has none — agents with no terminal to go back
    /// to, which is most desktop-hosted sessions.
    static func tty(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return nil }
        // NODEV (-1) is "no controlling terminal"; devname would read it as a
        // real device number and answer garbage.
        guard info.kp_eproc.e_tdev != -1,
              let name = devname(info.kp_eproc.e_tdev, S_IFCHR)
        else { return nil }
        return String(cString: name)
    }

    /// The process's working directory — how a terminal that publishes no tty
    /// (cmux's AppleScript interface) can still name the tab it lives in.
    static func currentDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let read = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                                Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard read == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Raise whichever application owns this process.
    ///
    /// Returns false when the chain runs out before an application appears,
    /// which is the honest answer for an agent started by launchd, over ssh, or
    /// from a process that has since been reparented to init.
    @discardableResult
    static func activateApp(owning pid: pid_t) -> Bool {
        guard let app = owningApp(of: pid) else {
            Log.usage.debug("no owning app for pid \(pid, privacy: .public)")
            return false
        }
        // `activate()` rather than the deprecated options form: the notch's own
        // panel is non-activating, so there is no focus of ours to hand over
        // and nothing to co-ordinate.
        return app.activate()
    }

    /// The nearest ancestor process that macOS knows as a running application.
    static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        // The app with windows, not merely the nearest bundle. Claude
        // Desktop runs its Claude Code sessions from a `claude.app` bundle
        // of their own — a background bundle with an identifier and no
        // windows — so the nearest bundled ancestor was the CLI itself, and
        // activating it brought nothing to the front. A regular app up the
        // chain (Claude, Terminal) is the one to raise; the nearest bundle
        // is only the answer when there is no such app above it.
        var nearest: NSRunningApplication?
        for candidate in ancestry(of: pid) {
            guard let app = NSRunningApplication(processIdentifier: candidate),
                  app.bundleIdentifier != nil else { continue }
            if app.activationPolicy == .regular { return app }
            if nearest == nil { nearest = app }
        }
        return nearest
    }

    /// The process and its parents, nearest first.
    ///
    /// Bounded rather than looped until pid 1: a corrupted `kinfo_proc` that
    /// reports itself as its own parent would otherwise spin forever, and no
    /// real chain from an agent to its terminal is more than a handful deep.
    static func ancestry(of pid: pid_t, limit: Int = 8) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while chain.count < limit, current > 1 {
            chain.append(current)
            guard let parent = parent(of: current), parent != current else { break }
            current = parent
        }
        return chain
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return nil }
        return info.kp_eproc.e_ppid
    }
}
