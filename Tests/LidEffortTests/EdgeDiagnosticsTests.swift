import XCTest
@testable import LidEffort

/// Where the panel is and what an edge change does, on this Mac's screens.
/// Prints only; skipped unless `PILLR_EDGE_DIAG` is set.
@MainActor
final class EdgeDiagnosticsTests: XCTestCase {
    func testPrintEdgeChange() throws {
        guard ProcessInfo.processInfo.environment["PILLR_EDGE_DIAG"] != nil else { throw XCTSkip("set PILLR_EDGE_DIAG") }
        for s in NSScreen.screens { print("DIAG screen \(s.localizedName) \(s.frame) visible \(s.visibleFrame)") }
        print("DIAG preferred \(NotchGeometry.preferredScreen(from: NSScreen.screens)?.frame ?? .zero) main \(NSScreen.main?.frame ?? .zero)")
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        print("DIAG start edge \(controller.model.edge) frame \(String(describing: controller.panelFrameForTesting)) alpha \(controller.panelAlphaForTesting)")
        for edge in [NotchEdge.bottom, .left, .top, .right] {
            controller.apply(edge: edge)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            let mid = controller.panelAlphaForTesting
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            print("DIAG → \(edge): model \(controller.model.edge) alpha mid \(mid) end \(controller.panelAlphaForTesting) frame \(String(describing: controller.panelFrameForTesting))")
        }
    }
}
