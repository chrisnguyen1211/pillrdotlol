import XCTest
import SwiftUI
@testable import LidEffort

/// The cards' size, apart from the pill's.
@MainActor
final class CardScaleTests: XCTestCase {
    func testTheChoiceIsKeptAndKeptInRange() throws {
        let suite = "CardScaleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Preferences(defaults: defaults).cardScale, 1)
        Preferences(defaults: defaults).cardScale = 1.25
        XCTAssertEqual(Preferences(defaults: defaults).cardScale, 1.25)
        defaults.set(9.0, forKey: "cardScale")
        XCTAssertEqual(Preferences(defaults: defaults).cardScale, Preferences.cardScaleRange.upperBound)
    }

    private func controller(cardScale: CGFloat, notchScale: CGFloat = 1) -> NotchWindowController {
        let controller = NotchWindowController()
        controller.isFullScreenActive = { false }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.apply(scale: notchScale)
        controller.apply(cardScale: cardScale)
        controller.relocate()
        controller.model.isExpanded = true
        controller.model.hoveredIndex = 0
        return controller
    }

    func testTheTooltipsTargetGrowsWithItAndStaysInsideThePanel() throws {
        let normal = controller(cardScale: 1)
        let large = controller(cardScale: 1.3)
        let a = try XCTUnwrap(normal.tooltipRectForTesting(index: 0))
        let b = try XCTUnwrap(large.tooltipRectForTesting(index: 0))
        // Across the edge: gap + tail + card; along it: the card.
        XCTAssertGreaterThan(b.width, a.width * 1.2)
        XCTAssertGreaterThan(b.height, a.height * 1.2)
        let panel = try XCTUnwrap(large.panelFrameForTesting)
        XCTAssertTrue(CGRect(origin: .zero, size: panel.size).insetBy(dx: -1, dy: -1).contains(b),
                      "the panel grew to hold the larger card")
    }

    func testThePillSizeLeavesTheCardsAlone() throws {
        let small = controller(cardScale: 1, notchScale: 0.8)
        let large = controller(cardScale: 1, notchScale: 1.25)
        let a = try XCTUnwrap(small.tooltipRectForTesting(index: 0))
        let b = try XCTUnwrap(large.tooltipRectForTesting(index: 0))
        // Right edge: the card's extent along the edge is its height, across
        // it the card's width — neither depends on the pill.
        XCTAssertEqual(a.height, b.height, accuracy: 0.5)
        XCTAssertEqual(a.width, b.width, accuracy: 0.5)
    }

    func testTheAnswerFieldStillTakesTypingOnALargerCard() throws {
        let prompt = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Colour?","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}]}]}}"#.utf8)))
        final class Box { var draft: PromptDraft; init(_ d: PromptDraft) { draft = d } }
        let box = Box(PromptDraft(questions: prompt.questions))
        let scale: CGFloat = 1.3
        let card = CGSize(width: NotchLayout.cardWidth + 40, height: PromptCard.cardHeight(for: prompt) + 20)
        let size = CGSize(width: card.width * scale + 20, height: card.height * scale + 20)
        let panel = NotchPanel(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height))
        panel.acceptsKeyboard = true
        let host = NotchHostingView(rootView: AnyView(
            PromptCard(prompt: prompt, draft: Binding(get: { box.draft }, set: { box.draft = $0 }),
                       onAnswer: { _ in }, onOpen: {})
                .environment(\.notchSurfaceStyle, .solid)
                .scaleEffect(scale)
                .frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        host.interactiveRects = [CGRect(origin: .zero, size: size)]
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        var focused = false
        var y: CGFloat = 20
        while y < size.height * 0.6, !focused {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                panel.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: size.width / 2, y: y), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            focused = panel.firstResponder is NSTextView
            y += 6
        }
        XCTAssertTrue(focused, "the field is still reachable at 130%")
        (panel.firstResponder as? NSTextView)?.insertText("Teal", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(box.draft.customText(for: prompt.questions[0]), "Teal")
    }

    func testRenderTheNotchWithSmallAndLargeTooltips() throws {
        for scale: CGFloat in [0.9, 1.2] {
            let model = NotchViewModel()
            model.updateSnapshots(Fixtures.snapshots())
            model.cardScale = scale
            model.isExpanded = true
            model.hoveredIndex = 0
            let size = model.panelSize
            let host = NSHostingView(rootView: AnyView(NotchRootView(model: model)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.3))
                .environment(\.notchSurfaceStyle, .solid)
                .environment(\.colorScheme, .dark)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("card-scale-\(Int(scale * 100)).png"))
            }
        }
    }
}
