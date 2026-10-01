import XCTest
import SwiftUI
@testable import LidEffort

/// Hover inside the notch comes from the controller's own pointer
/// tracking, not from SwiftUI's — which the panel mostly never hears.
@MainActor
final class NotchHoverTests: XCTestCase {
    func testAViewHearsThePointerComeAndGo() throws {
        let pointer = NotchPointer()
        final class Log { var events: [Bool] = [] }
        let log = Log()
        let host = NSHostingView(rootView: AnyView(
            VStack(spacing: 0) {
                Color.clear.frame(width: 200, height: 50)
                Color.red.frame(width: 200, height: 50).notchHover { log.events.append($0) }
            }
            .environment(\.notchPointer, pointer)))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        pointer.move(to: CGPoint(x: 100, y: 20))          // over the top half
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(log.events, [])
        pointer.move(to: CGPoint(x: 100, y: 75))          // onto the red one
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(log.events, [true])
        pointer.move(to: CGPoint(x: 120, y: 80))          // moving within it says nothing new
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(log.events, [true])
        pointer.move(to: nil)                             // off the notch altogether
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(log.events, [true, false])
    }

    func testTheControllerOnlyPassesThePointerOnOverWhatItDraws() throws {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { false }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.model.isExpanded = true
        controller.model.hoveredIndex = 0

        let over = controller.cellPointForTesting(index: 0)
        controller.pointerMovedForTesting(toLocal: over)
        XCTAssertEqual(controller.pointer.location, over)
        controller.pointerMovedForTesting(toLocal: CGPoint(x: -4000, y: -4000))
        XCTAssertNil(controller.pointer.location)
    }
}

@MainActor
final class HoverLiftRenderTests: XCTestCase {
    func testTheHoveredSessionComesForward() throws {
        let now = Date()
        let sessions = [
            AgentSession(id: "a", name: "pill-lid", detail: "Terminal · pill-lid", state: .busy, waitingFor: nil, since: now, processID: 1),
            AgentSession(id: "b", name: "nas-fix", detail: "Terminal · nas-fix", state: .idle, waitingFor: nil, since: now.addingTimeInterval(-2340), processID: 2),
            AgentSession(id: "c", name: "abundance", detail: "Terminal · abundance", state: .idle, waitingFor: nil, since: now.addingTimeInterval(-3120), processID: 3),
        ]
        let pointer = NotchPointer()
        let card = TooltipCard(
            snapshot: ProviderSnapshot(id: "claude", displayName: "Claude", glyph: .claude, fidelity: .official,
                                       status: .ok, windows: [LimitWindow(id: "s", label: "Current session", usedFraction: 0.29)]),
            activity: ActivitySummary(sessions: sessions), now: now, sessionCap: 3)
        let size = CGSize(width: NotchLayout.cardWidth + 60, height: 520)
        let host = NSHostingView(rootView: AnyView(
            card.padding(20).frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(white: 0.2))
                .environment(\.notchSurfaceStyle, .solid)
                .environment(\.notchPointer, pointer)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // Onto the second session, "nas-fix".
        pointer.move(to: CGPoint(x: size.width / 2, y: 180))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("session-hover.png"))
        }
    }
}

@MainActor
final class PointingHandTests: XCTestCase {
    func testAnOpenableRowAsksForTheHandOnlyWhileThePointerIsOnIt() throws {
        let pointer = NotchPointer()
        let host = NSHostingView(rootView: AnyView(
            VStack(spacing: 0) {
                Color.clear.frame(width: 200, height: 50).hoverLift(pointingHand: false)
                Color.clear.frame(width: 200, height: 50).hoverLift(pointingHand: true)
            }
            .environment(\.notchPointer, pointer)))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        pointer.move(to: CGPoint(x: 100, y: 25))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(pointer.hands.isEmpty, "a row that opens nothing is no link")
        pointer.move(to: CGPoint(x: 100, y: 75))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(pointer.hands.count, 1)
        pointer.move(to: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(pointer.hands.isEmpty)
    }

    func testAWorkingLogoBreathesFromFullToDimAndBack() {
        let t0 = 1000 * Breathing.period
        XCTAssertEqual(Breathing.opacity(at: t0), 1, accuracy: 1e-6)
        XCTAssertEqual(Breathing.opacity(at: t0 + Breathing.period / 2), Breathing.low, accuracy: 1e-6)
        XCTAssertEqual(Breathing.opacity(at: t0 + Breathing.period), 1, accuracy: 1e-6)
    }
}

@MainActor
final class BreathingRingRenderTests: XCTestCase {
    func testTheWorkingRingDrawsNoDots() throws {
        let busy = ActivitySummary(sessions: [AgentSession(id: "a", name: "a", detail: "", state: .busy, waitingFor: nil, since: Date())])
        let size = CGSize(width: 260, height: 120)
        let host = NSHostingView(rootView: AnyView(
            HStack(spacing: 30) {
                ProviderRing(usedFraction: 0.42, glyph: .claude, activity: busy)
                ProviderRing(usedFraction: 0.8, glyph: .openai, activity: busy)
            }
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("ring-breathing.png"))
        }
    }
}
