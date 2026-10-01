import Foundation

/// Reads Devin usage using the session owned by Devin Desktop or Devin CLI.
///
/// The cached quota in the Desktop database can lag behind the account, so
/// each refresh asks GetUserStatus instead. The session is read-only:
/// whichever tool owns sign-in and token rotation, spyx never refreshes
/// or writes its token.
actor DevinLocalProvider: UsageProvider {
    nonisolated let id = "devin"
    nonisolated let displayName = "Devin"
    nonisolated let glyph = ProviderGlyph.devin

    nonisolated private let store: URL
    nonisolated private let cliCredentials: URL
    private let session: URLSession
    private var retryNoEarlierThan: Date?

    init(database: URL = DevinCredentials.storeURL,
         cliCredentials: URL = DevinCredentials.cliCredentialsURL,
         session: URLSession = URLSession(configuration: .ephemeral,
                                          delegate: DevinRedirectPolicy(), delegateQueue: nil)) {
        self.store = database
        self.cliCredentials = cliCredentials
        self.session = session
    }

    nonisolated var isVisibleWhenAbsent: Bool {
        DevinCredentials.anySourceExists(desktop: store, cli: cliCredentials)
    }

    nonisolated var signInRoute: SignInRoute {
        DevinCredentials.signInRoute(
            desktopInstalled: FileManager.default.fileExists(atPath: store.path))
    }

    nonisolated func account() -> ProviderAccount? {
        DevinCredentials.account(from: store, fallbackCLI: cliCredentials)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let retryNoEarlierThan, retryNoEarlierThan > Date() {
            throw UsageProviderError.rateLimited(retryAfter: retryNoEarlierThan.timeIntervalSinceNow)
        }
        let auth = try DevinCredentials.load(from: store, fallbackCLI: cliCredentials)
        var request = URLRequest(
            url: URL(string: "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["apiKey": auth.apiKey, "ideName": "windsurf", "ideVersion": "1.108.2",
                         "extensionName": "windsurf", "extensionVersion": "1.108.2", "locale": "en"]
        ])
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { throw UsageProviderError.needsAuth }
        if status == 403 { throw UsageProviderError.accessDenied }
        if status == 429 {
            let hint = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
            let delay = hint.isFinite ? max(60, hint) : 60
            retryNoEarlierThan = Date().addingTimeInterval(delay)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard (200..<300).contains(status) else { throw UsageProviderError.badResponse(status: status) }
        let windows = try DevinUsage.windows(fromJSON: String(decoding: data, as: UTF8.self))
        retryNoEarlierThan = nil
        return ProviderSnapshot(
            id: id, displayName: displayName, glyph: glyph,
            fidelity: .official, status: .ok, windows: windows,
            headlineID: windows.first?.id, weeklyID: "weekly"
        )
    }
}

final class DevinRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
