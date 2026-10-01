import AppKit

/// What a ring's own right-click menu can do that the notch cannot do on
/// its own — its account page, its alerts, its place on the pill. Supplied
/// by the app delegate, through the fleet; the defaults do nothing, so a
/// notch with none of it wired (the tests, a demo) still has a menu.
struct AgentMenuActions {
    /// The agent's own page for its usage or account, if it has one.
    var manageURL: (String) -> URL? = { _ in nil }
    var alertsMuted: (String) -> Bool = { _ in false }
    var setAlertsMuted: (String, Bool) -> Void = { _, _ in }
    /// Takes the ring off the pill. Settings → Accounts brings it back.
    var hide: (String) -> Void = { _ in }
    /// The rings, by id, in the order they should now stand.
    var reorder: ([String]) -> Void = { _ in }
    /// Opens a page, in the browser.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Whose readings these are: the account the agent's credential belongs to.
    var account: (String) -> ProviderAccount? = { _ in nil }
    /// Where this agent's account lives: its own sign-in window, an app, or nowhere spyx can open.
    var signInRoute: (String) -> SignInRoute? = { _ in nil }
    /// Takes you there — to sign in, or with `true`, to switch account.
    var openAccountSource: (String, Bool) -> Void = { _, _ in }
}

/// A menu item that runs a closure. `NSMenuItem` wants an Objective-C
/// target and selector; this is its own target, and the menu holds it.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func fire(_ sender: Any?) { handler() }

    /// For the tests: what choosing it does.
    func performForTesting() { handler() }
}

extension NotchWindowController {
    /// The menu for one ring: that agent's own things first — refresh it,
    /// its page, its effort, its sessions, its alerts, its place — and the
    /// notch's own below, so nothing the plain menu offers is lost.
    func agentMenu(for index: Int) -> NSMenu? {
        guard model.snapshots.indices.contains(index) else { return nil }
        let snapshot = model.snapshots[index]
        let name = snapshot.displayName
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(.sectionHeader(title: name))
        for line in infoLines(for: snapshot) { menu.addItem(Self.info(line)) }
        menu.addItem(.separator())

        if let need = model.connectNeed(for: snapshot) {
            let connect = ActionMenuItem(L10n.t("\(need.buttonTitle)…")) { [weak self] in
                self?.model.onConnect?(snapshot.id)
            }
            connect.toolTip = need.reason
            menu.addItem(connect)
        }

        menu.addItem(ActionMenuItem(L10n.t("Refresh \(name)"), key: "r") { [weak self] in
            guard let self, let refresh = self.onRefreshProvider else { return }
            Task { await self.model.refresh(snapshot, using: refresh) }
        })

        if let account = accountItem(for: snapshot) { menu.addItem(account) }
        if let url = agentMenuActions.manageURL(snapshot.providerID) {
            menu.addItem(ActionMenuItem(L10n.t("Open \(name) Usage Page")) { [weak self] in
                self?.agentMenuActions.open(url)
            })
        }

        if let effort = effortSubmenu(for: snapshot) { menu.addItem(effort) }
        if let sessions = sessionsSubmenu(for: snapshot) { menu.addItem(sessions) }

        menu.addItem(.separator())

        // Local models have no limits to be warned about.
        if snapshot.localModel == nil {
            let muted = agentMenuActions.alertsMuted(snapshot.providerID)
            menu.addItem(ActionMenuItem(L10n.t("Mute Limit Alerts"), checked: muted) { [weak self] in
                self?.agentMenuActions.setAlertsMuted(snapshot.providerID, !muted)
            })
        }

        let ids = model.snapshots.map(\.id)
        let vertical = model.edge.isVertical
        if index > 0 {
            menu.addItem(ActionMenuItem(vertical ? L10n.t("Move Up") : L10n.t("Move Left")) { [weak self] in
                self?.agentMenuActions.reorder(Self.moving(ids, from: index, by: -1))
            })
        }
        if index < ids.count - 1 {
            menu.addItem(ActionMenuItem(vertical ? L10n.t("Move Down") : L10n.t("Move Right")) { [weak self] in
                self?.agentMenuActions.reorder(Self.moving(ids, from: index, by: 1))
            })
        }
        menu.addItem(ActionMenuItem(L10n.t("Hide \(name) from the Pill")) { [weak self] in
            self?.agentMenuActions.hide(snapshot.id)
        })

        menu.addItem(.separator())
        // The notch's own items, but not the other agents' sign-ins: those
        // are in their own menus, and in the notch's.
        for item in generalMenuItems(signIns: false) { menu.addItem(item) }
        return menu
    }

    /// Greyed lines under the name: whose account, each limit and when it
    /// resets, and how old the reading is if it is not live.
    func infoLines(for snapshot: ProviderSnapshot) -> [String] {
        var lines: [String] = []
        if let local = snapshot.localModel {
            lines.append(local.name)
            return lines
        }
        let account = agentMenuActions.account(snapshot.providerID)
        let who = [account?.label, (account?.plan ?? snapshot.plan).map { $0.capitalized }].compactMap { $0 }
        if !who.isEmpty { lines.append(who.joined(separator: " · ")) }
        for window in snapshot.windows.prefix(3) {
            guard let used = window.usedFraction else { continue }
            let percent = Int((used * 100).rounded())
            let reset = window.resetsAt.map {
                ResetCopy.text(for: $0, now: model.now, format: model.resetTimeFormat)
            } ?? ""
            lines.append(reset.isEmpty ? L10n.t("\(window.label): \(percent)%")
                                       : L10n.t("\(window.label): \(percent)% · \(reset)"))
        }
        if let since = snapshot.status.staleSince, since != .distantPast {
            lines.append(L10n.t("Updated \(ElapsedCopy.ago(since: since, now: model.now))"))
        }
        return lines
    }

    private static func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Where the agent's account lives, when spyx can take you there: its
    /// own sign-in window — to sign in, or switch account once signed in —
    /// or the app that holds it. Claude Code is a command; nothing to open.
    private func accountItem(for snapshot: ProviderSnapshot) -> NSMenuItem? {
        guard snapshot.localModel == nil, model.connectNeed(for: snapshot) == nil,
              let route = agentMenuActions.signInRoute(snapshot.providerID) else { return nil }
        let id = snapshot.providerID
        let signedIn = agentMenuActions.account(id) != nil
        switch route {
        case .modal(let name):
            let title = signedIn ? L10n.t("Switch \(name) Account…") : L10n.t("Sign in to \(name)…")
            return ActionMenuItem(title) { [weak self] in self?.agentMenuActions.openAccountSource(id, signedIn) }
        case .openApp(_, let name):
            return ActionMenuItem(L10n.t("Open \(name)")) { [weak self] in self?.agentMenuActions.openAccountSource(id, false) }
        case .guidance:
            return nil
        }
    }

    /// The ids with one moved a place along, the rest in order.
    static func moving(_ ids: [String], from index: Int, by step: Int) -> [String] {
        let target = index + step
        guard ids.indices.contains(index), ids.indices.contains(target) else { return ids }
        var moved = ids
        moved.swapAt(index, target)
        return moved
    }

    /// The agent's effort scale, its current value ticked; choosing one
    /// writes it, the same as letting go of the tooltip's bar there.
    private func effortSubmenu(for snapshot: ProviderSnapshot) -> NSMenuItem? {
        guard snapshot.localModel == nil, model.connectNeed(for: snapshot) == nil,
              let effort = model.effort,
              let scale = effort.scales[EffortState.targetID(forProviderID: snapshot.providerID)], !scale.isEmpty
        else { return nil }
        let current = effort.value(forProviderID: snapshot.providerID)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, value) in scale.enumerated() {
            submenu.addItem(ActionMenuItem(value, checked: value == current) { [weak self] in
                self?.model.onSetEffort?(snapshot.providerID, index)
            })
        }
        let item = NSMenuItem(title: current.map { L10n.t("Effort: \($0)") } ?? L10n.t("Effort"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    /// Its sessions, the busiest first; choosing one brings its window forward.
    private func sessionsSubmenu(for snapshot: ProviderSnapshot) -> NSMenuItem? {
        guard snapshot.localModel == nil, let sessions = model.activity(for: snapshot)?.sessions, !sessions.isEmpty
        else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let order: [AgentSession.State] = [.waiting, .busy, .success, .idle]
        let sorted = sessions.sorted {
            (order.firstIndex(of: $0.state) ?? 9, -$0.since.timeIntervalSince1970)
                < (order.firstIndex(of: $1.state) ?? 9, -$1.since.timeIntervalSince1970)
        }
        for session in sorted {
            let item = ActionMenuItem("\(session.name) — \(Self.label(session.state))") { [weak self] in
                if let pid = session.processID { self?.model.onFocusSession?(pid) }
            }
            item.toolTip = session.detail
            item.isEnabled = session.processID != nil
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: L10n.t("Sessions (\(sessions.count))"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    static func label(_ state: AgentSession.State) -> String {
        switch state {
        case .busy: return L10n.t("working")
        case .waiting: return L10n.t("waiting on you")
        case .success: return L10n.t("done")
        case .idle: return L10n.t("idle")
        }
    }
}
