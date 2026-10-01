import XCTest
import SwiftUI
@testable import LidEffort

/// Clicks every spot of a real, hosted prompt card and records which of
/// its controls answers — so a control that cannot be reached, or one
/// that answers for another, shows up as a map rather than a hunch.
@MainActor
final class PromptClickMapTests: XCTestCase {
    enum Hit: String { case allow = "A", always = "W", deny = "D", open = "O", dismiss = "X", none = "." }

    private func map(_ makeView: (@escaping (Hit) -> Void) -> AnyView, size: CGSize) -> [[Hit]] {
        var last: Hit = .none
        let host = NSHostingView(rootView: makeView { last = $0 })
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let step: CGFloat = 12
        var rows: [[Hit]] = []
        var y = size.height - step / 2
        while y > 0 {
            var row: [Hit] = []
            var x = step / 2
            while x < size.width {
                last = .none
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1)!
                    window.sendEvent(event)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                row.append(last)
                x += step
            }
            rows.append(row)
            y -= step
        }
        return rows
    }

    private func bash() throws -> PendingPrompt {
        var p = try XCTUnwrap(PendingPrompt(hookInput: Data(#"{"session_id":"s","cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"npm test"},"permission_suggestions":[{"type":"addRules"}]}"#.utf8)))
        p.sessionName = "nas-fix"
        return p
    }

    private func report(_ name: String, _ rows: [[Hit]]) -> Set<Hit> {
        if ProcessInfo.processInfo.environment["EFFORT_CLICK_MAP"] != nil {
            print("── \(name) ──\n" + rows.map { $0.map(\.rawValue).joined() }.joined(separator: "\n"))
        }
        return Set(rows.flatMap { $0 })
    }

    func testEveryControlOnTheFoldedCardIsReachable() throws {
        let prompt = try bash()
        let size = CGSize(width: NotchLayout.cardWidth + 40, height: PromptCard.cardHeight(for: prompt) + 20)
        let rows = map({ hit in
            AnyView(PromptCard(prompt: prompt, draft: .constant(PromptDraft(questions: [])), direction: .trailing,
                               onAnswer: { answer in
                                   switch answer { case .allow: hit(.allow); case .allowAlways: hit(.always); case .deny: hit(.deny); case .passThrough: hit(.dismiss); default: break }
                               },
                               onOpen: { hit(.open) })
                .environment(\.notchSurfaceStyle, .solid))
        }, size: size)
        let hits = report("folded card", rows)
        XCTAssertTrue(hits.isSuperset(of: [.allow, .always, .deny, .open, .dismiss]), "reached: \(hits.map(\.rawValue).sorted())")
        // A 16 pt Open was one spot on this 12 px grid, missed more often
        // than hit — and a miss lands nowhere, so Allow got pressed instead.
        XCTAssertGreaterThanOrEqual(rows.joined().filter { $0 == .open }.count, 4, "Open is big enough to hit")
        XCTAssertGreaterThanOrEqual(rows.joined().filter { $0 == .dismiss }.count, 4, "so is Dismiss")
    }

    func testEveryControlInTheTooltipPanelIsReachable() throws {
        let prompt = try bash()
        let size = CGSize(width: NotchLayout.cardWidth, height: PromptPanel.height(for: prompt) + 20)
        let rows = map({ hit in
            AnyView(PromptPanel(prompt: prompt, draft: .constant(PromptDraft(questions: [])),
                                onAnswer: { answer in
                                    switch answer { case .allow: hit(.allow); case .allowAlways: hit(.always); case .deny: hit(.deny); case .passThrough: hit(.dismiss); default: break }
                                },
                                onOpen: { hit(.open) }, namesSession: false)
                .padding(10)
                .environment(\.notchSurfaceStyle, .solid))
        }, size: size)
        let hits = report("tooltip panel", rows)
        XCTAssertTrue(hits.isSuperset(of: [.allow, .always, .deny, .open, .dismiss]), "reached: \(hits.map(\.rawValue).sorted())")
        // A 16 pt Open was one spot on this 12 px grid, missed more often
        // than hit — and a miss lands nowhere, so Allow got pressed instead.
        XCTAssertGreaterThanOrEqual(rows.joined().filter { $0 == .open }.count, 4, "Open is big enough to hit")
        XCTAssertGreaterThanOrEqual(rows.joined().filter { $0 == .dismiss }.count, 4, "so is Dismiss")
    }
}
