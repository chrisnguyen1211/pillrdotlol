import Foundation

/// The Ollama cloud API key, read from the environment first and the keychain
/// second.
///
/// Unlike every other provider, spyx owns this credential: the user types
/// it into Settings, and it is stored in the login keychain under a service
/// name no other app uses. The environment variable `OLLAMA_API_KEY` is checked
/// first, so a shell that already exports one works without any setup.
enum OllamaCredentials {
    static let keychainService = "ollama-api-key"
    static let keychainAccount = "spyx"
    static let environmentKey = "OLLAMA_API_KEY"

    /// Held until the item moves, for the reason spelled out in
    /// `CredentialCache`: a data read can prompt, and this is reached every
    /// second from the local-runtime timer. A stored key never expires on its
    /// own.
    private static let cache = CredentialCache<String> { _ in false }

    private static func cachedKeychainKey() -> String? {
        try? cache.value(
            itemModifiedAt: { KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) },
            reload: {
                guard let key = KeychainItem.read(service: keychainService, account: keychainAccount) else {
                    throw UsageProviderError.needsAuth
                }
                return key
            }
        )
    }

    /// The API key, wherever it is found. Environment first, then keychain.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     keychain: () -> String? = cachedKeychainKey) -> String? {
        if let env = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return keychain()
    }

    /// Whether a key is available, judged without a data read: the
    /// environment variable, else the item's attributes, which are free to
    /// ask about unlike its contents. Never the cache — that would not
    /// reflect a `store`/`delete` that just happened.
    static var isPresent: Bool {
        load(keychain: { nil }) != nil || KeychainItem.modifiedAt(service: keychainService, account: keychainAccount) != nil
    }

    /// Stores a key in the keychain, so it survives relaunches. Overwrites any
    /// existing item under the same service+account.
    @discardableResult
    static func store(_ key: String) -> Bool {
        cache.forget()
        return KeychainItem.store(service: keychainService, account: keychainAccount, value: key)
    }

    /// Removes the key from the keychain. Called on sign-out, so the next
    /// fetch finds nothing and the ring goes dark.
    @discardableResult
    static func delete() -> Bool {
        cache.forget()
        return KeychainItem.delete(service: keychainService, account: keychainAccount)
    }

    static func forgetCached() { cache.forget() }
}
