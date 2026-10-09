import XCTest
import SwiftUI
@testable import LidEffort

/// The cards' text against what shows through their glass: a prompt card
/// and a usage card, light and dark, over a white app window and a black
/// one, with the glass seeing the window and with the blur that stands in
/// for it, and with Reduce Transparency.
///
/// `EFFORT_RENDER_SCREEN=1 EFFORT_RENDER_DIR=/tmp/x swift test --filter
/// CardLegibilityRenderTests` puts them on screen for a moment, writes what
/// came out, and measures the secondary line's contrast on each.
@MainActor
final class CardLegibilityRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Without a screen: the inks on the grounds they were picked for. The
    /// solid style's black and a white card keep their old contrast.
    func testTheSecondaryInkOnItsOwnGrounds() {
        XCTAssertEqual(Contrast.ratio(Contrast.ink(Palette.secondaryInkDark, over: 0), 0), 10.54, accuracy: 0.05)
        XCTAssertEqual(Contrast.ratio(Contrast.ink(Palette.secondaryInkLight, over: 1), 1), 9.23, accuracy: 0.05)
    }

    /// Something like an app window: a plain page with lines of text on it.
    private struct Backdrop: View {
        let light: Bool
        var body: some View {
            let page = light ? Color.white : Color(white: 0.09)
            let ink = light ? Color(white: 0.25) : Color(white: 0.85)
            ZStack(alignment: .topLeading) {
                page
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<40, id: \.self) { i in
                        Text(String(repeating: "lorem ipsum dolor sit amet ", count: 4))
                            .font(.system(size: 12, weight: i % 7 == 0 ? .bold : .regular))
                            .foregroundStyle(i % 5 == 0 ? Color.accentColor : ink)
                            .lineLimit(1)
                    }
                }
                .padding(14)
            }
        }
    }

    private func cards() throws -> some View {
        let bash = try XCTUnwrap(PendingPrompt(hookInput: Data(PendingPromptTests.bash.utf8), now: now))
        let sessions: [AgentSession] = (0..<3).map { i in
            AgentSession(id: "s\(i)", name: i == 0 ? "effort-lid-3c" : "session-\(i)", detail: "Terminal · project",
                         state: i == 0 ? .busy : .idle, waitingFor: nil, since: now.addingTimeInterval(-Double(i) * 900))
        }
        let snapshot = ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                        status: .ok, windows: [LimitWindow(id: "s", label: "Current session", usedFraction: 0.29)])
        return HStack(alignment: .top, spacing: 24) {
            PromptCard(prompt: bash, draft: .constant(PromptDraft(questions: bash.questions)),
                       direction: .trailing, onAnswer: { _ in }, onOpen: {})
            TooltipCard(snapshot: snapshot, activity: ActivitySummary(sessions: sessions), now: now, sessionCap: 3)
        }
        .padding(24)
        .environment(\.drawsFieldsAsText, true)
    }

    /// The cards in a panel like the notch's (borderless, clear, no
    /// shadow) over a separate "app" window, both put on screen for a
    /// moment and captured together: only the window server draws Liquid
    /// Glass and the blur behind a window, and an offscreen capture shows
    /// neither. Done only when asked for (`EFFORT_RENDER_SCREEN=1`), since
    /// it puts two windows over whatever is on the screen.
    private func screenSnapshot(_ view: some View, name: String, dark: Bool, lightBehind: Bool) throws -> NSBitmapImageRep? {
        guard ProcessInfo.processInfo.environment["EFFORT_RENDER_SCREEN"] == "1",
              let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
              let screen = NSScreen.screens.first else { return nil }
        let size = CGSize(width: 2 * NotchLayout.cardWidth + 2 * NotchLayout.tailLength + 100, height: 520)
        let origin = CGPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: (screen.frame.midY - size.height / 2).rounded())
        let rect = CGRect(origin: origin, size: size)

        let app = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        app.contentView = NSHostingView(rootView: Backdrop(light: lightBehind).frame(width: size.width, height: size.height))
        app.level = .screenSaver
        let panel = NotchPanel(contentRect: rect)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading)))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        app.orderFrontRegardless()
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); app.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        // `screencapture` counts from the top of the main display.
        let top = screen.frame.maxY - rect.maxY
        let file = URL(fileURLWithPath: dir).appendingPathComponent(name)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(top)),\(Int(size.width)),\(Int(size.height))", file.path]
        try capture.run()
        capture.waitUntilExit()
        guard let data = try? Data(contentsOf: file) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    func testTheCardsOverALightAndADarkWindow() throws {
        for dark in [false, true] {
            for lightBehind in [true, false] {
                for sees in [true, false] {
                    let view = try cards()
                        .environment(\.notchSurfaceStyle, .glass)
                        .environment(\.cardGlassSeesBehind, sees)
                    let name = "legibility-\(dark ? "dark" : "light")-over-\(lightBehind ? "light" : "dark")\(sees ? "" : "-blur").png"
                    guard let rep = try screenSnapshot(view, name: name, dark: dark, lightBehind: lightBehind) else { continue }
                    assertReadable(rep, dark: dark, name)
                }
            }
        }
        // Reduce Transparency: the solid card, whatever is behind.
        let solid = try cards()
            .environment(\.notchSurfaceStyle, .glass)
            .environment(\.notchReduceTransparency, true)
        if let rep = try screenSnapshot(solid, name: "legibility-reduce-transparency.png", dark: true, lightBehind: true) {
            assertReadable(rep, dark: true, "reduce transparency")
        }
    }

    /// Patches of each card with no text on them, in points from the top
    /// left of the capture: beside "Run tests" on the prompt card, and
    /// beside "Current session" on the usage card.
    private static let blankPatches = [CGRect(x: 130, y: 88, width: 80, height: 10),
                                       CGRect(x: 400, y: 62, width: 100, height: 10)]

    /// The secondary ink, laid over the card as it came out, against the
    /// card: at least 4.5:1, the body-text minimum, and the primary ink
    /// well above that.
    private func assertReadable(_ rep: NSBitmapImageRep, dark: Bool, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let scale = CGFloat(rep.pixelsWide) / (2 * NotchLayout.cardWidth + 2 * NotchLayout.tailLength + 100)
        for patch in Self.blankPatches {
            var samples: [Double] = []
            for y in stride(from: patch.minY, to: patch.maxY, by: 2) {
                for x in stride(from: patch.minX, to: patch.maxX, by: 2) {
                    guard let colour = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                    samples.append(Contrast.luminance(colour))
                }
            }
            guard !samples.isEmpty else { continue }
            // The lightest of the card in dark, the darkest in light: the
            // worst place for the ink in each.
            let ground = dark ? samples.max()! : samples.min()!
            let secondary = Contrast.ratio(Contrast.ink(dark ? Palette.secondaryInkDark : Palette.secondaryInkLight, over: ground), ground)
            let primary = Contrast.ratio(dark ? 1 : 0, ground)
            print("legibility \(name) patch \(patch.minX): ground \(String(format: "%.3f", ground)) secondary \(String(format: "%.2f", secondary)):1 primary \(String(format: "%.2f", primary)):1")
            // The glass is kept: over a white window, the worst case, the
            // secondary line is allowed down to 3.8:1 and primary to 4.5:1.
            XCTAssertGreaterThanOrEqual(secondary, 3.8, "\(name): secondary text on the card", file: file, line: line)
            XCTAssertGreaterThanOrEqual(primary, 4.5, "\(name): primary text on the card", file: file, line: line)
        }
    }
}

/// WCAG relative luminance and contrast, on grey levels.
enum Contrast {
    static func luminance(_ colour: NSColor) -> Double {
        0.2126 * linear(colour.redComponent) + 0.7152 * linear(colour.greenComponent) + 0.0722 * linear(colour.blueComponent)
    }

    static func linear(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// The luminance of a grey ink, translucent or not, laid over a ground
    /// of the given luminance: blended as the screen blends it, in sRGB.
    static func ink(_ ink: NSColor, over ground: Double) -> Double {
        let ink = ink.usingColorSpace(.sRGB)!
        let groundLevel = ground <= 0.0031308 ? ground * 12.92 : 1.055 * pow(ground, 1 / 2.4) - 0.055
        let level = Double(ink.alphaComponent) * Double(ink.redComponent) + (1 - Double(ink.alphaComponent)) * groundLevel
        return linear(CGFloat(level))
    }

    static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
