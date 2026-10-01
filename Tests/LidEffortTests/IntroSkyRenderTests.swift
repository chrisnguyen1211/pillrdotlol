import XCTest
import SwiftUI
@testable import LidEffort

/// Frames of the intro over its sky, for looking at: written out only when
/// EFFORT_RENDER_DIR is set.
@MainActor
final class IntroSkyRenderTests: XCTestCase {
    func testRenderIntroFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] else { throw XCTSkip("set EFFORT_RENDER_DIR") }
        let size = CGSize(width: 1440, height: 900)
        let target = CGRect(x: 1426, y: 410, width: 10, height: 80)
        for (name, t) in [("0-in", 0.9), ("1-drops", 2.4), ("2-name", IntroTimeline.strike + 1.2), ("3-fly", IntroTimeline.flyFrom + 0.6), ("4-land", IntroTimeline.flyTo - 0.1)] {
            let renderer = ImageRenderer(content: ZStack {
                // A stand-in desktop, where the real one would be.
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.4)], startPoint: .top, endPoint: .bottom)
                PixelSkyView(t: t, size: size, blur: 5).opacity(0) // warms the cache off the clock
                IntroFrame(t: t, size: size, target: target, agents: [.claude, .openai, .grok], showsBackdrop: false)
                    .background(IntroSkyOnly(t: t, size: size))
            }.frame(width: size.width, height: size.height))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("intro-sky-\(name).png"))
        }
    }
}

/// The intro's sky on its own, with its own timing — `IntroFrame` minus the
/// desktop blur an image renderer cannot draw.
private struct IntroSkyOnly: View {
    let t: Double
    let size: CGSize
    var body: some View {
        let skyIn = GlassTour.smooth(0.15, 1.7, t)
        let skyOut = GlassTour.smooth(IntroTimeline.flyFrom - 0.35, IntroTimeline.flyTo + 0.05, t)
        PixelSkyView(t: t, size: size, blur: 5 + 24 * CGFloat(1 - skyIn) + 24 * CGFloat(skyOut))
            .scaleEffect(1.06 - 0.06 * skyIn + 0.04 * skyOut)
            .opacity(skyIn * (1 - skyOut))
    }
}
