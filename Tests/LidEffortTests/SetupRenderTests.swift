import XCTest
import SwiftUI
@testable import LidEffort

/// Every setup page laid out in an offscreen window, for a look:
/// `EFFORT_RENDER_DIR=… swift test --filter SetupRenderTests`.
@MainActor
final class SetupRenderTests: XCTestCase {
    func testEveryPageRenders() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "setup-render-\(UUID())"))
        let model = SetupModel(preferences: Preferences(defaults: defaults), store: nil, effort: { nil })
        for step in model.plan.steps {
            model.go(to: step)
            let host = NSHostingView(rootView: SetupAssistantView(model: model, finish: {}, openSettings: {}))
            let frame = NSRect(x: 0, y: 0, width: SetupAssistantView.width, height: SetupAssistantView.height)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("setup-\(step.rawValue).png"))
        }
    }
}
