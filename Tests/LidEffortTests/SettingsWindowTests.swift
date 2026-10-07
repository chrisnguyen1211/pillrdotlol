import XCTest
import AppKit
import SwiftUI
@testable import LidEffort

/// The Settings window's top bar sits where a title bar would. macOS gives a
/// press there to the window server, to move the window, wherever the view
/// under it says it can move the window — so nothing under the bar may, or
/// the appearance icon, search and quit never get their clicks.
@MainActor
final class SettingsWindowTests: XCTestCase {
    func testNothingUnderTheTopBarMovesTheWindow() {
        XCTAssertFalse(SettingsHostingView(rootView: EmptyView()).mouseDownCanMoveWindow, "the host")
        XCTAssertFalse(StillEffectView().mouseDownCanMoveWindow, "the glass behind the bar")
        XCTAssertFalse(WindowDragHandle.Handle().mouseDownCanMoveWindow,
                       "the bar's empty stretch moves the window itself, not through the window server")
    }

    /// A press in the title strip reaches a button there.
    func testAButtonInTheTitleStripTakesItsClick() throws {
        final class Counter { var taps = 0 }
        let counter = Counter()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.close() }
        window.contentView = SettingsHostingView(rootView: VStack(spacing: 0) {
            Button { counter.taps += 1 } label: { Color.red.frame(width: 28, height: 28) }
                .buttonStyle(.plain)
                .frame(height: 52)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea())
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let point = NSPoint(x: 200, y: window.frame.height - 26)
        XCTAssertGreaterThanOrEqual(point.y, window.contentLayoutRect.maxY, "the point is under the title bar")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(counter.taps, 1)
    }

    /// The real sheet, pressed where the appearance icon is: it must change
    /// the appearance. The preview under the bar used to take the press —
    /// its notch is laid out full size and scaled, and its hit area ran up
    /// over the whole bar.
    func testTheAppearanceIconInTheRealSheetTakesItsClick() throws {
        let defaults = UserDefaults(suiteName: "SettingsWindowTests.\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.appearanceChoice = .light
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: SettingsView.width, height: SettingsView.height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.close() }
        window.contentView = SettingsHostingView(rootView: SettingsView(
            preferences: preferences, providers: { [] }, signOut: { _ in }, signIn: { _ in false },
            switchAccount: { _ in false }, retry: { _ in }, resetPosition: {}, quit: {}, updater: Updater()))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        // Right to left along the bar: padding, quit, gap, search, gap, the icon.
        let iconX = SettingsView.width - 14 - 28 - 12 - 190 - 12 - 14
        let point = NSPoint(x: iconX, y: window.frame.height - SettingsView.headerHeight / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(preferences.appearanceChoice, .dark, "Light → Dark: the icon took the press")
    }
}
