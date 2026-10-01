import SwiftUI
import XCTest
@testable import LidEffort

/// The top edge on a display without a notch and on notched MacBooks of a
/// few sizes, folded and open, written out when EFFORT_RENDER_DIR is set —
/// for looking at, since balance is not something a unit test can judge.
@MainActor
final class TopEdgeRenderTests: XCTestCase {
    func testTheTopEdgeRendersOnEveryKindOfDisplay() throws {
        let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"]
        let cases: [(String, HardwareNotch?, Bool, Int)] = [
            ("plain-open-3", nil, true, 3), ("plain-folded-3", nil, false, 3),
            ("plain-open-1", nil, true, 1), ("plain-open-5", nil, true, 5),
            ("mbp14-open-3", HardwareNotch(width: 185, height: 32), true, 3),
            ("mbp14-folded-3", HardwareNotch(width: 185, height: 32), false, 3),
            ("mbp14-open-1", HardwareNotch(width: 185, height: 32), true, 1),
            ("morespace-open-3", HardwareNotch(width: 152, height: 26), true, 3),
            ("air13-open-2", HardwareNotch(width: 178, height: 33), true, 2),
        ]
        for (name, notch, open, cells) in cases {
            let model = NotchViewModel()
            model.edge = .top
            model.accentColor = .blue
            model.surfaceStyle = .solid
            model.hardwareNotch = notch
            model.screenSize = CGSize(width: 1512, height: 982)
            model.snapshots = (0..<cells).map { i in
                ProviderSnapshot(id: "p\(i)", displayName: "P\(i)", glyph: [.claude, .openai, .grok][i % 3],
                                 fidelity: .official, status: .ok,
                                 windows: [LimitWindow(id: "w", label: "Session", usedFraction: 0.3 + 0.2 * Double(i))],
                                 headlineID: "w")
            }
            model.isExpanded = open
            model.isHoveringSettings = name.hasSuffix("-5")
            let size = model.panelSize
            let crop = CGSize(width: size.width, height: min(size.height, 160))
            let renderer = ImageRenderer(content:
                ZStack(alignment: .top) {
                    Color(white: 0.55)
                    NotchRootView(model: model).frame(width: size.width, height: size.height)
                }
                .frame(width: crop.width, height: crop.height, alignment: .top).clipped()
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, name)
            guard let dir else { continue }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("top-\(name).png"))
        }
    }
}
