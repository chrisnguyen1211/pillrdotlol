import Foundation
import os
import Security

/// An API key spyx tracks on top of whatever a provider's own ring reads,
/// each read on its own and drawn as a line of the one API keys cell — see
/// `APIKeyGroup`.
///
/// Two kinds, told apart by their id:
///
/// - A second (third, …) key for one of the providers that had a key field
///   before the API tab — GLM, MiniMax's Coding Plan, Ollama Cloud and
///   Apify. The provider's own key stays under the base id (`glm`); an extra
///   one is the same adapter built around a different key, under
///   `<base>-<slug>` — the shape a Claude profile's `claude-<slug>` has, and
///   for the same reason: everything that only has an id
///   (`EffortState.targetID`, `ProviderGlyph.forProvider`) maps it back to
///   the base by splitting on the dash, so the ring wears the base's glyph.
/// - A key for any other provider in `APICatalog`, under
///   `apikey_<catalog id>-<slug>`. The prefix is what keeps it apart from
///   everything else: split on the dash it gives `apikey_kimi`, which is no
///   agent's effort target, where a bare `kimi-…` would have taken the Kimi
///   agent's. `ProviderGlyph.forProvider` asks the catalog for its glyph.
///
/// Only the description lives here and in `Preferences`. The key itself is in
/// the login keychain — see `ExtraKeySecrets`.
struct ExtraKey: Codable, Identifiable, Equatable, Hashable {
    /// `<base>-<slug>` or `apikey_<base>-<slug>`, the provider id.
    let id: String
    /// `glm`, `minimax`, `ollama`, `apify`, or a catalog entry's id.
    let base: String
    /// What the person called it — "Work". Unique per base.
    var name: String
    /// Which console the key belongs to, where that is a question: `global` or
    /// `china` for GLM, `international` or `china` for MiniMax, and a catalog
    /// entry's own regions. Nil elsewhere.
    var region: String?
    /// Values for a catalog entry's extra fields — an account or project id.
    /// Not secrets. Nil for every key saved before the catalog existed.
    var fields: [String: String]? = nil

    /// The providers that carried extra keys before the catalog, in the
    /// order Settings lists them. Their ids keep the old shape.
    static let bases = ["glm", "minimax", "ollama", "apify"]

    /// What a catalog key's id starts with.
    static let catalogPrefix = "apikey_"

    // MARK: Identity

    /// A short random slug, `k` and five hex digits: lowercase, no dash, and
    /// never `local` — `ollama-local` is a different provider entirely.
    static func randomSlug() -> String {
        let hex = String(format: "%05x", Int.random(in: 0..<0x100000))
        return "k" + hex
    }

    static func makeID(base: String, existing: [ExtraKey] = [],
                       slug: () -> String = randomSlug) -> String {
        let stem = bases.contains(base) ? base : catalogPrefix + base
        var id = "\(stem)-\(slug())"
        // Five hex digits make a collision unlikely, not impossible.
        while existing.contains(where: { $0.id == id }) { id = "\(stem)-\(slug())" }
        return id
    }

    private static func isSlug(_ slug: Substring) -> Bool {
        slug.count == 6 && slug.first == "k"
            && slug.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) })
    }

    /// The base an extra key's id belongs to, or nil for any other id.
    ///
    /// Strict about the slug's shape on purpose: `ollama-local` and its
    /// `ollama-local:model:…` cells start with `ollama-` too, and they are not
    /// keys. A catalog key whose entry has gone from the catalog is not one
    /// either — there is nothing left that could read it.
    static func base(fromProviderID id: String) -> String? {
        if id.hasPrefix(catalogPrefix) {
            let rest = id.dropFirst(catalogPrefix.count)
            guard let dash = rest.lastIndex(of: "-") else { return nil }
            let base = String(rest[..<dash])
            guard isSlug(rest[rest.index(after: dash)...]),
                  let entry = APICatalog.entry(id: base), case .catalog = entry.route
            else { return nil }
            return base
        }
        for base in bases where id.hasPrefix(base + "-") {
            guard isSlug(id.dropFirst(base.count + 1)) else { return nil }
            return base
        }
        return nil
    }

    static func isExtraKey(providerID: String) -> Bool {
        base(fromProviderID: providerID) != nil
    }

    // MARK: Names

    /// The base provider's name, as its own ring is titled.
    static func providerName(for base: String) -> String {
        switch base {
        case "glm":     return "GLM"
        case "minimax": return "MiniMax"
        case "ollama":  return "Ollama"
        case "apify":   return "Apify"
        default:        return APICatalog.entry(id: base)?.name ?? base
        }
    }

    /// "GLM · Work" — what the ring, the tooltip, the menu and the alerts say.
    var displayName: String { Self.displayName(base: base, name: name) }

    static func displayName(base: String, name: String) -> String {
        "\(providerName(for: base)) · \(name)"
    }

    /// "Key 2", "Key 3"… — the first one not already taken for this base.
    /// Where the provider's own ring holds a key, that is the first, so
    /// counting starts at two; a catalog provider has no ring of its own, and
    /// neither does a base with nothing to read, so theirs start at one.
    static func defaultName(base: String, existing: [ExtraKey], hasOwnKey: Bool? = nil) -> String {
        var n = (hasOwnKey ?? bases.contains(base)) ? 2 : 1
        while isNameTaken(L10n.t("Key \(n)"), base: base, in: existing) { n += 1 }
        return L10n.t("Key \(n)")
    }

    /// Case- and whitespace-insensitive, so "Work" and "work " are one name.
    static func isNameTaken(_ name: String, base: String, in existing: [ExtraKey],
                            excluding id: String? = nil) -> Bool {
        let wanted = normalized(name)
        return existing.contains {
            $0.base == base && $0.id != id && normalized($0.name) == wanted
        }
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Region

    var glmIsChina: Bool { region == "china" }

    var minimaxRegion: MiniMaxRegion {
        region.flatMap(MiniMaxRegion.init(rawValue:)) ?? .international
    }

    /// The region a new key starts on: the one the base's own key uses.
    static func defaultRegion(for base: String) -> String? {
        switch base {
        case "glm":     return GLMCredentials.pastedIsChina ? "china" : "global"
        case "minimax": return Preferences.storedMinimaxRegion().rawValue
        default:        return APICatalog.entry(id: base)?.regions.first?.id
        }
    }

    /// What an extra key's row says in place of the base's sign-in guidance:
    /// there is nothing to sign into, only a key that was kept or was not.
    static var signInGuidance: String {
        L10n.t("This key was added in spyx. If it stops working, remove it and add it again.")
    }
}

// MARK: - The keys themselves

/// Each extra key's secret, in the login keychain: service `spyx-extra-key`,
/// account the extra key's id.
///
/// The item is spyx's own, so a read never needs to ask anyone — and is never
/// allowed to: an ad-hoc rebuild is a new signing identity, and an own-item
/// read can then raise the dialogue like anyone else's. Reads are made with
/// interaction switched off and held behind a `CredentialCache` until the item
/// moves, the same bargain every other key in the app makes.
enum ExtraKeySecrets {
    static let service = "spyx-extra-key"

    private static let lock = NSLock()
    private static var caches: [String: CredentialCache<String>] = [:]

    private static func cache(for id: String) -> CredentialCache<String> {
        lock.lock(); defer { lock.unlock() }
        if let cache = caches[id] { return cache }
        let cache = CredentialCache<String> { _ in false }
        caches[id] = cache
        return cache
    }

    /// The key for this extra key's id, or nil when there is none or it could
    /// not be read without asking.
    static func read(id: String) -> String? {
        try? cache(for: id).value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: service, account: id) },
            reload: { try readNow(id: id) }
        )
    }

    private static func readNow(id: String) throws -> String {
        guard let match = KeychainItem.newest(service: service, account: id) else {
            throw UsageProviderError.needsAuth
        }
        let (status, data) = KeychainSecret.read(query: [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: match.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ], interactive: false, rescue: nil)
        guard status == errSecSuccess, let data else {
            Log.usage.error("extra key read failed: OSStatus \(status)")
            throw ClaudeCredentials.wasRefused(status)
                ? UsageProviderError.accessDenied
                : UsageProviderError.needsAuth
        }
        guard let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { throw UsageProviderError.needsAuth }
        return key
    }

    /// Attributes only: free to ask, and never stale after a store or delete.
    static func isPresent(id: String) -> Bool {
        KeychainItem.modifiedAt(service: service, account: id) != nil
    }

    @discardableResult
    static func store(id: String, key: String) -> Bool {
        cache(for: id).forget()
        return KeychainItem.store(service: service, account: id,
                                  value: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func delete(id: String) -> Bool {
        cache(for: id).forget()
        return KeychainItem.delete(service: service, account: id)
    }
}

// MARK: - Providers

/// Builds the ring behind an extra key: the base provider's own adapter, told
/// a different id, name and key — or, for a catalog key, `CatalogKeyProvider`.
enum ExtraKeyProviders {
    /// `secret` is the key, asked for on every fetch. Production reads the
    /// keychain item; verification and tests hand in the key they hold.
    static func make(_ extra: ExtraKey,
                     session: URLSession = .shared,
                     archive: UsageArchive = UsageArchive(),
                     secret: @escaping @Sendable () -> String?) -> UsageProvider? {
        switch extra.base {
        case "glm":
            let base = URL(string: extra.glmIsChina ? "https://open.bigmodel.cn" : "https://api.z.ai")!
            return GLMProvider(id: extra.id, displayName: extra.displayName,
                               session: session, archive: archive,
                               credential: {
                                   secret().map { GLMCredentials.Credential(token: $0, baseURL: base, source: "spyx") }
                               })
        case "minimax":
            return MiniMaxProvider(id: extra.id, displayName: extra.displayName,
                                   session: session, region: extra.minimaxRegion, archive: archive,
                                   extraKey: secret)
        case "ollama":
            return OllamaProvider(id: extra.id, displayName: extra.displayName,
                                  session: session, key: secret)
        case "apify":
            return ApifyProvider(id: extra.id, displayName: extra.displayName,
                                 session: session, archive: archive, token: secret)
        default:
            // Everything else in the catalog reads through one adapter,
            // driven by the entry's own description.
            return CatalogKeyProvider(extra: extra, session: session, secret: secret)
        }
    }

    /// Every extra key's ring, reading its key from the keychain.
    static func makeAll(_ keys: [ExtraKey]) -> [UsageProvider] {
        keys.compactMap { extra in
            let id = extra.id
            return make(extra, secret: { ExtraKeySecrets.read(id: id) })
        }
    }
}

// MARK: - Adding one

/// What Settings' "Add" does, apart from the view so it can be tested: check
/// the key with a real reading, and keep it only if that reading came back.
@MainActor
enum ExtraKeyVerifier {
    enum Outcome: Equatable {
        case added(ExtraKey)
        case failed(String)
    }

    /// - Parameters:
    ///   - makeProvider: the provider to check with, holding the key in hand
    ///     rather than reading it from anywhere — nothing has been stored yet.
    ///   - storeSecret: files the key once it has been shown to work.
    static func add(base: String, name rawName: String, key rawKey: String, region: String?,
                    fields: [String: String]? = nil,
                    existing: [ExtraKey],
                    hasOwnKey: Bool? = nil,
                    makeID: (String, [ExtraKey]) -> String = { ExtraKey.makeID(base: $0, existing: $1) },
                    makeProvider: (ExtraKey, String) -> UsageProvider? = { extra, key in
                        ExtraKeyProviders.make(extra, secret: { key })
                    },
                    storeSecret: (String, String) -> Bool = { ExtraKeySecrets.store(id: $0, key: $1) })
    async -> Outcome {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failed(L10n.t("Paste a key first")) }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty
            ? ExtraKey.defaultName(base: base, existing: existing, hasOwnKey: hasOwnKey) : trimmed
        guard !ExtraKey.isNameTaken(name, base: base, in: existing) else {
            return .failed(L10n.t("There is already a key called \(name)"))
        }
        if let entry = APICatalog.entry(id: base) {
            for field in entry.fields where field.required
                && (fields?[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
                return .failed(L10n.t("Fill in \(field.title()) first"))
            }
        }
        let kept = fields?.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty }
        let extra = ExtraKey(id: makeID(base, existing), base: base, name: name, region: region,
                             fields: kept?.isEmpty == false ? kept : nil)
        guard let provider = makeProvider(extra, key) else {
            return .failed(L10n.t("spyx doesn't know this provider"))
        }

        // Only a reading that actually came back proves the key. A throttle
        // or an expired-looking answer reads as "stale" to the store, which is
        // right for a key already kept and wrong for one being judged.
        do {
            _ = try await provider.fetchSnapshot(freshness: .fromSource)
        } catch {
            return .failed(reason(for: UsageStore.providerStatus(for: error)))
        }
        guard storeSecret(extra.id, key) else {
            return .failed(L10n.t("Couldn't save the key in your login keychain"))
        }
        Log.usage.info("extra key added for \(base, privacy: .public): \(name, privacy: .private)")
        return .added(extra)
    }

    /// Removing an extra key: its keychain item, its description and every
    /// choice made about its ring. The store follows `extraKeys`.
    static func remove(_ id: String, from preferences: Preferences,
                       deleteSecret: (String) -> Void = { ExtraKeySecrets.delete(id: $0) }) {
        guard ExtraKey.isExtraKey(providerID: id) else { return }
        deleteSecret(id)
        preferences.removeExtraKey(id: id)
    }

    /// The wording a refused key gets on a base row, so the two read alike.
    nonisolated static func reason(for status: ProviderStatus) -> String {
        switch status {
        case .needsAuth, .accessDenied: return L10n.t("That key was not accepted")
        case .error(let why): return L10n.t("Couldn't connect — \(why)")
        case .unsupported(let why): return why
        case .stale: return L10n.t("Couldn't check the key just now — try again in a minute")
        default: return L10n.t("That key was not accepted")
        }
    }
}
