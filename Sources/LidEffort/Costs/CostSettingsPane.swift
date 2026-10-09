import AppKit
import SwiftUI

/// Settings › Costs: how each login is paid, the plan detected for it, and
/// the market data the money is worked out from.
struct CostSettingsPane: View {
    /// Where the API keys are, for the dashboard.
    var preferences: Preferences? = nil
    @ObservedObject var accounts: CostAccountStore = .shared
    @ObservedObject var prices: PriceTable = .shared
    @ObservedObject var catalog: PlanCatalog = .shared

    private var currencyName: String { Locale.current.localizedString(forCurrencyCode: prices.localCurrency) ?? prices.localCurrency }

    var body: some View {
        Form {
            Section { PaneHero(section: .costs) }

            if accounts.accounts.isEmpty {
                Section {
                    Text(L10n.t("No Claude Code or Codex login on this Mac yet."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            ForEach(accounts.accounts) { account in
                Section(account.name) {
                    if let model = CostModels.model(for: account.id) {
                        CostAccountRows(account: account, model: model)
                    }
                }
            }

            Section(L10n.t("How the money is worked out")) {
                Text(L10n.t("Detected from each login once a day. A week of the plan costs the price ÷ 4.35; a project that used 4% of the weekly allowance spent 4% of that. Amounts in \(currencyName), your Mac's currency. Type the amount you actually pay to override the list price."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.t("Market data")) {
                Toggle(isOn: $prices.marketDataEnabled) {
                    SettingLabel(title: L10n.t("Download exchange rate and token prices"),
                                 subtitle: L10n.t("Once a day from open.er-api.com and OpenRouter. These are the only servers pillr reaches that are not an agent's own or GitHub."))
                }
                LabeledContent(L10n.t("Exchange rate")) {
                    Text(prices.rateKnown ? L10n.t("1 USD = \(MoneyFormat.string(prices.rate, currency: prices.currency))")
                         : prices.marketDataEnabled ? L10n.t("Not fetched yet") : L10n.t("Off, amounts stay in USD"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L10n.t("Per-token prices")) {
                    Text(L10n.t("\(prices.prices.count) models")).foregroundStyle(.secondary)
                }
                LabeledContent(L10n.t("Plan catalog")) {
                    Text(L10n.t("\(catalog.plans.count) plans")).foregroundStyle(.secondary)
                }
                // Only where there is something to fetch: with market data off
                // the bundled prices are all there is.
                if prices.marketDataEnabled {
                    HStack {
                        Button(L10n.t("Refresh now")) {
                            catalog.reload()
                            prices.refreshIfDue(force: true)
                        }
                        if let error = prices.lastError {
                            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                }
            }

            CodingPlansSection()
        }
        .formStyle(NotchFormStyle())
    }
}

/// One login's billing: how it is paid, what it costs, and the plan detected.
private struct CostAccountRows: View {
    let account: CostAccount
    /// The same model the tooltip's "what used it" reads, so what Settings
    /// says it spent is what the card says — and it re-prices the moment the
    /// billing changes here.
    @ObservedObject var model: CostModel
    @ObservedObject private var accounts = CostAccountStore.shared
    @ObservedObject private var prices = PriceTable.shared
    @ObservedObject private var catalog = PlanCatalog.shared

    var body: some View {
        let auto = account.monthlyLocal(rate: prices.effectiveRate)
        Picker(selection: Binding(get: { account.billing }, set: { accounts.setBilling(account.id, $0) })) {
            ForEach(CostAccount.Billing.allCases) { Text($0.title).tag($0) }
        } label: {
            SettingLabel(title: L10n.t("Billing"), subtitle: CostModels.model(for: account.id)?.statsLine())
        }
        .accessibilityLabel(L10n.t("Billing"))
        .pickerStyle(.segmented)
        .fixedSize()

        LabeledContent(L10n.t("Spent")) {
            Text(spentLine).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        if account.billing == .api {
            Text(L10n.t("Priced per token: each project's input, output and cache tokens at the model's list price, with \(prices.prices.count) models bundled. Turn on Market data below for today's prices."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if account.billing == .subscription {
            LabeledContent(L10n.t("Monthly price")) {
                TextField("", value: Binding(get: { account.monthlyPrice == 0 ? nil : account.monthlyPrice },
                                             set: { accounts.setMonthlyPrice(account.id, $0 ?? 0) }),
                          format: .number,
                          prompt: Text(auto > 0 ? MoneyFormat.string(auto, currency: prices.currency) : "—"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
            LabeledContent(L10n.t("Plan")) {
                Text(planDetail).foregroundStyle(.secondary)
            }
        }
    }

    /// What the login spent in the range the tooltip shows, in money.
    private var spentLine: String {
        switch model.state {
        case .unavailable: return L10n.t("No sessions on this Mac yet")
        case .waiting: return L10n.t("Nothing measured yet")
        case .ready:
            let priced = model.rows.compactMap(\.cost)
            let projects = model.rows.filter { !$0.isUnexplained }.count
            guard !priced.isEmpty else {
                if account.billing == .subscription, account.monthlyPrice == 0,
                   account.planTier.flatMap({ catalog.usd(for: $0) }) == 0 {
                    return L10n.t("Free plan · nothing to pay")
                }
                return account.billing == .subscription
                    ? L10n.t("Set the monthly price to see money")
                    : L10n.t("No priced tokens yet")
            }
            let total = MoneyFormat.string(priced.reduce(0, +), currency: prices.currency)
            return projects == 1
                ? L10n.t("\(model.range.shortTitle): \(total) · 1 project")
                : L10n.t("\(model.range.shortTitle): \(total) · \(projects) projects")
        }
    }

    private var planDetail: String {
        guard let tier = account.planTier else { return L10n.t("Plan not detected yet") }
        let name = catalog.name(for: tier)
        if let local = catalog.monthly(for: tier, currency: prices.currency, rate: prices.effectiveRate) {
            return L10n.t("\(name) · \(MoneyFormat.string(local, currency: prices.currency))/month (catalog)")
        }
        return L10n.t("\(name) · price unknown, set it here")
    }
}

/// Every agent's plan as it reports it, and what a month of it costs: the
/// list price where pillr knows it, a price typed here where it does not
/// (or to override it).
struct CodingPlansSection: View {
    @ObservedObject var accounts: CostAccountStore = .shared
    @State private var typed: [String: String] = [:]
    @State private var rows: [CodingPlans.Row] = []

    var body: some View {
        Section(L10n.t("Coding plans")) {
            if rows.isEmpty {
                Text(L10n.t("No agent reports a plan yet. Claude and Codex logins count here when set to Monthly plan."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField(row.monthly.map { CodingPlansSection.plain($0) } ?? L10n.t("Price"), text: binding(row.id))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .accessibilityLabel(L10n.t("Monthly price for \(row.agentName)"))
                        Text(row.currency == "USD" ? L10n.t("USD / month") : L10n.t("\(row.currency) / month"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    HStack(spacing: 8) {
                        ProviderGlyphView(glyph: row.glyph, size: 14)
                        SettingLabel(title: row.agentName, subtitle: subtitle(row))
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(accounts.$accounts) { _ in reload() }
    }

    private func reload() {
        rows = CodingPlans.rows(snapshots: Costs.latestSnapshots, accounts: accounts.accounts,
                                localCurrency: PriceTable.shared.currency)
        typed = CodingPlans.overrides.mapValues { CodingPlansSection.plain($0) }
    }

    private func subtitle(_ row: CodingPlans.Row) -> String {
        let plan = row.name ?? row.reported
        switch row.source {
        case .table: return L10n.t("\(plan) · list price")
        case .typed: return L10n.t("\(plan) · your price")
        case .account: return L10n.t("\(plan) · price set for this login")
        case nil: return L10n.t("\(plan) · price not known, type it here")
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { text in
            typed[id] = text
            var all = CodingPlans.overrides
            let number = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            if let number, number >= 0 { all[id] = number } else { all[id] = nil }
            CodingPlans.overrides = all
        })
    }

    static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
