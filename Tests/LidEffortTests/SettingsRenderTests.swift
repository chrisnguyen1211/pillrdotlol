import XCTest
import SwiftUI
import LidEffortCore
@testable import LidEffort

/// Every pane of the settings window, drawn by AppKit in an offscreen
/// window — `cacheDisplay` draws the real controls, which an
/// `ImageRenderer` cannot — and written out when EFFORT_RENDER_DIR is set.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private func snapshot(_ view: some View, size: CGSize, name: String, dark: Bool) throws {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    func testEveryPaneDraws() throws {
        let suite = "SettingsRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let pane = CGSize(width: SettingsView.width, height: 1500)
        let panes: [(String, AnyView)] = [
            ("lid", AnyView(LidPane(effort: EffortController(defaults: defaults)))),
            ("notch", AnyView(NotchPane(preferences: preferences, displays: [], resetPosition: {}))),
            ("sessions", AnyView(SessionsPane(preferences: preferences))),
            ("notifications", AnyView(NotificationsPane(preferences: preferences, previewResetAlert: {},
                                                        previewSessionLimitAlert: {}, previewWeeklyLimitAlert: {},
                                                        showAccounts: {}))),
            ("general", AnyView(GeneralPane(preferences: preferences, updater: Updater()))),
        ]
        for dark in [true, false] {
            preferences.interfaceMode = dark ? .dark : .light
            for (name, view) in panes {
                try snapshot(view.scrollContentBackground(.hidden), size: pane, name: name, dark: dark)
            }
            let window = SettingsView(preferences: preferences, providers: { [] }, signOut: { _ in }, signIn: { _ in false },
                                      switchAccount: { _ in false }, retry: { _ in }, resetPosition: {}, quit: {},
                                      updater: Updater())
            try snapshot(window, size: CGSize(width: SettingsView.width, height: SettingsView.height), name: "window", dark: dark)
            var accounts = window
            accounts.startSection = .accounts
            try snapshot(accounts, size: CGSize(width: SettingsView.width, height: SettingsView.height), name: "accounts", dark: dark)
        }
    }

    func testSearchFindsSettingsByWhatTheyDo() {
        XCTAssertEqual(Set(SettingsIndex.search("sound").map(\.section)), [.notifications])
        XCTAssertTrue(SettingsIndex.search("claude hook").contains { $0.title == "Answer Claude from the notch" })
        XCTAssertTrue(SettingsIndex.search("MONITOR").contains { $0.section == .notch })
        XCTAssertTrue(SettingsIndex.search("codex").contains { $0.section == .lid })
        XCTAssertTrue(SettingsIndex.search("").isEmpty)
        XCTAssertTrue(SettingsIndex.search("zzzz").isEmpty)
    }
}
