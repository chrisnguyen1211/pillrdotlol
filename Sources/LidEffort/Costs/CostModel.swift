// Ported from Codenotch (MIT).
import Foundation
import SwiftUI
import Combine

/// Drives the "what used it" section of a Claude or Codex card.
///
/// The limit itself only tells you how much is gone. This pairs each observed
/// increase with the local turns that happened in the same interval, so the card
/// can say *which project* spent it. Everything is computed locally from files
/// the CLIs already wrote; no extra requests.
@MainActor
final class CostModel: ObservableObject {

    /// The login as it is now: billing and price are edited in Settings while
    /// the model lives, so they are read from the store rather than kept.
    var account: CostAccount { CostAccountStore.shared.account(initialAccount.id) ?? initialAccount }
    private let initialAccount: CostAccount

    enum State {
        case unavailable      // no transcripts on this machine — hide the section
        case waiting          // indexed, but no measurable consumption yet
        case ready
    }

    @Published private(set) var rows: [ProjectCost] = []
    @Published private(set) var state: State = .unavailable
    /// False for plans with no rolling limits (credit-based seats): the session
    /// and week views need limit samples, so only month and all-time apply.
    @Published private(set) var quotaBacked = true
    /// The allowance the "week" tab measures: the weekly limit, or the credit
    /// cycle for credit-based seats.
    @Published private(set) var allowance: CostWindow = .weekly
    var creditBacked: Bool { allowance == .credits }

    @Published var isExpanded: Bool {
        didSet { UserDefaults.standard.set(isExpanded, forKey: Self.expandedKey) }
    }

    /// Which range the list is showing. Persisted, like the expanded state.
    @Published var range: CostRange {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: Self.rangeKey)
            reload()
        }
    }

    static let expandedKey = "costExpanded"
    static let rangeKey = "costRange"
    private let store: CostStore?
    private let indexer: CostIndexer?

    init(account: CostAccount) {
        self.initialAccount = account
        isExpanded = UserDefaults.standard.bool(forKey: Self.expandedKey)
        let saved = CostRange(rawValue: UserDefaults.standard.string(forKey: Self.rangeKey) ?? "") ?? .session
        range = saved == .allTime ? .month : saved

        // One database and one transcript watcher per account.
        let dbName = "agentcost-\(account.id).sqlite"
        store = CostStore(url: CostPaths.directory.appendingPathComponent(dbName))
        indexer = store.flatMap {
            CostIndexer(store: $0, root: account.transcriptsRoot, format: account.provider == "codex" ? .codex : .claude)
        }

        guard let indexer else { return }
        state = .waiting
        indexer.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        indexer.start()
        reload()
    }

    /// Called after every usage poll. Samples the limit and attributes any increase.
    /// spyx's windows carry ids: "session"/"primary" are the rolling session,
    /// "weekly_all"/"secondary" the week, anything named credits the credit cap
    /// of a Business seat.
    func observe(_ snapshots: [ProviderSnapshot]) {
        guard let store, let snap = snapshots.first(where: { $0.id == account.id }) else { return }
        let samples: [(window: CostWindow, pct: Double, resetsAt: Date?)] = snap.windows.compactMap { w in
            guard let f = w.usedFraction else { return nil }
            let window: CostWindow
            switch w.id {
            case "session", "primary": window = .session
            case "weekly_all", "weekly", "secondary": window = .weekly
            default:
                if w.id.lowercased().contains("credit") || w.label.lowercased().contains("credit") { window = .credits } else { return nil }
            }
            if window == .credits, let used = w.used, let remaining = w.remaining {
                CostAccountStore.shared.setCreditLimit(account.id, Double(used + remaining))
            }
            return (window, f * 100, w.resetsAt)
        }
        if samples.isEmpty {
            if quotaBacked { quotaBacked = false; if range.window != nil { range = .month } }
            return
        }
        if !quotaBacked { quotaBacked = true }
        let win: CostWindow = samples.contains { $0.window == .credits } ? .credits : .weekly
        if allowance != win { allowance = win; if range == .session && win == .credits { range = .weekly } }
        CostAccountStore.shared.detectPlanIfDue(account.id)

        Task.detached(priority: .utility) {
            for s in samples {
                store.recordSample(window: s.window, pct: s.pct, resetsAt: s.resetsAt)
            }
            await MainActor.run { self.reload() }
        }
    }

    func reload() {
        guard let store else { return }
        let range = (quotaBacked || self.range.window == nil) ? self.range : .month
        let pricer = PriceTable.shared.pricer
        let account = self.account
        let monthlyLocal = account.monthlyLocal(rate: pricer.rate)
        let quotaBacked = self.quotaBacked
        let allowance = self.allowance
        let creditPoint: Double? = (allowance == .credits && account.creditLimit != nil)
            ? account.creditLocal(rate: pricer.rate).map { $0 * account.creditLimit! / 100 } : nil
        Task.detached(priority: .utility) {
            // The "week" tab reads the account's allowance window (weekly limit or credit cycle).
            var fresh: [ProjectCost]
            if range == .weekly { fresh = store.currentPeriod(window: allowance) } else { fresh = store.rows(for: range) }
            // Money for the same interval, from the tokens of each project.
            let now = Int(Date().timeIntervalSince1970)
            let from: Int
            if range == .weekly { from = store.currentPeriodStart(window: allowance) }
            else if let w = range.window { from = store.currentPeriodStart(window: w) }
            else if let d = range.start { from = Int(d.timeIntervalSince1970) }
            else { from = 0 }
            let costs: [String: Double]
            switch account.billing {
            case .api:
                costs = store.projectCosts(from: from, to: now, pricer: pricer)
            case .subscription where quotaBacked && creditPoint != nil:
                // Credit-based seat: 1 % of the cycle's allowance = limit ÷ 100 credits.
                let pct = store.attributedPct(window: .credits, from: from, to: now)
                costs = pct.mapValues { creditPoint! * $0 }
            case .subscription where quotaBacked:
                // A week of the plan costs price ÷ 4.35; a project that consumed
                // 4 % of the weekly allowance spent 4 % of that.
                let weekly = monthlyLocal / CostEstimator.weeksPerMonth
                let pct = store.attributedWeeklyPct(from: from, to: now)
                costs = weekly > 0 ? pct.mapValues { weekly * $0 / 100 } : [:]
            case .subscription:
                // No rolling limit to anchor on: the plan is spread over the
                // month's tokens.
                let month = store.totalWeight(from: CostEstimator.monthStart(), to: now)
                let (byProject, _) = store.weightsPublic(from: from - 1, to: now)
                costs = (monthlyLocal > 0 && month > 0) ? byProject.mapValues { monthlyLocal * $0 / month } : [:]
            }
            // Inside the allowance window every row's share is already the
            // share of that window, so its money is that share of the plan:
            // the same number for every row, whether its share came from a
            // recorded jump or from the gap spread over the tokens.
            let perPoint: Double?
            switch account.billing {
            case .subscription where quotaBacked && creditPoint != nil && range == .weekly:
                perPoint = creditPoint
            case .subscription where quotaBacked && range == .weekly:
                let weekly = monthlyLocal / CostEstimator.weeksPerMonth
                perPoint = weekly > 0 ? weekly / 100 : nil
            default:
                perPoint = nil
            }
            for i in fresh.indices where !fresh[i].isUnexplained {
                fresh[i].cost = perPoint.map { $0 * fresh[i].pct } ?? costs[fresh[i].project]
            }
            let done = fresh.presentable()
            await MainActor.run {
                self.rows = done
                self.state = done.isEmpty ? .waiting : .ready
            }
        }
    }

    var store_: CostStore? { store }

    /// Diagnostics line for the settings pane.
    func statsLine() -> String? {
        guard let store else { return nil }
        let st = store.stats()
        guard st.events > 0 || st.files > 0 else { return nil }
        if st.errors > 0 { return L10n.t("\(st.events) turns · \(st.files) files · \(st.errors) skipped") }
        return L10n.t("\(st.events) turns · \(st.files) files")
    }
}


/// One CostModel per account (Claude and Codex), created lazily and kept while the account exists.
@MainActor
enum CostModels {
    private static var byAccount: [String: CostModel] = [:]

    static var all: [CostModel] {
        CostAccountStore.shared.accounts.compactMap { model(for: $0.id) }
    }

    static func model(for accountID: String) -> CostModel? {
        if let m = byAccount[accountID] { return m }
        guard let a = CostAccountStore.shared.account(accountID) else { return nil }
        let m = CostModel(account: a)
        byAccount[accountID] = m
        return m
    }
}
