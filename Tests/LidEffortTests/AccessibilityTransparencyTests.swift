import SwiftUI
import XCTest
@testable import LidEffort

@MainActor
final class AccessibilityTransparencyTests: XCTestCase {
    private func session(_ name: String, _ state: AgentSession.State) -> AgentSession {
        AgentSession(
            id: name,
            name: name,
            detail: "Terminal · test",
            state: state,
            waitingFor: state == .waiting ? "your answer" : nil,
            since: Date()
        )
    }

    func testEnvironmentValueCanBeOverridden() {
        var values = EnvironmentValues()
        XCTAssertFalse(values.notchReduceTransparency)
        values.notchReduceTransparency = true
        XCTAssertTrue(values.notchReduceTransparency)
    }

    func testProviderRingRendersUnderStandardAndReducedTransparency() throws {
        let normalRing = ProviderRing(usedFraction: 0.5, glyph: .claude)
            .environment(\.notchReduceTransparency, false)
            .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

        let reducedRing = ProviderRing(usedFraction: 0.5, glyph: .claude)
            .environment(\.notchReduceTransparency, true)
            .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

        let normalRenderer = ImageRenderer(content: normalRing)
        let reducedRenderer = ImageRenderer(content: reducedRing)

        let normalImage = try XCTUnwrap(normalRenderer.nsImage)
        let reducedImage = try XCTUnwrap(reducedRenderer.nsImage)

        XCTAssertEqual(normalImage.size.width, NotchLayout.ringDiameter)
        XCTAssertEqual(reducedImage.size.width, NotchLayout.ringDiameter)
    }

    func testExhaustedAndStaleProviderRingsRenderUnderReducedTransparency() throws {
        let staleExhaustedRing = ProviderRing(
            usedFraction: 1.0,
            glyph: .cursor,
            isStale: true,
            isBlocked: true,
            activity: ActivitySummary(sessions: [session("s1", .waiting)])
        )
        .environment(\.notchReduceTransparency, true)
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)

        let renderer = ImageRenderer(content: staleExhaustedRing)
        let image = try XCTUnwrap(renderer.nsImage)

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testTooltipCardRendersUnderReducedTransparency() throws {
        let snapshot = ProviderSnapshot(
            id: "claude",
            displayName: "Claude",
            glyph: .claude,
            fidelity: .official,
            status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.6)]
        )
        let activity = ActivitySummary(sessions: [
            session("session-1", .busy),
            session("session-2", .idle)
        ])

        let standardCard = TooltipCard(snapshot: snapshot, activity: activity, now: Date())
            .environment(\.notchReduceTransparency, false)
            .padding(10)

        let reducedCard = TooltipCard(snapshot: snapshot, activity: activity, now: Date())
            .environment(\.notchReduceTransparency, true)
            .padding(10)

        let standardRenderer = ImageRenderer(content: standardCard)
        let reducedRenderer = ImageRenderer(content: reducedCard)

        let standardImage = try XCTUnwrap(standardRenderer.nsImage)
        let reducedImage = try XCTUnwrap(reducedRenderer.nsImage)

        XCTAssertGreaterThan(standardImage.size.height, NotchLayout.cardWidth * 0.4)
        XCTAssertGreaterThan(reducedImage.size.height, NotchLayout.cardWidth * 0.4)
    }

    func testSettingsViewRendersUnderReducedTransparency() throws {
        let defaults = UserDefaults(suiteName: "AccessibilityTransparencyTests.\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        let updater = Updater()

        let view = SettingsView(
            preferences: preferences,
            providers: { [] },
            signOut: { _ in },
            signIn: { _ in false },
            switchAccount: { _ in false },
            retry: { _ in },
            resetPosition: {},
            quit: {},
            updater: updater
        )
        .environment(\.notchReduceTransparency, true)
        .frame(width: SettingsView.width, height: SettingsView.height)

        let renderer = ImageRenderer(content: view)
        let image = try XCTUnwrap(renderer.nsImage)

        XCTAssertEqual(image.size.width, SettingsView.width)
        XCTAssertEqual(image.size.height, SettingsView.height)
    }
}
