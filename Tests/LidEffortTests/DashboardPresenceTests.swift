import XCTest
import AppKit
@testable import LidEffort

/// The dashboard runs only while Settings can be seen: closed, hidden or
/// covered, its sky and fire hold still and git is not asked every minute.
@MainActor
final class DashboardPresenceTests: XCTestCase {
    override func tearDown() {
        SettingsPresence.shared.isShowing = false
    }

    func testNothingIsReloadedWhileSettingsCantBeSeen() async {
        var loads = 0
        await DashboardPanel.keepFresh(while: false) { loads += 1 }
        XCTAssertEqual(loads, 0)
    }

    func testTheReloadStopsWhenSettingsIsHidden() async throws {
        final class Count: @unchecked Sendable { var loads = 0 }
        let count = Count()
        let task = Task { @MainActor in
            await DashboardPanel.keepFresh(while: true, every: 0.02) { count.loads += 1 }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()          // what SwiftUI does when `isShowing` changes
        await task.value
        let then = count.loads
        XCTAssertGreaterThan(then, 1, "reloaded while seen")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(count.loads, then, "not reloaded once hidden")
    }

    func testAWindowOffScreenCantBeSeen() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(SettingsPresence.canBeSeen(window), "never shown")
        window.orderOut(nil)
        XCTAssertFalse(SettingsPresence.canBeSeen(window), "ordered out")
    }

    func testClosingSettingsStopsTheDashboard() {
        let defaults = UserDefaults(suiteName: "DashboardPresenceTests.\(UUID().uuidString)")!
        let controller = SettingsWindowController(
            preferences: Preferences(defaults: defaults), providers: { [] }, updater: Updater(),
            signOut: { _ in }, signIn: { _ in false }, switchAccount: { _ in false }, retry: { _ in },
            resetPosition: {}, quit: {})
        SettingsPresence.shared.isShowing = true
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(SettingsPresence.shared.isShowing)

        SettingsPresence.shared.isShowing = true
        let hidden = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        hidden.isReleasedWhenClosed = false
        defer { hidden.close() }
        controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: hidden))
        XCTAssertFalse(SettingsPresence.shared.isShowing, "covered or hidden counts as closed")
    }
}
