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
}
