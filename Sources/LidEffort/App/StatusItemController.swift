import AppKit

/// The menu bar icon, present only while `AppPresence.menuBar` is chosen.
///
/// It exists to be a way *into* the app, so it opens settings and offers Quit —
/// with no Dock tile there is otherwise nothing to right-click, and an app you
/// cannot quit is a worse problem than one you cannot see.
///
/// It also carries the same readings as the notch tooltips, so `NotchVisibility`
/// hidden stays usable: with the notch off screen the menu is where the
/// percentages, resets and stale ages live.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let onOpenSettings: () -> Void
    /// Refetch one provider, leaving the others alone.
    var onRefreshProvider: ((String) -> Void)?
    /// Refetch every provider.
    var onRefreshAll: (() -> Void)?
    /// Open the setup assistant again.
    var onOpenSetup: (() -> Void)?
    /// Start the intro tour.
    var onTakeTour: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    /// An update downloaded and waiting: its version, and the restart.
    var readyUpdate: (() -> String?)?
    var onRestartToUpdate: (() -> Void)?

    /// The latest readings, mirrored from the store. The menu is rebuilt from
    /// these every time it opens, so reset countdowns and ages are fresh.
    var snapshots: [ProviderSnapshot] = []
    /// The notch's decorated cells, read when the menu opens. A local runtime's
    /// own snapshot only lists its models; what each one is doing, how fast it
    /// answered and what it cost today are put on the cells by the view model,
    /// and the menu says the same things the cells do.
    var cells: () -> [ProviderSnapshot] = { [] }
    var activity: (ProviderSnapshot) -> ActivitySummary? = { _ in nil }

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
    }

    var isShowing: Bool { item != nil }

    func show() {
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        item.button?.toolTip = L10n.t("spyx")

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        self.item = item
    }

    func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    // MARK: - Menu

    /// Rebuilt on every open rather than on every fetch: a menu built at fetch
    /// time would freeze "Resets in 51 min" and "20 hr ago" until the next
    /// reading lands.
    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu: menu, now: Date())
    }

    /// Exposed for tests: what the menu says without needing a status item.
    func rebuild(menu: NSMenu, now: Date) {
        menu.removeAllItems()
        if snapshots.isEmpty {
            let empty = NSMenuItem(title: L10n.t("No agents connected yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            menu.addItem(withTitle: L10n.t("Connect an Agent…"), action: #selector(openSetup), keyEquivalent: "").target = self
        } else {
            let cells = cells()
            for snapshot in snapshots {
                menu.addItem(headerItem(for: snapshot, now: now))
                for line in Self.detailLines(for: snapshot, cells: cells, activity: activity, now: now) {
                    let row = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    row.isEnabled = false
                    row.indentationLevel = 1
                    menu.addItem(row)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.t("Refresh All"), action: #selector(refreshAll), keyEquivalent: "r"
        ).target = self
        menu.addItem(
            withTitle: L10n.t("Settings…"), action: #selector(openSettings), keyEquivalent: ","
        ).target = self
        menu.addItem(
            withTitle: L10n.t("Set Up spyx…"), action: #selector(openSetup), keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: L10n.t("Take the Tour"), action: #selector(takeTour), keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("About spyx"), action: #selector(about), keyEquivalent: "").target = self
        if let version = readyUpdate?() {
            menu.addItem(withTitle: L10n.t("Restart to Update to \(version)"), action: #selector(restartToUpdate), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: L10n.t("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: L10n.t("Report a Bug…"), action: #selector(reportBug), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.t("Quit spyx"), action: #selector(quit), keyEquivalent: "q"
        ).target = self
    }

    /// The menu bar mark: its own drawing, not the app icon shrunk down.
    ///
    /// A template image, which is what lets macOS tint it — dark on a light
    /// menu bar, light on a dark one, and correct against a wallpaper-tinted
    /// bar without the app knowing any of that. The full-colour app icon can do
    /// none of it: it would fight every system item beside it and ignore the
    /// user's appearance entirely.
    ///
    /// Vector, so it is drawn at whatever the bar asks for rather than scaled
    /// from a fixed bitmap.
    static func icon() -> NSImage? {
        guard let image = Assets.image(named: "MenuBarIcon") else { return nil }
        // Menu bar items are laid out on an 18pt square; taller and macOS
        // clips it, shorter and it floats.
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func openSetup() { onOpenSetup?() }
    @objc private func takeTour() { onTakeTour?() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func restartToUpdate() { onRestartToUpdate?() }
    @objc private func reportBug() {
        BugReport.open(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
    }

    @objc private func refreshProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRefreshProvider?(id)
    }

    @objc private func refreshAll() { onRefreshAll?() }

    /// The provider's own row: name, headline figure, and age when stale — the
    /// same three facts the tooltip header shows. Clicking re-reads it.
    private func headerItem(for snapshot: ProviderSnapshot, now: Date) -> NSMenuItem {
        var title = "\(snapshot.displayName) — \(Self.headline(for: snapshot))"
        if snapshot.kind == .usage, let since = snapshot.status.staleSince, since != .distantPast {
            title += " · \(ElapsedCopy.ago(since: since, now: now))"
        }
        let header = NSMenuItem(title: title, action: #selector(refreshProvider(_:)), keyEquivalent: "")
        header.target = self
        header.representedObject = snapshot.id
        return header
    }

    /// A runtime has no headline figure of its own; its models have. The row
    /// says how many there are, and the lines under it say the rest.
    static func headline(for snapshot: ProviderSnapshot) -> String {
        if snapshot.kind == .localRuntime {
            return snapshot.localRuntime?.summary ?? "—"
        }
        return snapshot.hasReading ? snapshot.headlineText : "—"
    }

    /// Everything the tooltip says under its header: the blocked line first,
    /// then one row per limit window, or the status message when there is
    /// nothing metered. For a local runtime, one line per loaded model, built
    /// from its decorated cell. Pure, so the wording can be tested without a
    /// menu.
    static func detailLines(for snapshot: ProviderSnapshot, cells: [ProviderSnapshot] = [],
                            activity: (ProviderSnapshot) -> ActivitySummary? = { _ in nil },
                            now: Date) -> [String] {
        let now = now
        if snapshot.kind == .localRuntime {
            let models = cells.filter { $0.providerID == snapshot.id && $0.localModel != nil }
            guard models.isEmpty else { return models.map { modelLine(for: $0, activity: activity($0)) } }
            // The header already says "No models loaded"; only a failure to
            // reach the server is worth a line of its own.
            return snapshot.localRuntime == nil ? [snapshot.statusMessage].compactMap { $0 } : []
        }
        if let block = snapshot.block {
            var lines = [block.summary(now: now)]
            lines += snapshot.windows.map { windowLine(for: $0, now: now) }
            return lines
        }
        if let message = snapshot.statusMessage {
            return [message]
        }
        return snapshot.windows.map { windowLine(for: $0, now: now) }
    }

    /// One loaded model on one line: what its cell prints, what it is doing,
    /// how full its context was, and what it cost today — the tooltip's rows,
    /// in the order the eye wants them.
    static func modelLine(for cell: ProviderSnapshot, activity: ActivitySummary?) -> String {
        guard let model = cell.localModel else { return cell.headlineText }
        var parts = [cell.headlineText]
        if let activity, activity.state == .working {
            parts.append(activity.note ?? activity.sessions.first?.name ?? L10n.t("Thinking"))
        }
        if let fraction = cell.localContextFraction {
            parts.append(L10n.t("Context \(Percent.text(for: fraction))%"))
        }
        if let ledger = cell.localLedger {
            parts.append(L10n.t("Today \(ledger.tokensTodayText)"))
        }
        return "\(model.name): \(parts.joined(separator: " · "))"
    }

    /// One metered window on one line: label, percentage burned, and reset —
    /// the same three the tooltip spreads over three lines.
    static func windowLine(for window: LimitWindow, now: Date) -> String {
        var line = "\(window.label): \(window.summary)"
        if let resetsAt = window.resetsAt {
            line += " · \(ResetCopy.text(for: resetsAt, now: now))"
        }
        return line
    }
}
