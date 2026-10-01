import Foundation
import Sparkle

/// Updates, through Sparkle: the signed appcast on the GitHub releases, checked in the
/// background, downloaded and installed on the next launch when the user
/// leaves "Install updates automatically" on.
///
/// Settings talks to this rather than to Sparkle: a preference, a version, a
/// "check now" and what it found. Sparkle only starts in a bundle that names
/// a feed — a `swift run` binary or a test host has none, and asks nothing.
@MainActor
final class Updater: NSObject, ObservableObject {
    enum Outcome: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)

        var message: String? {
            switch self {
            case .idle: return nil
            case .checking: return L10n.t("Checking…")
            case .upToDate: return L10n.t("spyx is up to date.")
            case .found(let v): return L10n.t("Version \(v) is available.")
            case .unreachable: return L10n.t("Couldn't reach the update server. spyx will try again on its own — nothing is wrong with this copy.")
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle
    private static let automaticKey = "updater.automatic"
    private var controller: SPUStandardUpdaterController?

    var automatic: Bool {
        get {
            UserDefaults.standard.object(forKey: Updater.automaticKey) == nil
                ? true : UserDefaults.standard.bool(forKey: Updater.automaticKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Updater.automaticKey)
            controller?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Whether this build can update itself at all.
    static var hasFeed: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start() {
        guard controller == nil, !Runtime.isUnderTest, Self.hasFeed else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = automatic
        controller.startUpdater()
        self.controller = controller
    }

    /// Asks the feed now, with Sparkle's own window if there is something new.
    func checkNow() {
        guard let controller else {
            outcome = .failed(L10n.t("This build can't update itself. Download the latest from the releases page on GitHub."))
            return
        }
        outcome = .checking
        controller.checkForUpdates(nil)
    }

    /// Network failures, as opposed to a feed that answered with nothing new.
    nonisolated static func isUnreachable(_ code: Int) -> Bool {
        [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
         NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed].contains(code)
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.outcome = .found(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.outcome = .upToDate(Date()) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        // "No update" arrives here too, after `updaterDidNotFindUpdate`.
        guard !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) else { return }
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? error.code
        let outcome: Outcome = Self.isUnreachable(underlying) ? .unreachable : .failed(error.localizedDescription)
        Task { @MainActor in self.outcome = outcome }
    }
}
