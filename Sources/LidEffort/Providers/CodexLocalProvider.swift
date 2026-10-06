import Foundation
import SQLite3

/// Reads live account limits using the session owned and refreshed by Codex.
actor CodexLocalProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.openai
    nonisolated let profile: CodexProfile

    private let session: URLSession
    nonisolated private let authURL: URL
    private let archive: UsageArchive
    private var retryNoEarlierThan: Date?

    init(profile: CodexProfile = .default(),
         session: URLSession = .shared,
         authURL: URL? = nil,
         archive: UsageArchive = UsageArchive()) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.authURL = authURL ?? profile.authURL
        self.archive = archive
        // Recreating the provider or relaunching must not bypass the server's retry deadline.
        self.retryNoEarlierThan = archive.loadBackoffUntil(providerID: profile.id)
    }

    nonisolated var signInCommand: String? { profile.signInCommand }

    /// Where the sign-in lives: a new one written there is read at once.
    nonisolated var credentialFiles: [URL] { [authURL] }

    nonisolated var signInRoute: SignInRoute {
        guard profile.slug != nil else { return .openApp(bundleID: "com.openai.codex", name: "Codex") }
        return .guidance(L10n.t("Run \(profile.signInCommand) in Terminal to sign in to \(displayName)."))
    }

    nonisolated func account() -> ProviderAccount? {
        CodexCredentials.account(from: authURL, source: profile.sourceName)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        if let retryNoEarlierThan, retryNoEarlierThan > now {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSince(now))
        }

        // Codex can rotate its token between polls; this app never refreshes or writes it.
        let credential = try CodexCredentials.load(from: authURL)
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            let receivedAt = Date()
            let delay = max(60, Self.retryAfter(from: http, now: receivedAt) ?? 0)
            retryNoEarlierThan = receivedAt.addingTimeInterval(delay)
            archive.saveBackoffUntil(retryNoEarlierThan, providerID: id)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let windows = try CodexUsage.windows(from: data)

        async let resetCredits = Self.fetchResetCredits(session: session, credential: credential)

        // The profile page's token statistics are the source for the chart and
        // totals.
        let profileUsage = try? await Self.fetchProfileUsage(
            session: session, credential: credential
        )
        retryNoEarlierThan = nil
        archive.saveBackoffUntil(nil, providerID: id)
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: windows.first?.id,
            weeklyID: "secondary",
            tokenUsage: profileUsage,
            plan: CodexUsage.plan(from: data) ?? account()?.plan?.nonEmptyPlan,
            resetCredits: await resetCredits
        )
    }

    private static func fetchProfileUsage(
        session: URLSession,
        credential: CodexCredentials.Credential
    ) async throws -> CodexTokenUsage {
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }
        return try CodexUsage.profileUsage(from: data)
    }

    /// Unused rate-limit resets on this Codex account, listed by the same
    /// backend as usage.
    private static func fetchResetCredits(
        session: URLSession,
        credential: CodexCredentials.Credential
    ) async -> CodexResetCredits? {
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return nil }
            return try CodexUsage.resetCredits(from: data)
        } catch {
            return nil
        }
    }

    private static func retryAfter(from response: HTTPURLResponse?, now: Date) -> TimeInterval? {
        guard let header = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if let seconds = TimeInterval(header), seconds.isFinite { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Shared access to Codex's local state.
enum CodexStore {
    static var stateURL: URL {
        CodexProfile.default().stateURL
    }

    /// The desktop app's own thread catalogue.
    ///
    /// Codex's *rollouts* are written by the CLI and by the VS Code extension.
    /// The desktop app — ChatGPT.app, which is what most people mean by "Codex"
    /// now — writes none of them; it keeps its threads here instead, with
    /// `source_kind = 'chatgpt'`. Watching only the rollouts meant the notch
    /// could never see the desktop app working at all.
    static var desktopStoreURL: URL {
        CodexProfile.default().desktopStoreURL
    }

    /// The most recently touched desktop thread: when, and what it is called.
    static func newestDesktopThread(in url: URL) -> (title: String, updatedAt: Date)? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }

        let rows = SQLiteStore.rows(
            in: db,
            sql: """
            SELECT source_updated_at, display_title, thread_id
            FROM local_thread_catalog ORDER BY source_updated_at DESC LIMIT 1
            """,
            columns: 3
        )
        guard let row = rows.first, let seconds = Double(row[0]) else { return nil }
        // Seconds since the epoch, with a fractional part — not the
        // milliseconds the `threads` table next door uses.
        let title = row[1].isEmpty ? "Codex" : row[1]
        return (title, Date(timeIntervalSince1970: seconds))
    }

    /// The rollout of the most recently touched thread.
    static func newestRollout(in store: URL) -> URL? {
        guard let db = SQLiteStore.open(store) else { return nil }
        defer { sqlite3_close(db) }

        let paths = SQLiteStore.rows(
            in: db,
            sql: "SELECT rollout_path FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 8"
        )
        return paths
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
