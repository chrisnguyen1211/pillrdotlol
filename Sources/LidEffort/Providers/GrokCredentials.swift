import Foundation

/// Identity and token from `~/.grok/auth.json`.
///
/// Grok CLI signs in through `auth.x.ai` and writes the session here. pillr
/// only reads it — refreshing is Grok's job, the same bargain as Claude Code's
/// keychain token. Writing a new access token would race the CLI for the file.
struct GrokCredentials {
    static var authURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    let accessToken: String
    let expiresAt: Date
    let email: String?

    var isExpired: Bool { expiresAt <= Date() }

    static func account(from url: URL = authURL) -> ProviderAccount? {
        guard let stored = (try? load(from: url)) else { return nil }
        return ProviderAccount(
            label: stored.email,
            plan: nil,
            source: "Grok",
            manageURL: URL(string: "https://grok.com/?_s=usage")
        )
    }

    static func load(from url: URL = authURL) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = pick(from: root)
        else { throw UsageProviderError.needsAuth }

        guard let token = entry["key"] as? String, !token.isEmpty else {
            throw UsageProviderError.needsAuth
        }

        return GrokCredentials(
            accessToken: token,
            expiresAt: date(entry["expires_at"]) ?? Date().addingTimeInterval(30 * 24 * 60 * 60),
            email: entry["email"] as? String
        )
    }

    /// Only a session minted by xAI itself. The file is keyed by
    /// `issuer::client_id`, and Grok also supports a customer IdP whose token
    /// is meant for a private proxy — sending that to cli-chat-proxy.grok.com
    /// would be handing someone else's credential to the public endpoint.
    static let trustedIssuer = "https://auth.x.ai"

    /// The file is keyed by `issuer::client_id`. One signed-in CLI is the
    /// ordinary case; if several sit there, the one that is still live wins,
    /// otherwise the first *trusted* entry.
    static func pick(from root: [String: Any]) -> [String: Any]? {
        let entries = root.compactMap { key, value -> [String: Any]? in
            guard let entry = value as? [String: Any], isTrusted(key: key, entry: entry)
            else { return nil }
            return entry
        }
        if let live = entries.first(where: {
            guard let expiry = date($0["expires_at"]) else { return true }
            return expiry > Date()
        }) { return live }
        return entries.first
    }

    static func isTrusted(key: String, entry: [String: Any]) -> Bool {
        if key.hasPrefix(trustedIssuer) { return true }
        if let issuer = entry["oidc_issuer"] as? String, issuer == trustedIssuer { return true }
        return false
    }

    static func date(_ any: Any?) -> Date? {
        guard let text = any as? String else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
