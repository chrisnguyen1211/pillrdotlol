import AppKit
import Foundation

/// pillr was called spyx until 1.1. Everything spyx kept under its own name
/// is carried over once, the first time pillr runs, so an update loses
/// nothing: the settings (`Preferences.migrateFromPreviousDomain`), the
/// folder in Application Support, the browser sign-ins, the keys in the
/// keychain (`KeychainItem`, as each is first read) and the done hooks in
/// each agent (`AgentHooks.removeLegacy`).
///
/// The old name is spelled out here and nowhere else in the app.
enum Rebrand {
    static let previousName = "spyx"
    static let previousBundleID = "lol.spyx.app"

    /// Copies what lives under the old name, before anything — WebKit,
    /// `URLSession`, the costs index — opens the new one. A copy, not a move,
    /// for everything but Application Support: an older copy of the app left
    /// on the Mac still finds its own.
    static func carryOver(fileManager: FileManager = .default,
                          library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                          bundleID: String = Bundle.main.bundleIdentifier ?? "lol.pillr.app") {
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        move(support.appendingPathComponent(previousName), to: support.appendingPathComponent("pillr"), fileManager)
        for folder in ["WebKit", "HTTPStorages"] {
            let base = library.appendingPathComponent(folder, isDirectory: true)
            copy(base.appendingPathComponent(previousBundleID), to: base.appendingPathComponent(bundleID), fileManager)
        }
        let cookies = library.appendingPathComponent("HTTPStorages", isDirectory: true)
        copy(cookies.appendingPathComponent(previousBundleID + ".binarycookies"),
             to: cookies.appendingPathComponent(bundleID + ".binarycookies"), fileManager)
    }

    private static func move(_ from: URL, to: URL, _ fileManager: FileManager) {
        guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { return }
        do { try fileManager.moveItem(at: from, to: to) } catch {
            Log.usage.error("could not carry over \(from.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func copy(_ from: URL, to: URL, _ fileManager: FileManager) {
        guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { return }
        do { try fileManager.copyItem(at: from, to: to) } catch {
            Log.usage.error("could not carry over \(from.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The app's own name on disk

    /// Where this copy should be: an update installs over the old bundle and
    /// keeps its name, so `/Applications/spyx.app` would go on holding pillr.
    /// Nil when it already has its name, or the folder already holds one.
    static func renamedLocation(for bundleURL: URL, fileManager: FileManager = .default) -> URL? {
        guard bundleURL.lastPathComponent == previousName + ".app" else { return nil }
        let target = bundleURL.deletingLastPathComponent().appendingPathComponent("pillr.app")
        guard !fileManager.fileExists(atPath: target.path),
              fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else { return nil }
        return target
    }

    /// Gives the bundle its new name and starts again from there, so the
    /// hooks, the login item and Finder all name pillr. True when a new
    /// copy is on its way and this one should quit.
    static func renameBundleIfNeeded(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        guard let target = renamedLocation(for: bundleURL) else { return false }
        do {
            try FileManager.default.moveItem(at: bundleURL, to: target)
        } catch {
            Log.usage.error("could not rename the app: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        // This copy goes once the new one is under way; the new one retires
        // it too (`AppDelegate.retireOlderInstances`), should this not run.
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}
