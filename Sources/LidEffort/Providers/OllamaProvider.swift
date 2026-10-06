import Foundation
import os

/// Reads Ollama cloud usage from `https://ollama.com/api/usage`, authenticating
/// with an API key the user provides in Settings or exports as
/// `OLLAMA_API_KEY`.
///
/// The only provider that owns its credential rather than borrowing one: the
/// key is stored in the login keychain under a service no other app uses, and
/// sign-out deletes it. Polling and error handling follow the same path every
/// other provider takes through `UsageStore`.
actor OllamaProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.ollama

    private let endpoint = URL(string: "https://ollama.com/api/usage")!
    private let session: URLSession
    /// An extra key's ring: its own key, never the environment's or the
    /// base's keychain item. Nil for the provider's own ring.
    nonisolated private let extraKey: (@Sendable () -> String?)?

    /// The defaults are the provider's own ring. An extra key passes its id,
    /// its "Ollama · Work" name and `key`, which returns its key.
    init(id: String = "ollama", displayName: String = "Ollama",
         session: URLSession = .shared, key: (@Sendable () -> String?)? = nil) {
        self.id = id
        self.displayName = displayName
        self.session = session
        self.extraKey = key
    }

    private func loadKey() -> String? {
        extraKey.map { $0() } ?? OllamaCredentials.load()
    }

    nonisolated var signInRoute: SignInRoute {
        if extraKey != nil { return .guidance(ExtraKey.signInGuidance) }
        return .guidance(L10n.t("Add an Ollama API key under API, or export OLLAMA_API_KEY in your shell."))
    }

    nonisolated func account() -> ProviderAccount? {
        if let extraKey {
            guard extraKey() != nil else { return nil }
        } else {
            guard OllamaCredentials.isPresent else { return nil }
        }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: extraKey == nil ? "Ollama" : "spyx",
            manageURL: URL(string: "https://ollama.com/settings")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let key = loadKey() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("\(self.id, privacy: .public) usage -> \(body.prefix(900), privacy: .private)")

        let result = try OllamaUsage.parse(body)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: result.windows,
            headlineID: result.headlineID,
            weeklyID: "weekly"
        )
    }

    nonisolated func signOut() async {
        // An extra key is removed from Settings, not by switching it off.
        guard extraKey == nil else { return }
        OllamaCredentials.delete()
    }

    nonisolated func forgetCachedCredential() {
        guard extraKey == nil else { return }
        OllamaCredentials.forgetCached()
    }
}
