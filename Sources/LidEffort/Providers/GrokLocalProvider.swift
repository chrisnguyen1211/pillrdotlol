import Foundation
import os

/// Reads Grok Build usage from the same billing endpoint the CLI's `/usage` uses.
///
/// The credential is Grok's own `~/.grok/auth.json` session — the CLI's job to
/// refresh, not this app's. Credits (`?format=credits`) is the weekly Grok
/// Build allowance, and the only number this endpoint actually states.
actor GrokLocalProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok"
    nonisolated let glyph = ProviderGlyph.grok

    private let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let session: URLSession
    private let authURL: URL

    init(session: URLSession = .shared, authURL: URL = GrokCredentials.authURL) {
        self.session = session
        self.authURL = authURL
    }

    nonisolated var signInCommand: String? { "grok login" }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Run grok login — it signs in and refreshes the token this reads."))
    }

    nonisolated func account() -> ProviderAccount? { GrokCredentials.account() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try GrokCredentials.load(from: authURL)
        if credentials.isExpired { throw UsageProviderError.credentialExpired }

        let credits = try await body(from: creditsURL, token: credentials.accessToken)
        Log.usage.debug("grok credits -> \(credits.prefix(400), privacy: .private)")

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: try GrokUsage.windows(creditsJSON: credits),
            headlineID: "credits"
        )
    }

    private func body(from url: URL, token: String) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status),
              let text = String(data: data, encoding: .utf8)
        else { throw UsageProviderError.badResponse(status: status) }
        return text
    }
}
