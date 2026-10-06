import Foundation

/// Every API key spyx was handed, drawn as one cell in the notch.
///
/// A ring per key stopped scaling the moment people added more than two: a
/// pill of twelve key rings is a pill with no room for the agents. So the
/// keys are read one by one, exactly as before — each keeps its own reading,
/// its own alerts and its own place in the archive — and only the notch
/// gathers them up. The cell's ring is the key nearest to running out; its
/// tooltip lists them all.
///
/// Who belongs: everything read with a key. The providers that had a key
/// field before the API tab — `glm`, `minimax`, `ollama` (Ollama Cloud) and
/// `apify` — their extra keys (`glm-k…`), and every catalog key
/// (`apikey_…`). Nothing local: `ollama-local`, LM Studio and custom
/// endpoints keep rings of their own.
enum APIKeyGroup {
    /// The cell's id. No provider has it, it is not a catalog key's prefix,
    /// and split on the dash it is no agent's effort target or glyph.
    static let id = "apikeys"

    static var displayName: String { L10n.t("API keys") }

    static func isMember(_ providerID: String) -> Bool {
        ExtraKey.bases.contains(providerID) || isAddedKey(providerID)
    }

    /// A key added under API, as against a base provider's own reading.
    static func isAddedKey(_ providerID: String) -> Bool {
        providerID.hasPrefix(ExtraKey.catalogPrefix) || ExtraKey.isExtraKey(providerID: providerID)
    }

    /// "1 key", "5 keys".
    static func countText(_ count: Int) -> String {
        count == 1 ? L10n.t("1 key") : L10n.t("\(count) keys")
    }

    // MARK: Order

    /// A remembered order with the keys folded into the group.
    ///
    /// The group keeps its own place once it has one. Before that — someone
    /// who dragged single key rings about in an older version — it takes the
    /// place of the first key the order names, which is where the keys were
    /// being looked for. The other key ids are dropped from the answer, not
    /// from what is stored.
    static func groupedOrder(_ order: [String]) -> [String] {
        let hasGroup = order.contains(id)
        var placed = hasGroup
        return order.compactMap { providerID in
            guard isMember(providerID) else { return providerID }
            guard !placed else { return nil }
            placed = true
            return id
        }
    }

    // MARK: The cell

    /// `cells` with every key taken out and one group cell put where the
    /// first of them stood. The keys go in the API tab's order: the base
    /// providers' own first, then the rest as `memberOrder` has them — the
    /// order they were added in — and anything it does not name after them.
    /// Nothing to gather, nothing changes.
    static func collapse(_ cells: [ProviderSnapshot], memberOrder: [String] = []) -> [ProviderSnapshot] {
        guard let first = cells.firstIndex(where: { isMember($0.id) }) else { return cells }
        let members = arrangeMembers(cells.filter { isMember($0.id) }, by: memberOrder)
        var result = cells.filter { !isMember($0.id) }
        // Where the first key stood, counted among what is left.
        let at = cells[..<first].filter { !isMember($0.id) }.count
        result.insert(snapshot(members: members), at: at)
        return result
    }

    static func arrangeMembers(_ members: [ProviderSnapshot], by order: [String]) -> [ProviderSnapshot] {
        let named = ExtraKey.bases + order.filter(isAddedKey)
        return ProviderOrder.arrange(members, by: named, id: \.id)
    }

    /// The group cell for these keys, in this order.
    static func snapshot(members: [ProviderSnapshot]) -> ProviderSnapshot {
        let headline = headline(for: members)
        var group = ProviderSnapshot(id: id, displayName: displayName, glyph: .apiKey, fidelity: .official,
                                     status: status(for: members),
                                     windows: headline.map { [$0] } ?? [],
                                     headlineID: headline?.id)
        group.keyGroup = members
        return group
    }

    /// What the ring draws: the reading of `ringMember`, or the number of
    /// keys when it has nothing to print. Nil when no key has been read yet,
    /// so the cell says so.
    static func headline(for members: [ProviderSnapshot]) -> LimitWindow? {
        guard members.contains(where: \.hasReading) else { return nil }
        let count = countText(members.count)
        guard let window = ringMember(of: members)?.headline else {
            return LimitWindow(id: id, label: displayName, usedText: count, prefersUsedText: true)
        }
        return LimitWindow(id: id, label: displayName, usedFraction: window.usedFraction,
                           usedText: window.usedText ?? count, resetsAt: window.resetsAt,
                           bandOverride: window.bandOverride, prefersUsedText: true)
    }

    /// Whether a key's last check failed — refused, or an error the
    /// provider gave. Its last numbers, if any, are still shown.
    static func isFailing(_ member: ProviderSnapshot) -> Bool {
        switch member.status {
        case .needsAuth, .accessDenied, .signedOutByOwner, .error, .unsupported: return true
        case .ok, .stale: return false
        }
    }

    /// The cell's status, which decides whether its ring is dimmed.
    ///
    /// Dimmed the way a failing provider's ring is when any key is failing,
    /// so a refused key cannot hide behind eleven working ones — and when
    /// the key the ring is drawing has gone stale. The others' ages are the
    /// tooltip's to say.
    static func status(for members: [ProviderSnapshot]) -> ProviderStatus {
        if members.contains(where: isFailing) { return .stale(since: .distantPast) }
        guard members.contains(where: \.hasReading) else { return .stale(since: .distantPast) }
        let ringKey = ringMember(of: members)
        if let since = ringKey?.status.staleSince { return .stale(since: since) }
        return .ok
    }

    /// The key whose reading the ring is drawing: the one closest to running
    /// out — the highest share used among the keys that say one. With no
    /// share anywhere, balances only, the lowest balance; one that only
    /// prints its amount cannot be compared, so it comes after, in order.
    /// Ties go to the key listed first, so the ring does not flicker between
    /// two keys at the same share.
    static func ringMember(of members: [ProviderSnapshot]) -> ProviderSnapshot? {
        let read = members.filter(\.hasReading)
        let shares = read.enumerated().compactMap { offset, member in
            member.headline?.usedFraction.map { (member: member, share: $0, offset: offset) }
        }
        if let top = shares.max(by: { ($0.share, -$0.offset) < ($1.share, -$1.offset) }) {
            return top.member
        }
        let balances = read.filter { $0.headline?.id.hasPrefix("balance") == true && $0.headline?.usedText != nil }
        let counted = balances.compactMap { member in member.headline?.money.map { (member: member, left: $0.remaining) } }
        return counted.min(by: { $0.left < $1.left })?.member ?? balances.first
    }

    // MARK: The tooltip's words

    /// What the tooltip's header says beside the title: how many keys, and
    /// how old the oldest reading is when one has aged.
    static func note(for members: [ProviderSnapshot], now: Date) -> String {
        let ages = members.compactMap { member -> Date? in
            guard member.hasReading, let since = member.status.staleSince, since != .distantPast else { return nil }
            return since
        }
        let count = countText(members.count)
        guard let oldest = ages.min() else { return count }
        return "\(count) · \(ElapsedCopy.ago(since: oldest, now: now))"
    }

    /// Why a key could not be read, in the words the API tab uses. A base
    /// provider may have no key at all yet, and says where one comes from.
    static func problem(for member: ProviderSnapshot) -> String? {
        switch member.status {
        case .needsAuth, .accessDenied, .signedOutByOwner:
            if ExtraKey.bases.contains(member.id), !member.hasReading, let message = member.statusMessage {
                return message
            }
            return L10n.t("That key was not accepted")
        case .error(let why), .unsupported(let why): return why
        case .ok, .stale: return nil
        }
    }

    /// One figure as a line of the tooltip: what it is, how much, and when
    /// it resets where that is known.
    struct Figure: Equatable {
        /// The window's name, for a figure measured against a limit — a
        /// share needs saying of what. Nil for an amount that says itself
        /// ("$7.50 left", "Key works · …").
        let label: String?
        let text: String
        /// Draws a bar under the line.
        let usedFraction: Double?
        let band: UsageBand?
    }

    static func figures(for member: ProviderSnapshot, now: Date,
                        resetTimeFormat: ResetTimeFormat = .automatic) -> [Figure] {
        member.windows.map { window in
            let reset = window.resetsAt.map { ResetCopy.text(for: $0, now: now, format: resetTimeFormat) }
            let amount = window.detail ?? window.summary
            let text = [amount, reset].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            guard let fraction = window.usedFraction else {
                return Figure(label: nil, text: text, usedFraction: nil, band: nil)
            }
            return Figure(label: window.label, text: text, usedFraction: fraction,
                          band: window.bandOverride ?? UsageBand.band(for: fraction))
        }
    }

    /// The line a key without numbers stands on: not read yet, or failing
    /// with nothing kept.
    static func placeholderLine(for member: ProviderSnapshot) -> String? {
        guard !member.hasReading, problem(for: member) == nil else { return nil }
        return L10n.t("Not read yet")
    }

    /// One key in a line, for the ring's menu: "OpenRouter · Work: $7.50 left".
    static func menuLine(for member: ProviderSnapshot, now: Date) -> String {
        let what = problem(for: member)
            ?? figures(for: member, now: now).first?.text
            ?? L10n.t("Not read yet")
        return "\(member.displayName): \(what)"
    }

    // MARK: Settings

    /// The Accounts list with the keys' rows folded into one, where the
    /// first of them stood. Every added key folds in, on or off — each is
    /// switched under API. A base provider folds in once it is connected;
    /// switched off, its row stays, so its Connect is still there to press.
    static func collapse(summaries: [ProviderSummary],
                         isConnected: (String) -> Bool = { _ in true }) -> [ProviderSummary] {
        let folded = Set(summaries.map(\.id).filter { isAddedKey($0) || (isMember($0) && isConnected($0)) })
        guard let first = summaries.firstIndex(where: { folded.contains($0.id) }) else { return summaries }
        let members = summaries.filter { folded.contains($0.id) }
        var result = summaries.filter { !folded.contains($0.id) }
        let at = summaries[..<first].filter { !folded.contains($0.id) }.count
        result.insert(summary(account: members.lazy.compactMap(\.account).first), at: at)
        return result
    }

    static func summary(account: ProviderAccount? = nil) -> ProviderSummary {
        ProviderSummary(id: id, name: displayName, glyph: .apiKey, account: account,
                        signIn: .guidance(L10n.t("Add, rename or switch keys off under API.")))
    }
}
