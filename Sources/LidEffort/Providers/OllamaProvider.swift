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
    nonisolated let id = "ollama"
    nonisolated let displayName = "Ollama"
    nonisolated let glyph = ProviderGlyph.ollama

    private let endpoint = URL(string: "https://ollama.com/api/usage")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Enter an Ollama API key below, or export OLLAMA_API_KEY in your shell."))
    }

    nonisolated func account() -> ProviderAccount? {
        guard OllamaCredentials.isPresent else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: "Ollama",
            manageURL: URL(string: "https://ollama.com/settings")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let key = OllamaCredentials.load() else { throw UsageProviderError.needsAuth }

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
        Log.usage.debug("ollama usage -> \(body.prefix(900), privacy: .private)")

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
        OllamaCredentials.delete()
    }

    nonisolated func forgetCachedCredential() {
        OllamaCredentials.forgetCached()
    }
}
