import XCTest
import SwiftUI
@testable import LidEffort

/// An agent that is not signed in gets a Connect button, not an effort bar.
@MainActor
final class ConnectNeedTests: XCTestCase {
    private let codexApp = SignInRoute.openApp(bundleID: "com.openai.codex", name: "Codex")

    func testAnExpiredAgentWithItsAppInstalledOffersToOpenIt() {
        let need = ConnectNeed.need(status: .stale(since: Date()), expired: true, route: codexApp,
                                    command: "codex login", appInstalled: { _ in true })
        XCTAssertEqual(need?.reason, "Sign-in expired")
        XCTAssertEqual(need?.buttonTitle, "Open Codex")
        XCTAssertEqual(need?.action, .openApp)
    }

    func testWithoutTheAppItRunsTheSignInCommand() {
        let need = ConnectNeed.need(status: .needsAuth, expired: false, route: codexApp,
                                    command: "codex login", appInstalled: { _ in false })
        XCTAssertEqual(need?.reason, "Not signed in")
        XCTAssertEqual(need?.action, .terminal("codex login"))
        XCTAssertEqual(need?.buttonTitle, "Sign in in Terminal")
    }

    func testACommandLineAgentSignsInFromTerminal() {
        let need = ConnectNeed.need(status: .signedOutByOwner, expired: false,
                                    route: .guidance("Run grok login"), command: "grok login", appInstalled: { _ in true })
        XCTAssertEqual(need?.action, .terminal("grok login"))
    }

    func testMacOSRefusingIsAnsweredWithAllowAccess() {
        let need = ConnectNeed.need(status: .accessDenied, expired: false, route: .guidance("x"), command: "claude", appInstalled: { _ in true })
        XCTAssertEqual(need?.action, .allowAccess)
    }

    func testASignedInAgentNeedsNothing() {
        XCTAssertNil(ConnectNeed.need(status: .ok, expired: false, route: codexApp, command: nil, appInstalled: { _ in true }))
        XCTAssertNil(ConnectNeed.need(status: .stale(since: Date()), expired: false, route: codexApp, command: nil, appInstalled: { _ in true }),
                     "merely old is not signed out")
    }

    func testNothingToRunOrOpenFallsBackToSettings() {
        let need = ConnectNeed.need(status: .needsAuth, expired: false, route: .guidance("Ask your admin"), command: nil, appInstalled: { _ in true })
        XCTAssertEqual(need?.action, .settings)
    }

    func testTheEffortBarGivesWayToTheConnectRow() throws {
        let model = NotchViewModel()
        model.updateSnapshots(Fixtures.snapshots())
        let snapshot = try XCTUnwrap(model.snapshots.first)
        model.connectNeeds = [snapshot.id: ConnectNeed(reason: "Sign-in expired", buttonTitle: "Open Codex", action: .openApp)]
        XCTAssertNil(model.effortValue(for: snapshot), "no bar for an agent that is not signed in")
        XCTAssertTrue(model.hasEffortRow(for: snapshot), "the well stays, so the card keeps its height")
    }

    func testRenderTheConnectRow() throws {
        let card = TooltipCard(
            snapshot: ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official,
                                       status: .stale(since: Date().addingTimeInterval(-3600)),
                                       windows: [LimitWindow(id: "s", label: "5-hour limit", usedFraction: 0.42)]),
            now: Date(),
            connect: ConnectNeed(reason: "Sign-in expired", buttonTitle: "Open Codex", action: .openApp))
        let view = card.padding(20).background(Color(white: 0.2))
            .environment(\.notchSurfaceStyle, .solid).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("connect-row.png"))
        }
    }
}
