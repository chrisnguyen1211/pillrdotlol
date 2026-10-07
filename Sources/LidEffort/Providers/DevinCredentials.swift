import Foundation
import SQLite3

/// The session Devin keeps for itself — Devin Desktop's SQLite store first,
/// then the CLI's `credentials.toml` if that store is missing or has no sign-in.
///
/// pillr only ever reads it, the same bargain as Cursor and Claude Code:
/// the owning tool mints and refreshes it, we borrow the current value. Both
/// files hold the same kind of session token, and both answer the same
/// GetUserStatus call — the CLI path is only a fallback so the notch works on
/// a machine that has never had the Desktop app.
struct DevinCredentials {
    let apiKey: String
    let email: String?

    /// Devin Desktop (formerly Windsurf) keeps its auth in the app's own
    /// global-storage database, at `ItemTable.key = "windsurfAuthStatus"`.
    static var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    /// Devin CLI writes its credentials to a plain TOML file on `devin auth login`.
    static var cliCredentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin/credentials.toml")
    }

    /// Identity, Desktop first.
    static func account(from url: URL = storeURL,
                        fallbackCLI cli: URL = cliCredentialsURL) -> ProviderAccount? {
        guard let auth = try? load(from: url, fallbackCLI: cli) else { return nil }
        let source = FileManager.default.fileExists(atPath: url.path) ? "Devin Desktop" : "Devin CLI"
        return ProviderAccount(
            label: auth.email,
            plan: nil,
            source: source,
            manageURL: URL(string: "https://app.devin.ai")
        )
    }

    /// True when either source exists — the Desktop database or the CLI file.
    static func anySourceExists(desktop url: URL = storeURL,
                                cli: URL = cliCredentialsURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: cli.path)
    }

    /// Open Devin Desktop when it is installed; otherwise name the CLI command.
    static func signInRoute(desktopInstalled: Bool) -> SignInRoute {
        if desktopInstalled {
            return .openApp(bundleID: "com.exafunction.windsurf", name: "Devin")
        }
        return .guidance(L10n.t("Run `devin auth login` in a terminal to sign in."))
    }

    /// Desktop store first. The CLI file is only reached when the database has
    /// nothing to borrow — otherwise a laptop with both would flip between
    /// accounts depending on which file we happened to read. Re-read on every
    /// call so a sign-in or rotation takes effect without a restart.
    static func load(from url: URL = storeURL,
                     fallbackCLI cli: URL = cliCredentialsURL) throws -> DevinCredentials {
        if let auth = try? load(fromDatabase: url) { return auth }
        return try load(fromCLI: cli)
    }

    /// Desktop store only. Tests, and the combined loader above, pin the path
    /// so a missing Desktop app cannot silently become a live CLI read.
    static func load(fromDatabase url: URL) throws -> DevinCredentials {
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }
        guard let json = SQLiteStore.rows(
            in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: "windsurfAuthStatus"
        ).first else { throw UsageProviderError.needsAuth }

        struct Row: Decodable {
            let apiKey: String
            let email: String?
        }
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(json.utf8)),
              !row.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageProviderError.needsAuth }
        return DevinCredentials(apiKey: row.apiKey, email: row.email)
    }

    /// The CLI's `credentials.toml`. The file is simple enough that a TOML
    /// parser is not warranted — only `windsurf_api_key` is needed.
    static func load(fromCLI url: URL) throws -> DevinCredentials {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let line = content.split(separator: "\n")
                  .first(where: { $0.hasPrefix("windsurf_api_key") }),
              let value = line.split(separator: "\"").dropFirst().first
        else { throw UsageProviderError.needsAuth }
        let apiKey = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw UsageProviderError.needsAuth }
        return DevinCredentials(apiKey: apiKey, email: nil)
    }
}
