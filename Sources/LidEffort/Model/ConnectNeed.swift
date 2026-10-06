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

/// What a row in Settings → Accounts offers at its trailing end, in place of
/// the on/off switch every row used to have.
///
/// A switch read as "turn this on", not "sign in to this", and an agent that
/// was not signed in looked the same either way round. So each row now says
/// which of four states it is in and offers the one control that moves it on.
enum AccountRowState: Equatable {
    /// A local model: the switch stays, because it only shows or hides the
    /// model in the notch — there is nothing to sign in to.
    case toggle
    /// Switched off. One Connect button, which switches it on and starts
    /// whatever sign-in it needs.
    case connect
    /// Switched on but not readable yet, and what would fix it. Its button is
    /// shown only when it does something from here (`offersButton`).
    case needs(ConnectNeed)
    /// Switched on and reading.
    case reading

    static func resolve(isLocalModel: Bool, isConnected: Bool, need: ConnectNeed?) -> AccountRowState {
        if isLocalModel { return .toggle }
        guard isConnected else { return .connect }
        if let need { return .needs(need) }
        return .reading
    }

    /// The need to show for a connected row.
    ///
    /// The store's own answer (`UsageStore.connectNeeds()`) wins whenever the
    /// provider is on the notch: it follows each reading, so it clears the
    /// moment a sign-in lands. A provider not there yet — switched on a moment
    /// ago, or a sheet with no store — is judged from its summary instead.
    /// A refusal is taken from the summary either way: it leaves the last
    /// reading's status untouched, so the store's snapshot never says so.
    static func need(live: ConnectNeed?, isOnNotch: Bool, summary: ProviderSummary,
                     appInstalled: (String) -> Bool) -> ConnectNeed? {
        // A refusal first, whatever else the store still says: an old
        // "expired" can outlive it, and only Allow access… fixes a refusal.
        if summary.wasRefusedAccess {
            return ConnectNeed.need(status: .accessDenied, expired: false, route: summary.signIn,
                                    command: summary.signInCommand, appInstalled: appInstalled)
        }
        if isOnNotch, let live { return live }
        guard !isOnNotch else { return nil }
        let status: ProviderStatus = summary.account == nil && summary.kind == .usage ? .needsAuth : .ok
        return ConnectNeed.need(status: status, expired: summary.needsSignInRenewal, route: summary.signIn,
                                command: summary.signInCommand, appInstalled: appInstalled)
    }
}

extension ConnectNeed {
    /// Whether the need has a button in Settings. `.settings` means "open
    /// Settings", which is where the row already is — its guidance or key
    /// field is the answer there.
    var offersButton: Bool { action != .settings }
}
