import XCTest
import AppKit
@testable import LidEffort

/// The drop that runs round the bezel when the notch changes edge is a
/// full-screen window of its own. It has to go when the drop is done —
/// even when whoever started it has already let go of it, as the notch
/// does the moment the pill has faded back in.
@MainActor
final class EdgeFlowLeakTests: XCTestCase {
    private func dropWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.isVisible && $0 is NSPanel && $0.ignoresMouseEvents && $0.frame.width > 400 }
    }

    func testTheDropsWindowGoesEvenWhenNobodyHoldsTheOverlay() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let before = dropWindows().count
        for _ in 0..<3 {
            var overlay: EdgeFlowOverlay? = EdgeFlowOverlay()
            overlay?.run(on: screen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 400, y: 10)], depth: 20,
                         pillFraction: 0.2, duration: 0.05, glassy: false) {}
            // What the notch does: drop its reference once the pill is back —
            // or straight away, when another edge change replaces it.
            overlay = nil
            _ = overlay
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05 + EdgeFlowView.handoff + 0.4))
        XCTAssertEqual(dropWindows().count, before, "every drop's window is gone, not left animating behind the notch")
    }
}
