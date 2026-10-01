import Foundation

/// LM Studio's loaded models, read from its own REST listing on the local
/// server. Nothing is loaded, unloaded or generated from here.
///
/// The token is optional on purpose. LM Studio ships with authentication off,
/// and a server that never asked for a token must not be sent one — the header
/// is added only when the user stored a token. A 401 then means the server does
/// require one and Settings says so; it is not a sign-out, because there is no
/// account here to be signed out of.
@MainActor
final class LMStudioLocalProvider: UsageProvider {
    nonisolated let id = LMStudioMetrics.providerID
    nonisolated let displayName = "LM Studio"
    nonisolated let glyph = ProviderGlyph.lmstudio
    nonisolated let kind = ProviderKind.localRuntime

    nonisolated var isVisibleWhenAbsent: Bool { false }
    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "ai.elementlabs.lmstudio", name: "LM Studio")
    }

    var endpoint: URL {
        didSet { if endpoint != oldValue { cached = nil } }
    }
    private let session: URLSession
    private let token: () -> String?
    private let inventoryInterval: TimeInterval
    private let now: () -> Date
    private var cached: (at: Date, snapshot: ProviderSnapshot)?

    /// `inventoryInterval`: the store asks every local runtime once a second,
    /// and LM Studio writes a line to its own server log for every listing it
    /// answers — 86,000 lines a day for a question whose answer changes a few
    /// times a day. A listing this old is answered from memory instead.
    init(endpoint: URL = URL(string: LMStudioEndpoint.defaultAddress)!, session: URLSession? = nil,
         token: @escaping () -> String? = { LMStudioCredentials.load() },
         inventoryInterval: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        self.endpoint = endpoint
        self.session = session ?? OllamaLocalProvider.makeSession()
        self.token = token
        self.inventoryInterval = inventoryInterval
        self.now = now
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        if let cached, now().timeIntervalSince(cached.at) < inventoryInterval { return cached.snapshot }
        let snapshot = try await fetchListing()
        cached = (now(), snapshot)
        return snapshot
    }

    private func fetchListing() async throws -> ProviderSnapshot {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/v1/models"))
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LMStudioError.unavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw LMStudioError.needsToken }
        guard status == 200 else { throw LMStudioError.http(status) }
        let reading = try LMStudioUsage.parse(data)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: [],
                                kind: kind, localRuntime: reading)
    }
}
