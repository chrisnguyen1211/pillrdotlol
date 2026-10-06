import SwiftUI

@main
struct LidEffortMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { PromptHookClient.runIfRequested()
        CLIDiagnostics.runIfRequested() }

    var body: some Scene {
        // The notch is the UI; the panel is put up by the delegate. This scene
        // exists only because `App` needs one.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.t("Settings…")) { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appInfo) {
                    Button(L10n.t("Check for Updates…")) { appDelegate.checkForUpdates() }
                }
                CommandGroup(replacing: .help) {
                    Button(L10n.t("Report a Bug…")) {
                        BugReport.open(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    }
                }
            }
    }
}
