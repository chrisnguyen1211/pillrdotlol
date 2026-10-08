import XCTest
@testable import LidEffort

/// A right-click on a ring is about that agent; anywhere else on the notch,
/// it is the notch's own menu.
@MainActor
final class AgentMenuTests: XCTestCase {
    private func controller() -> NotchWindowController {
        let controller = NotchWindowController()
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        return controller
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }

    private func item(_ menu: NSMenu, _ title: String) throws -> ActionMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title } as? ActionMenuItem, "no “\(title)” in \(titles(menu))")
    }

    func testEachRingHasItsOwnMenu() throws {
        let controller = controller()
        let first = try XCTUnwrap(controller.agentMenu(for: 0))
        let second = try XCTUnwrap(controller.agentMenu(for: 1))
        let a = controller.model.snapshots[0].displayName, b = controller.model.snapshots[1].displayName
        XCTAssertTrue(first.items[0].title.hasPrefix(a))
        XCTAssertTrue(second.items[0].title.hasPrefix(b))
        XCTAssertTrue(titles(first).contains("Refresh \(a)"))
        XCTAssertTrue(titles(second).contains("Refresh \(b)"))
        // And the notch's own items are still there, underneath.
        XCTAssertTrue(titles(first).contains("Keep open"))
        XCTAssertTrue(titles(first).contains("Quit pillr"))
    }

    func testMovingAndHidingSayWhichAgent() throws {
        let controller = controller()
        var order: [String]?
        var hidden: String?
        controller.agentMenuActions = AgentMenuActions(hide: { hidden = $0 }, reorder: { order = $0 })
        let ids = controller.model.snapshots.map(\.id)

        let first = try XCTUnwrap(controller.agentMenu(for: 0))
        XCTAssertFalse(titles(first).contains("Move Up"), "the first ring has nowhere up to go")
        try item(first, "Move Down").performForTesting()
        XCTAssertEqual(order, [ids[1], ids[0]] + ids.dropFirst(2))

        let last = try XCTUnwrap(controller.agentMenu(for: ids.count - 1))
        XCTAssertFalse(titles(last).contains("Move Down"))
        let name = controller.model.snapshots[ids.count - 1].displayName
        try item(last, "Hide \(name) from the Pill").performForTesting()
        XCTAssertEqual(hidden, ids.last)
    }

    func testTheTopEdgeMovesLeftAndRight() throws {
        let controller = controller()
        controller.model.edge = .top
        let menu = try XCTUnwrap(controller.agentMenu(for: 1))
        XCTAssertTrue(titles(menu).contains("Move Left"))
        XCTAssertTrue(titles(menu).contains("Move Right"))
    }

    func testAlertsAndPageAreThatAgentsOwn() throws {
        let controller = controller()
        let id = controller.model.snapshots[0].providerID
        var muted: (String, Bool)?
        var opened: URL?
        let page = URL(string: "https://example.com/usage")!
        controller.agentMenuActions = AgentMenuActions(
            manageURL: { $0 == id ? page : nil },
            alertsMuted: { _ in true },
            setAlertsMuted: { muted = ($0, $1) },
            open: { opened = $0 }
        )
        let menu = try XCTUnwrap(controller.agentMenu(for: 0))
        let mute = try item(menu, "Mute Limit Alerts")
        XCTAssertEqual(mute.state, .on)
        mute.performForTesting()
        XCTAssertEqual(muted?.0, id)
        XCTAssertEqual(muted?.1, false, "a ticked mute unmutes")

        let name = controller.model.snapshots[0].displayName
        try item(menu, "Open \(name) Usage Page").performForTesting()
        XCTAssertEqual(opened, page)
        let other = try XCTUnwrap(controller.agentMenu(for: 1))
        XCTAssertFalse(titles(other).contains { $0.hasSuffix("Usage Page") }, "no page, no item")
    }

    func testEffortAndSessionsAreOffered() throws {
        let controller = controller()
        let snapshot = controller.model.snapshots[0]
        var effort = EffortState()
        let target = EffortState.targetID(forProviderID: snapshot.providerID)
        effort.values[target] = "high"
        effort.scales[target] = ["low", "medium", "high", "xhigh"]
        controller.model.effort = effort
        var set: (String, Int)?
        controller.model.onSetEffort = { set = ($0, $1) }
        var focused: pid_t?
        controller.model.onFocusSession = { focused = $0 }
        controller.model.sessions[snapshot.providerID] = [
            AgentSession(id: "a", name: "api-server", detail: "Terminal · api", state: .busy, waitingFor: nil, since: Date(), processID: 41),
            AgentSession(id: "b", name: "docs", detail: "Terminal · docs", state: .waiting, waitingFor: nil, since: Date(), processID: 42),
        ]

        let menu = try XCTUnwrap(controller.agentMenu(for: 0))
        let effortMenu = try XCTUnwrap(menu.items.first { $0.title == "Effort: high" }?.submenu)
        XCTAssertEqual(effortMenu.items.map(\.title), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(effortMenu.items[2].state, .on)
        try XCTUnwrap(effortMenu.items[3] as? ActionMenuItem).performForTesting()
        XCTAssertEqual(set?.0, snapshot.providerID)
        XCTAssertEqual(set?.1, 3)

        let sessions = try XCTUnwrap(menu.items.first { $0.title == "Sessions (2)" }?.submenu)
        XCTAssertEqual(sessions.items.map(\.title), ["docs · waiting on you", "api-server · working"], "the one waiting on you first")
        try XCTUnwrap(sessions.items[0] as? ActionMenuItem).performForTesting()
        XCTAssertEqual(focused, 42)
    }

    func testARightClickOnARingIsThatRingsAndElsewhereIsTheNotchs() throws {
        let controller = controller()
        let frame = try XCTUnwrap(controller.panelFrameForTesting)
        let model = controller.model
        let place = NotchPlacement(edge: model.edge, panelSize: frame.size)
        func ring(_ index: Int) -> CGPoint {
            let p = place.point(along: model.slack + model.ringCenter(index: index) * model.sizeScale,
                                across: model.restingDepth * model.sizeScale / 2)
            return CGPoint(x: p.x, y: frame.height - p.y)
        }
        let second = controller.contextMenu(at: ring(1))
        XCTAssertTrue(second.items[0].title.hasPrefix(model.snapshots[1].displayName), "\(titles(second))")
        let nowhere = controller.contextMenu(at: CGPoint(x: -500, y: -500))
        XCTAssertEqual(nowhere.items.first?.title, "Keep open")
        XCTAssertTrue(titles(nowhere).contains("Settings…"))
    }

    /// Another agent's sign-in does not belong in this one's menu — only in
    /// the notch's own.
    func testOtherAgentsSignInsStayOutOfItsMenu() throws {
        let controller = controller()
        controller.signInItems = [(title: "Sign in to DeepSeek…", action: {})]
        let menu = try XCTUnwrap(controller.agentMenu(for: 0))
        XCTAssertFalse(titles(menu).contains("Sign in to DeepSeek…"))
        XCTAssertTrue(titles(controller.contextMenu(at: CGPoint(x: -500, y: -500))).contains("Sign in to DeepSeek…"))
    }

    /// Under the name: whose account, each limit and when it resets.
    func testTheMenuSaysWhoseAndHowMuch() throws {
        let controller = controller()
        let snapshot = controller.model.snapshots[0]
        controller.agentMenuActions = AgentMenuActions(
            account: { _ in ProviderAccount(label: "me@example.com", plan: "max", source: "Claude Code", manageURL: nil) }
        )
        let menu = try XCTUnwrap(controller.agentMenu(for: 0))
        let info = menu.items.dropFirst().prefix { !$0.isSeparatorItem }
        XCTAssertEqual(info.first?.title, "me@example.com · Max")
        XCTAssertTrue(info.allSatisfy { !$0.isEnabled }, "information, not actions")
        let window = try XCTUnwrap(snapshot.windows.first { $0.usedFraction != nil })
        XCTAssertTrue(info.contains { $0.title.hasPrefix("\(window.label): \(Int(((window.usedFraction ?? 0) * 100).rounded()))%") },
                      "\(info.map(\.title))")
    }

    /// Its own account, where pillr can take you: its sign-in window — or,
    /// signed in, a switch — or the app that holds it.
    func testTheAccountItemFollowsWhereTheAccountLives() throws {
        let controller = controller()
        var opened: (String, Bool)?
        var signedIn = false
        var route = SignInRoute.modal(name: "DeepSeek")
        controller.agentMenuActions = AgentMenuActions(
            account: { _ in signedIn ? ProviderAccount(label: nil, plan: nil, source: "web", manageURL: nil) : nil },
            signInRoute: { _ in route },
            openAccountSource: { opened = ($0, $1) }
        )
        let id = controller.model.snapshots[0].providerID
        try item(try XCTUnwrap(controller.agentMenu(for: 0)), "Sign in to DeepSeek…").performForTesting()
        XCTAssertEqual(opened?.0, id)
        XCTAssertEqual(opened?.1, false)

        signedIn = true
        try item(try XCTUnwrap(controller.agentMenu(for: 0)), "Switch DeepSeek Account…").performForTesting()
        XCTAssertEqual(opened?.1, true)

        route = .openApp(bundleID: "com.todesktop.cursor", name: "Cursor")
        XCTAssertNoThrow(try item(try XCTUnwrap(controller.agentMenu(for: 0)), "Open Cursor"))
        route = .guidance("Run claude")
        let menu = try XCTUnwrap(controller.agentMenu(for: 0))
        XCTAssertFalse(titles(menu).contains { $0.hasPrefix("Open Cursor") || $0.hasPrefix("Sign in") })
    }

    func testMovingKeepsEveryoneElseInPlace() {
        XCTAssertEqual(NotchWindowController.moving(["a", "b", "c"], from: 1, by: 1), ["a", "c", "b"])
        XCTAssertEqual(NotchWindowController.moving(["a", "b", "c"], from: 0, by: -1), ["a", "b", "c"])
    }
}
