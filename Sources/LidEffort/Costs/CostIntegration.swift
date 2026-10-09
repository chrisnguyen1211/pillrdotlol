import AppKit
import Combine
import SwiftUI

/// Where the cost layer plugs into the app: the cost models watch the usage
/// store's snapshots, and the Activity window opens from Settings › Costs.
@MainActor
enum Costs {
    private static var subscriptions: [AnyCancellable] = []
    private static var activityWindow: NSWindow?
    /// Every provider's latest reading, for the plans each agent is on.
    private(set) static var latestSnapshots: [ProviderSnapshot] = []

    static func attach(to store: UsageStore) {
        guard !Runtime.isUnderTest else { return }
        _ = PlanCatalog.shared
        _ = PriceTable.shared
        _ = CostAccountStore.shared
        subscriptions = [
            store.$snapshots
                .receive(on: RunLoop.main)
                .sink { snapshots in
                    latestSnapshots = snapshots
                    CostAccountStore.shared.rediscover()
                    CostModels.all.forEach { $0.observe(snapshots) }
                },
            // A price typed in Settings, a billing switched, a rate fetched:
            // the rows already on the card are re-priced.
            CostAccountStore.shared.$accounts.dropFirst().map { _ in () }
                .merge(with: PriceTable.shared.$rate.dropFirst().map { _ in () },
                       PlanCatalog.shared.$plans.dropFirst().map { _ in () })
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { CostModels.all.forEach { $0.reload() } },
        ]
    }

    static func showActivity() {
        if activityWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L10n.t("Activity")
            w.minSize = NSSize(width: 900, height: 560)
            w.contentViewController = NSHostingController(rootView: TimelinePane().frame(minWidth: 900, minHeight: 560))
            w.isReleasedWhenClosed = false
            w.center()
            activityWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        activityWindow?.makeKeyAndOrderFront(nil)
    }
}
