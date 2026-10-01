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
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
