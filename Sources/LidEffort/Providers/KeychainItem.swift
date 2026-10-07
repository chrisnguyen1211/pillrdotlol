import Foundation
import Security

/// Asking about a keychain item without asking for what is inside it.
///
/// The access control on another app's item guards its **data**, not its
/// attributes: `kSecReturnAttributes` is answered from the item's metadata and
/// never raises the "wants to access your confidential information" dialogue,
/// where `kSecReturnData` always may. `security find-generic-password` versus
/// the same command with `-w` is the same distinction from the shell.
///
/// That is what makes it worth asking often. The expensive read — the one that
/// can interrupt someone — then only has to happen when this says the item has
/// actually changed.
///
/// It is also what makes duplicates safe to resolve without a prompt. Claude
/// Code files a new keychain item on every token rotation rather than
/// updating one in place, so a login that has been used for months
/// accumulates several under the same service name — six, on the machine this
/// was found on. `kSecMatchLimitOne` gives no ordering guarantee across them,
/// so a plain query can return an old, expired duplicate while a valid one
/// sits beside it: the app reads a token that expired days ago, `security
/// find-generic-password` run at the same moment returns a different and
/// current one. `kSecMatchLimitAll` against attributes enumerates every
/// duplicate for free, so the newest is found by comparison rather than luck.
enum KeychainItem {
    /// One matching item, without its secret: when the owning app last wrote
    /// it, and a handle that can fetch its data later without searching again.
    struct Match {
        let modifiedAt: Date?
        /// Opaque to everything but `SecItemCopyMatching`. Reading the item
        /// this points at is the one call that can prompt; enumerating to find
        /// it, like reading `modifiedAt`, never does.
        let persistentRef: Data
        /// The service name it was filed under — needed to reach the same item
        /// by name when a direct read of it is refused.
        let service: String
        var account: String? = nil
    }

    /// The most recently modified item under a service, or nil if there is
    /// none or macOS declined to say. Ties do not arise in practice —
    /// `kSecAttrModificationDate` is a timestamp, not a version counter — and
    /// where they would, either duplicate is an equally good answer.
    static func newest(service: String, account: String? = nil) -> Match? {
        if let match = newestFiled(service: service, account: account) { return match }
        // Filed by spyx, before the rename, and not read since: see `read`.
        guard let old = legacy(service: service, account: account), !Legacy.refused(old.service, old.account)
        else { return nil }
        return newestFiled(service: old.service, account: old.account)
    }

    private static func newestFiled(service: String, account: String?) -> Match? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        if let account { query[kSecAttrAccount] = account }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }

        // A single match still comes back as one dictionary rather than an
        // array of one — `kSecMatchLimitAll` promises "every match", not "an
        // array", and one is not the many it means.
        let items = (result as? [[CFString: Any]]) ?? (result as? [CFString: Any]).map { [$0] } ?? []
        return winner(among: items)
    }

    /// The selection itself, apart from the query that produces its input.
    /// `SecItemCopyMatching` cannot run in a unit test — there is no keychain
    /// to point it at — so this is the half that can be, and is: given several
    /// duplicates, does the newest one actually win.
    static func winner(among items: [[CFString: Any]]) -> Match? {
        items
            .compactMap { item -> Match? in
                guard let ref = item[kSecValuePersistentRef] as? Data else { return nil }
                return Match(modifiedAt: item[kSecAttrModificationDate] as? Date, persistentRef: ref,
                             service: item[kSecAttrService] as? String ?? "",
                             account: item[kSecAttrAccount] as? String)
            }
            // A duplicate with no modification date is possible in principle
            // and worth keeping rather than discarding; `.distantPast` only
            // decides its rank against the others, never whether it exists.
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// When the owning app last wrote the newest item under this service, or
    /// nil if there is no such item or macOS declined to say.
    static func modifiedAt(service: String, account: String? = nil) -> Date? {
        newest(service: service, account: account)?.modifiedAt
    }

    /// The newest item across several services — the same "newest wins" choice
    /// as `newest(service:)`, widened to a profile whose token may be filed
    /// under more than one service name (see `ClaudeProfile.keychainServices`).
    /// Enumerating each service's attributes never raises a prompt, so trying
    /// two costs no extra dialogue over trying one.
    static func newest(services: [String], account: String? = nil) -> Match? {
        services
            .compactMap { newest(service: $0, account: account) }
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    /// When the owning app last wrote the newest item across these services.
    static func modifiedAt(services: [String], account: String? = nil) -> Date? {
        newest(services: services, account: account)?.modifiedAt
    }

    /// Reads the data from the newest item under a service. The one call that
    /// can trigger a keychain prompt. Items this app created itself (`store`)
    /// do not prompt either — but only as long as the binary keeps the same
    /// signing identity that stored them; an ad-hoc rebuild is a new identity,
    /// which is why even own-item readers go through `CredentialCache`.
    static func read(service: String, account: String? = nil) -> String? {
        guard let match = newest(service: service, account: account) else { return nil }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: match.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let isLegacy = match.service != service
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8)
        else {
            // Refused: not asked again this run — a background refresh must
            // not put the same dialogue up on every poll.
            if isLegacy { Legacy.refuse(match.service, match.account) }
            return nil
        }
        // spyx's item, read once: filed again under pillr's name, which this
        // copy owns and reads without a word, and the old one taken out.
        if isLegacy, let oldAccount = match.account {
            let newAccount = account ?? renamed(oldAccount)
            if store(service: service, account: newAccount, value: value) {
                delete(service: match.service, account: oldAccount, includingLegacy: false)
            }
        }
        return value
    }

    // MARK: Before the rename

    /// Where spyx filed what pillr files under `service` and `account`:
    /// the same names with spyx's in place of pillr's. Nil for a name that
    /// is not pillr's own — another app's item never moved.
    static func legacy(service: String, account: String?) -> (service: String, account: String?)? {
        let old = Rebrand.previousName
        let oldService = service.replacingOccurrences(of: "pillr", with: old)
        let oldAccount = account?.replacingOccurrences(of: "pillr", with: old)
        guard oldService != service || oldAccount != account else { return nil }
        return (oldService, oldAccount)
    }

    private static func renamed(_ account: String) -> String {
        account.replacingOccurrences(of: Rebrand.previousName, with: "pillr")
    }

    private enum Legacy {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var refusedItems: Set<String> = []
        static func refuse(_ service: String, _ account: String?) {
            lock.withLock { _ = refusedItems.insert(service + "\u{1F}" + (account ?? "")) }
        }
        static func refused(_ service: String, _ account: String?) -> Bool {
            lock.withLock { refusedItems.contains(service + "\u{1F}" + (account ?? "")) || refusedItems.contains(service + "\u{1F}") }
        }
    }

    /// Stores a string under a service+account, creating or updating the item.
    /// For items this app owns, no prompt is involved on either write or read.
    static func store(service: String, account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Deletes the item under a service+account, if one exists.
    @discardableResult
    static func delete(service: String, account: String, includingLegacy: Bool = true) -> Bool {
        // A key removed in pillr must not come back from spyx's copy of it.
        if includingLegacy, let old = legacy(service: service, account: account), let oldAccount = old.account {
            delete(service: old.service, account: oldAccount, includingLegacy: false)
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
