import AppKit
import ApplicationServices
import Foundation

/// Where macOS stands on one thing spyx needs.
enum Access: Equatable {
    case granted
    case denied
    /// Never asked: the button can raise macOS's own dialog.
    case notAsked
    /// Can't be told right now, and why — "Terminal isn't open".
    case unknown(String)

    var isGranted: Bool { self == .granted }
}

// MARK: - Where the app runs from

/// Where this copy of the app is running from, as it matters to setup.
///
/// Out of Applications, macOS refuses the login item, and a copy run from the
/// disk image or Downloads is translocated to a random read-only path — every
/// permission granted to it is granted to a path that is gone next launch.
enum AppLocation: Equatable {
    case applications
    /// Opened straight from the mounted .dmg.
    case diskImage
    /// Gatekeeper's randomised read-only copy of a quarantined download.
    case translocated
    /// A build folder, the Desktop, Downloads unquarantined.
    case elsewhere

    static func classify(path: String, home: String = NSHomeDirectory()) -> AppLocation {
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        return .elsewhere
    }

    static var current: AppLocation { classify(path: Bundle.main.bundlePath) }

    var needsMove: Bool { self != .applications }
}

enum AppMover {
    static let destination = URL(fileURLWithPath: "/Applications/spyx.app")
    /// The same app under the name it had before it was spyx. Left there it
    /// is a second copy of one bundle ID, and whichever macOS finds first is
    /// the one that opens at login.
    static let formerDestination = URL(fileURLWithPath: "/Applications/LidEffort.app")

    enum Failure: LocalizedError {
        case copy(String)
        var errorDescription: String? {
            switch self { case .copy(let why): return why }
        }
    }

    /// Copy this bundle into /Applications, open that copy, and quit this one.
    ///
    /// An older copy there is replaced — it is the same app, and leaving it
    /// would launch the stale one at login. Moved to the Trash rather than
    /// deleted, so nothing is lost if it was not what it seemed.
    @MainActor
    static func moveToApplications(from source: URL = Bundle.main.bundleURL) throws {
        let fm = FileManager.default
        for older in [destination, formerDestination] where fm.fileExists(atPath: older.path) {
            // The running copy may *be* the one there under another name;
            // it never is here, since `needsMove` said so.
            do { try fm.trashItem(at: older, resultingItemURL: nil) }
            catch { throw Failure.copy(L10n.t("An older copy in Applications couldn't be moved to the Trash.")) }
        }
        do { try fm.copyItem(at: source, to: destination) }
        catch { throw Failure.copy(L10n.t("Couldn't copy spyx into Applications: \(error.localizedDescription)")) }
        // This copy has already been through Gatekeeper — it is the one
        // running. Left quarantined, the copy would be asked about again,
        // and from Downloads it would be translocated all over again.
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? strip.run()
        strip.waitUntilExit()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--setup"]
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - Accessibility

enum AccessibilityAccess {
    static var status: Access { AXIsProcessTrusted() ? .granted : .notAsked }

    /// Adds spyx to the list, switched off, and opens the pane it is in:
    /// Accessibility is the one permission macOS never grants from a dialog.
    /// The first time, macOS's own alert — which adds spyx to the list and
    /// offers the way there. After that the alert no longer appears, so the
    /// pane itself is opened. Never both at once.
    static func request(_ defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: askedKey) {
            NSWorkspace.shared.open(settingsURL)
            return
        }
        defaults.set(true, forKey: askedKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static let askedKey = "accessibility.asked"

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}

// MARK: - Automation

/// A terminal a session can run in, and whether macOS has to agree before
/// spyx can reach into it.
struct AutomationTarget: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let purpose: String
    /// Apple Events, so macOS's Automation consent. The rest are only ever
    /// brought to the front, or opened by their own link — nothing to allow.
    var needsPermission = true

    var id: String { bundleID }

    static let all: [AutomationTarget] = [
        AutomationTarget(bundleID: "com.apple.Terminal", name: "Terminal",
                         purpose: L10n.t("Types /effort into an idle Claude Code tab, and opens a session's tab when you click it.")),
        AutomationTarget(bundleID: "com.googlecode.iterm2", name: "iTerm2",
                         purpose: L10n.t("Opens a session's tab when you click it.")),
        AutomationTarget(bundleID: "com.cmuxterm.app", name: "cmux",
                         purpose: L10n.t("Opens a session's pane when you click it.")),
        AutomationTarget(bundleID: "com.superset.desktop", name: "Superset",
                         purpose: L10n.t("Opens the exact pane through Superset's own link."), needsPermission: false),
        AutomationTarget(bundleID: "com.mitchellh.ghostty", name: "Ghostty",
                         purpose: frontOnly, needsPermission: false),
        AutomationTarget(bundleID: "dev.warp.Warp-Stable", name: "Warp",
                         purpose: frontOnly, needsPermission: false),
        AutomationTarget(bundleID: "com.microsoft.VSCode", name: "VS Code",
                         purpose: frontOnly, needsPermission: false),
        AutomationTarget(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor",
                         purpose: frontOnly, needsPermission: false),
        AutomationTarget(bundleID: "dev.zed.Zed", name: "Zed",
                         purpose: frontOnly, needsPermission: false),
        AutomationTarget(bundleID: "net.kovidgoyal.kitty", name: "kitty",
                         purpose: frontOnly, needsPermission: false),
        AutomationTarget(bundleID: "com.github.wez.wezterm", name: "WezTerm",
                         purpose: frontOnly, needsPermission: false),
    ]

    private static var frontOnly: String { L10n.t("Brought to the front when you click a session.") }

    /// The ones on this Mac. Terminal ships with macOS.
    static func installed(isInstalled: (String) -> Bool = AutomationTarget.isInstalled) -> [AutomationTarget] {
        all.filter { $0.bundleID == "com.apple.Terminal" || isInstalled($0.bundleID) }
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

enum AutomationAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// What macOS's answer means. `procNotFound` is not a refusal: consent can
    /// only be asked of an app that is running.
    static func from(_ status: OSStatus, appName: String) -> Access {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .unknown(L10n.t("\(appName) isn't open"))
        default: return .unknown(L10n.t("macOS didn't say (\(status))"))
        }
    }

    /// Asks macOS; with `ask`, raises its consent dialog if it has never been
    /// answered. Blocks until the person answers, so never on the main thread.
    static func status(of target: AutomationTarget, ask: Bool) -> Access {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: target.bundleID)
        guard let desc = descriptor.aeDesc else { return .unknown(L10n.t("macOS didn't say")) }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        return from(status, appName: target.name)
    }

    /// Launch the app out of sight if it isn't running, then ask.
    static func request(_ target: AutomationTarget) async -> Access {
        if !target.isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // Consent is asked of a process that has finished launching.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        return await Task.detached { status(of: target, ask: true) }.value
    }
}
