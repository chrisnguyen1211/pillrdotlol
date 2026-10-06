import XCTest
import SwiftUI
@testable import LidEffort

/// The orb reply lays out, and a look at it: `EFFORT_RENDER_DIR=… swift test --filter OrbReplyRenderTests`.
@MainActor
final class OrbReplyRenderTests: XCTestCase {
    private func write(_ view: some View, _ name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testThePillRenders() throws {
        let session = AgentSession(id: "grok.01a0", name: "shop-redesign", detail: "", state: .idle, waitingFor: nil, since: Date())
        try write(OrbReplyView(session: session, reach: .terminal(tty: "ttys000"), onClose: {})
            .background(Color(red: 0.12, green: 0.13, blue: 0.2)), "orb-reply-pill.png")
    }
}
