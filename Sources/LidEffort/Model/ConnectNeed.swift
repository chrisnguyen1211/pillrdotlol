import AppKit
import Foundation

/// A provider that cannot be read until something is done about its
/// account, and the one thing to do: said in its tooltip in place of the
/// effort bar, which would otherwise offer to set a level for an agent
/// that is not signed in.
struct ConnectNeed: Equatable {
    enum Action: Equatable {
        /// Open the app the account lives in.
        case openApp
        /// Run the sign-in command in a new Terminal window.
        case terminal(String)
        /// Ask macOS for the saved login again.
        case allowAccess
        /// Nothing to do from here: open Settings → Accounts.
        case settings
    }

    /// Why — "Sign-in expired".
    let reason: String
    let buttonTitle: String
    let action: Action

    /// What a provider needs, from its status, whether its token aged out,
    /// how it is signed in, and whether its app is on this Mac.
    static func need(status: ProviderStatus, expired: Bool, route: SignInRoute,
                     command: String?, appInstalled: (String) -> Bool) -> ConnectNeed? {
        let reason: String
        switch status {
        case .needsAuth: reason = L10n.t("Not signed in")
        case .signedOutByOwner: reason = L10n.t("Signed out")
        case .accessDenied:
            return ConnectNeed(reason: L10n.t("macOS blocked access"), buttonTitle: L10n.t("Allow access…"), action: .allowAccess)
        default:
            guard expired else { return nil }
            reason = L10n.t("Sign-in expired")
        }
        switch route {
        case .openApp(let bundleID, let name) where appInstalled(bundleID):
            return ConnectNeed(reason: reason, buttonTitle: L10n.t("Open \(name)"), action: .openApp)
        case .modal(let name):
            return ConnectNeed(reason: reason, buttonTitle: L10n.t("Sign in to \(name)"), action: .openApp)
        default:
            if let command {
                return ConnectNeed(reason: reason, buttonTitle: L10n.t("Sign in in Terminal"), action: .terminal(command))
            }
            return ConnectNeed(reason: reason, buttonTitle: L10n.t("Settings…"), action: .settings)
        }
    }

    /// Opens a Terminal window running the sign-in command — at your click,
    /// never otherwise, and the command is on the button's help first.
    static func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { Log.usage.error("sign-in command failed to start: \(error, privacy: .public)") }
    }
}
