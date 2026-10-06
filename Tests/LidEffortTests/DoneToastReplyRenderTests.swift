import XCTest
import SwiftUI
@testable import LidEffort

/// The done card carries a Reply chip at the end of its status line.
@MainActor
final class DoneToastReplyRenderTests: XCTestCase {
    func testTheDoneCardOffersReply() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let session = AgentSession(id: "claude.\(pid)", name: "checkout-redesign", detail: "Terminal · shop-web",
                                   state: .success, waitingFor: nil, since: Date(), processID: pid)
        var toast = DoneToast(event: SessionCompletionWatcher.Event(session: session, reason: .finished, providerID: "claude"),
                              glyph: .claude)
        toast.changes = "3 files · +42 −7"
        // As on the right edge: the card, and the round Reply button just
        // past its end along the edge.
        let view = VStack(spacing: DoneToastView.replyBubbleGap) {
            DoneToastView(toast: toast, direction: .leading)
            ReplyBubble()
        }
        .environment(\.notchSurfaceStyle, .solid)
        .padding(20).background(Color(red: 0.12, green: 0.13, blue: 0.2))
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("done-card-reply.png"))
        }
    }
}
