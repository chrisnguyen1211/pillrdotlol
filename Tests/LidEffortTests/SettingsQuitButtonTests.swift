import SwiftUI
import XCTest
@testable import LidEffort

@MainActor
final class SettingsQuitButtonTests: XCTestCase {
    func testSettingsRendersWithQuitAction() throws {
        let name = "SettingsQuitButtonTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var didQuit = false
        let settings = SettingsView(
            preferences: Preferences(defaults: defaults),
            providers: { [] },
            signOut: { _ in },
            signIn: { _ in false },
            switchAccount: { _ in false },
            retry: { _ in },
            resetPosition: {},
            quit: { didQuit = true },
            updater: Updater()
        )
        let view = settings.frame(width: SettingsView.width, height: SettingsView.height)

        let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
        XCTAssertEqual(image.size, CGSize(width: SettingsView.width, height: SettingsView.height))

        settings.quit()
        XCTAssertTrue(didQuit)
    }
}
