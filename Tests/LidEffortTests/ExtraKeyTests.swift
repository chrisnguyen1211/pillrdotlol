import XCTest
@testable import LidEffort

/// Extra API keys for GLM, MiniMax, Ollama and Apify: how they are named and
/// kept, which key each ring actually sends, how the store takes them in and
/// lets them go, and that Settings keeps a key only once it has been read.
/// Nothing here touches the real keychain — every secret is handed in.
@MainActor
final class ExtraKeyTests: XCTestCase {
    private var session: URLSession!
    private var archive: UsageArchive!

    override func setUpWithError() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExtraKeyEndpoint.self]
        session = URLSession(configuration: config)
        ExtraKeyEndpoint.reset { _ in (500, Data()) }
        archive = UsageArchive(defaults: isolatedDefaults())
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        ExtraKeyEndpoint.reset { _ in (500, Data()) }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "ExtraKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Persistence

    func testExtraKeysSurviveARelaunch() {
        let defaults = isolatedDefaults()
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.extraKeys, [])
        let work = ExtraKey(id: "glm-k1a2b3", base: "glm", name: "Work", region: "china")
        let side = ExtraKey(id: "apify-k00ff0", base: "apify", name: "Side", region: nil)
        preferences.disconnectedProviders.insert(work.id)
        preferences.addExtraKey(work)
        preferences.addExtraKey(side)
        XCTAssertTrue(preferences.isConnected(work.id), "a key just added starts on")

        let reopened = Preferences(defaults: defaults)
        XCTAssertEqual(reopened.extraKeys, [work, side])
        XCTAssertTrue(reopened.extraKeys[0].glmIsChina)
        XCTAssertTrue(reopened.renameExtraKey(id: work.id, to: "  Client "))
        XCTAssertEqual(Preferences(defaults: defaults).extraKeys.first?.name, "Client")
        XCTAssertTrue(Preferences(defaults: defaults).extraKeys.first?.displayName == "GLM · Client")
    }

    func testAStoredEntryThatIsNotAnExtraKeyIsDropped() throws {
        let defaults = isolatedDefaults()
        let bogus = [ExtraKey(id: "ollama-local", base: "ollama", name: "Nope", region: nil),
                     ExtraKey(id: "glm-k123ab", base: "minimax", name: "Mismatch", region: nil),
                     ExtraKey(id: "minimax-kabc12", base: "minimax", name: "Fine", region: "international")]
        defaults.set(try JSONEncoder().encode(bogus), forKey: "extraKeys")
        XCTAssertEqual(Preferences(defaults: defaults).extraKeys.map(\.id), ["minimax-kabc12"])
    }

    func testRenameRefusesAnEmptyOrTakenName() {
        let preferences = Preferences(defaults: isolatedDefaults())
        preferences.addExtraKey(ExtraKey(id: "glm-k00001", base: "glm", name: "Work", region: nil))
        preferences.addExtraKey(ExtraKey(id: "glm-k00002", base: "glm", name: "Home", region: nil))
        preferences.addExtraKey(ExtraKey(id: "ollama-k00003", base: "ollama", name: "Lab", region: nil))
        XCTAssertFalse(preferences.renameExtraKey(id: "glm-k00002", to: "work"))
        XCTAssertFalse(preferences.renameExtraKey(id: "glm-k00002", to: "   "))
        XCTAssertTrue(preferences.renameExtraKey(id: "glm-k00002", to: "Lab"), "names are unique per provider only")
    }

    func testRemovingForgetsTheKeyAndEveryChoiceAboutItsRing() {
        let preferences = Preferences(defaults: isolatedDefaults())
        let key = ExtraKey(id: "ollama-k0beef", base: "ollama", name: "Lab", region: nil)
        preferences.addExtraKey(key)
        preferences.setAlertsMuted(true, for: key.id)
        preferences.setProviderOrder(["claude", key.id, "ollama"])
        preferences.setConnected(false, for: key.id)
        var deleted: [String] = []

        ExtraKeyVerifier.remove(key.id, from: preferences, deleteSecret: { deleted.append($0) })

        XCTAssertEqual(deleted, [key.id])
        XCTAssertTrue(preferences.extraKeys.isEmpty)
        XCTAssertFalse(preferences.disconnectedProviders.contains(key.id))
        XCTAssertFalse(preferences.mutedAlertProviders.contains(key.id))
        XCTAssertFalse(preferences.providerOrder.contains(key.id))
        XCTAssertTrue(preferences.providerOrder.contains("ollama"))

        // A base id is never removed this way.
        ExtraKeyVerifier.remove("ollama", from: preferences, deleteSecret: { deleted.append($0) })
        XCTAssertEqual(deleted, [key.id])
    }

    // MARK: Identity

    func testIDsMapBackToTheBaseGlyphAndTarget() {
        for base in ExtraKey.bases {
            let id = ExtraKey.makeID(base: base)
            XCTAssertTrue(id.hasPrefix(base + "-"), id)
            XCTAssertEqual(ExtraKey.base(fromProviderID: id), base, id)
            XCTAssertEqual(EffortState.targetID(forProviderID: id), base, id)
            XCTAssertEqual(ProviderGlyph.forProvider(id), ProviderGlyph.forProvider(base), id)
            XCTAssertNotNil(ProviderGlyph.forProvider(id), id)
        }
        XCTAssertEqual(ProviderGlyph.forProvider("minimax-k12345"), .minimax)
        XCTAssertEqual(ProviderGlyph.forProvider("apify-k12345"), .apify)
        for other in ["glm", "ollama", "ollama-local", "ollama-local:model:qwen3:8b", "claude-work",
                      "codex-work", "gemini-api", "custom-endpoint-x", "glm-Work", "apify-k123"] {
            XCTAssertNil(ExtraKey.base(fromProviderID: other), other)
        }
    }

    func testSlugsAreShortLowercaseAndCollisionFree() {
        for _ in 0..<50 {
            let slug = ExtraKey.randomSlug()
            XCTAssertEqual(slug.count, 6)
            XCTAssertTrue(slug.hasPrefix("k"))
            XCTAssertEqual(slug, slug.lowercased())
            XCTAssertFalse(slug.contains("-"))
        }
        var slugs = ["k00001", "k00001", "k00002"]
        let existing = [ExtraKey(id: "glm-k00001", base: "glm", name: "A", region: nil)]
        XCTAssertEqual(ExtraKey.makeID(base: "glm", existing: existing, slug: { slugs.removeFirst() }), "glm-k00002")
    }

    func testDefaultNamesCountFromTwoAndSkipTakenOnes() {
        let existing = [ExtraKey(id: "glm-k00001", base: "glm", name: L10n.t("Key \(2)"), region: nil),
                        ExtraKey(id: "apify-k00002", base: "apify", name: L10n.t("Key \(3)"), region: nil)]
        XCTAssertEqual(ExtraKey.defaultName(base: "glm", existing: existing), L10n.t("Key \(3)"))
        XCTAssertEqual(ExtraKey.defaultName(base: "apify", existing: existing), L10n.t("Key \(2)"))
        XCTAssertEqual(ExtraKey.displayName(base: "minimax", name: "Work"), "MiniMax · Work")
    }

    // MARK: Each provider sends the key it was given

    func testGLMExtraKeySendsItsOwnKeyToItsOwnConsole() async throws {
        ExtraKeyEndpoint.reset { _ in (200, Data(Self.glmBody.utf8)) }
        let extra = ExtraKey(id: "glm-k00aa1", base: "glm", name: "Work", region: "china")
        let provider = try XCTUnwrap(ExtraKeyProviders.make(extra, session: session, archive: archive,
                                                            secret: { "glm-extra-secret" }))
        let snapshot = try await provider.fetchSnapshot(freshness: .fromSource)
        XCTAssertEqual(snapshot.id, "glm-k00aa1")
        XCTAssertEqual(snapshot.displayName, "GLM · Work")
        XCTAssertEqual(snapshot.glyph, .glm)
        let request = try XCTUnwrap(ExtraKeyEndpoint.requests.first)
        XCTAssertEqual(request.url?.host, "open.bigmodel.cn")
        XCTAssertEqual(request.url?.path, "/api/monitor/usage/quota/limit")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "glm-extra-secret")
        XCTAssertEqual(provider.account()?.source, "pillr")
        XCTAssertEqual(provider.signInRoute, .guidance(ExtraKey.signInGuidance))

        let global = try XCTUnwrap(ExtraKeyProviders.make(
            ExtraKey(id: "glm-k00aa2", base: "glm", name: "Home", region: "global"),
            session: session, archive: archive, secret: { "other" }))
        _ = try await global.fetchSnapshot()
        XCTAssertEqual(ExtraKeyEndpoint.requests.last?.url?.host, "api.z.ai")
    }

    func testMiniMaxExtraKeyUsesOnlyItsKeyAndRegion() async throws {
        ExtraKeyEndpoint.reset { _ in (200, Data(Self.minimaxBody.utf8)) }
        let extra = ExtraKey(id: "minimax-k00bb1", base: "minimax", name: "Team", region: "china")
        let provider = try XCTUnwrap(ExtraKeyProviders.make(extra, session: session, archive: archive,
                                                            secret: { "sk-cp-extra" }))
        let snapshot = try await provider.fetchSnapshot(freshness: .fromSource)
        XCTAssertEqual(snapshot.id, "minimax-k00bb1")
        XCTAssertEqual(snapshot.displayName, "MiniMax · Team")
        XCTAssertEqual(snapshot.fidelity, .official, "the key path, not a cookie")
        let request = try XCTUnwrap(ExtraKeyEndpoint.requests.first)
        XCTAssertEqual(request.url?.host, "api.minimaxi.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-cp-extra")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(provider.signInRoute, .guidance(ExtraKey.signInGuidance))

        // No key, no fallback to the base's cookie or web session.
        let empty = try XCTUnwrap(ExtraKeyProviders.make(extra, session: session, archive: archive, secret: { nil }))
        do {
            _ = try await empty.fetchSnapshot()
            XCTFail("an extra key with no key must not read anything")
        } catch UsageProviderError.needsAuth {}
        XCTAssertNil(empty.account())
    }

    func testOllamaExtraKeySendsItsOwnKey() async throws {
        ExtraKeyEndpoint.reset { _ in (200, Data(Self.ollamaBody.utf8)) }
        let extra = ExtraKey(id: "ollama-k00cc1", base: "ollama", name: "Lab", region: nil)
        let provider = try XCTUnwrap(ExtraKeyProviders.make(extra, session: session, archive: archive,
                                                            secret: { "ollama-extra" }))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "ollama-k00cc1")
        XCTAssertEqual(snapshot.displayName, "Ollama · Lab")
        XCTAssertEqual(snapshot.glyph, .ollama)
        let request = try XCTUnwrap(ExtraKeyEndpoint.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ollama.com/api/usage")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ollama-extra")
        XCTAssertEqual(provider.account()?.source, "pillr")
    }

    func testApifyExtraKeySendsItsOwnTokenAndBorrowsNoLogin() async throws {
        ExtraKeyEndpoint.reset { _ in (200, Data(ApifyFixture.limits.utf8)) }
        let extra = ExtraKey(id: "apify-k00dd1", base: "apify", name: "Client", region: nil)
        let provider = try XCTUnwrap(ExtraKeyProviders.make(extra, session: session, archive: archive,
                                                            secret: { "apify_api_extra" }))
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "apify-k00dd1")
        XCTAssertEqual(snapshot.displayName, "Apify · Client")
        let request = try XCTUnwrap(ExtraKeyEndpoint.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.apify.com/v2/users/me/limits")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer apify_api_extra")
        XCTAssertNil(provider.signInCommand, "Connect must not run apify login for an extra key")
        XCTAssertNotNil(provider.account())

        let empty = try XCTUnwrap(ExtraKeyProviders.make(extra, session: session, archive: archive, secret: { nil }))
        XCTAssertNil(empty.account(), "the CLI's login is never lent to an extra key")
        do {
            _ = try await empty.fetchSnapshot()
            XCTFail("an extra key with no token must not read anything")
        } catch UsageProviderError.needsAuth {}
    }

    func testTheBaseProvidersKeepTheirOwnIdentity() {
        XCTAssertEqual(GLMProvider(session: session, archive: archive).id, "glm")
        XCTAssertEqual(GLMProvider(session: session, archive: archive).displayName, "GLM")
        XCTAssertEqual(MiniMaxProvider(session: session, archive: archive).id, "minimax")
        XCTAssertEqual(OllamaProvider(session: session).id, "ollama")
        XCTAssertEqual(ApifyProvider(session: session, archive: archive).id, "apify")
        XCTAssertEqual(ApifyProvider(session: session, archive: archive).signInCommand, "apify login")
    }

    // MARK: The store

    func testTheStoreTakesExtraKeysInAndLetsThemGo() async throws {
        let base = StubProvider(id: "glm", name: "GLM")
        let store = UsageStore(providers: [base], archive: archive)
        await store.refresh()
        XCTAssertEqual(store.snapshots.map(\.id), ["glm"])
        let revision = store.providerListRevision

        let work = StubProvider(id: "glm-k00ee1", name: "GLM · Work")
        store.registerExtraKeyProviders([work])
        XCTAssertEqual(store.providerIDs, ["glm", "glm-k00ee1"])
        XCTAssertEqual(store.snapshots.map(\.id), ["glm", "glm-k00ee1"], "drawn at once, before its reading")
        XCTAssertGreaterThan(store.providerListRevision, revision)
        await store.refresh(providerID: work.id)?.value
        XCTAssertEqual(work.calls, 1, "a new key is read straight away")
        XCTAssertTrue(store.snapshots.first { $0.id == work.id }?.hasReading ?? false)
        XCTAssertEqual(store.providerSummaries.map(\.name), ["GLM", "GLM · Work"])

        // Renamed: same id, new provider. The reading stays, the title follows.
        let renamed = StubProvider(id: "glm-k00ee1", name: "GLM · Client")
        store.registerExtraKeyProviders([renamed])
        XCTAssertEqual(store.snapshots.first { $0.id == work.id }?.displayName, "GLM · Client")
        XCTAssertTrue(store.snapshots.first { $0.id == work.id }?.hasReading ?? false)
        XCTAssertEqual(renamed.calls, 0, "a rename is not a reason to read again")

        store.registerExtraKeyProviders([])
        XCTAssertEqual(store.providerIDs, ["glm"])
        XCTAssertEqual(store.snapshots.map(\.id), ["glm"])
        XCTAssertNil(archive.load()[work.id], "a removed key's reading is not remembered")
        XCTAssertEqual(base.calls, 1, "the base ring is left alone")
    }

    func testASwitchedOffExtraKeyIsRegisteredButNotRead() async {
        let store = UsageStore(providers: [], archive: archive, disconnected: ["ollama-k00ff1"])
        let lab = StubProvider(id: "ollama-k00ff1", name: "Ollama · Lab")
        store.registerExtraKeyProviders([lab])
        XCTAssertEqual(store.providerIDs, ["ollama-k00ff1"])
        XCTAssertTrue(store.snapshots.isEmpty)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(lab.calls, 0)
    }

    // MARK: Adding one from Settings

    func testAKeyThatReadsIsKept() async {
        var stored: [(String, String)] = []
        var checked: ExtraKey?
        let outcome = await ExtraKeyVerifier.add(
            base: "glm", name: "  ", key: " the-key \n", region: "china", existing: [],
            makeID: { base, _ in "\(base)-k0aaa1" },
            makeProvider: { extra, key in
                checked = extra
                XCTAssertEqual(key, "the-key")
                return StubProvider(id: extra.id, name: extra.displayName)
            },
            storeSecret: { stored.append(($0, $1)); return true })

        let expected = ExtraKey(id: "glm-k0aaa1", base: "glm", name: L10n.t("Key \(2)"), region: "china")
        XCTAssertEqual(outcome, .added(expected))
        XCTAssertEqual(checked, expected)
        XCTAssertEqual(stored.map(\.0), ["glm-k0aaa1"])
        XCTAssertEqual(stored.map(\.1), ["the-key"])
    }

    func testAKeyThatIsRefusedIsNotKept() async {
        var stored = 0
        let outcome = await ExtraKeyVerifier.add(
            base: "ollama", name: "Lab", key: "bad", region: nil, existing: [],
            makeProvider: { extra, _ in StubProvider(id: extra.id, name: extra.displayName, error: .needsAuth) },
            storeSecret: { _, _ in stored += 1; return true })
        XCTAssertEqual(outcome, .failed(L10n.t("That key was not accepted")))
        XCTAssertEqual(stored, 0)

        let throttled = await ExtraKeyVerifier.add(
            base: "ollama", name: "Lab", key: "maybe", region: nil, existing: [],
            makeProvider: { extra, _ in
                StubProvider(id: extra.id, name: extra.displayName, error: .rateLimited(retryAfter: 60))
            },
            storeSecret: { _, _ in stored += 1; return true })
        XCTAssertEqual(throttled, .failed(L10n.t("Couldn't check the key just now. Try again in a minute")),
                       "a throttle proves nothing about the key")
        XCTAssertEqual(stored, 0)
    }

    func testATakenNameOrAnEmptyKeyIsRefusedBeforeAnythingIsAsked() async {
        var asked = 0
        let existing = [ExtraKey(id: "apify-k0bbb1", base: "apify", name: "Work", region: nil)]
        let make: (ExtraKey, String) -> UsageProvider? = { extra, _ in
            asked += 1
            return StubProvider(id: extra.id, name: extra.displayName)
        }
        let taken = await ExtraKeyVerifier.add(base: "apify", name: "work", key: "k", region: nil,
                                               existing: existing, makeProvider: make,
                                               storeSecret: { _, _ in XCTFail("nothing to keep"); return true })
        XCTAssertEqual(taken, .failed(L10n.t("There is already a key called \("work")")))
        let empty = await ExtraKeyVerifier.add(base: "apify", name: "Other", key: "  ", region: nil,
                                               existing: existing, makeProvider: make,
                                               storeSecret: { _, _ in XCTFail("nothing to keep"); return true })
        XCTAssertEqual(empty, .failed(L10n.t("Paste a key first")))
        XCTAssertEqual(asked, 0)
    }

    func testVerificationReadsWithTheKeyBeingAdded() async throws {
        ExtraKeyEndpoint.reset { _ in (200, Data(Self.ollamaBody.utf8)) }
        var stored: String?
        let outcome = await ExtraKeyVerifier.add(
            base: "ollama", name: "Lab", key: "fresh-key", region: nil, existing: [],
            makeProvider: { [session, archive] extra, key in
                ExtraKeyProviders.make(extra, session: session!, archive: archive!, secret: { key })
            },
            storeSecret: { _, key in stored = key; return true })
        guard case .added(let extra) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(extra.displayName, "Ollama · Lab")
        XCTAssertEqual(stored, "fresh-key")
        XCTAssertEqual(ExtraKeyEndpoint.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-key")

        ExtraKeyEndpoint.reset { _ in (401, Data()) }
        stored = nil
        let refused = await ExtraKeyVerifier.add(
            base: "ollama", name: "Lab", key: "dead-key", region: nil, existing: [],
            makeProvider: { [session, archive] extra, key in
                ExtraKeyProviders.make(extra, session: session!, archive: archive!, secret: { key })
            },
            storeSecret: { _, key in stored = key; return true })
        XCTAssertEqual(refused, .failed(L10n.t("That key was not accepted")))
        XCTAssertNil(stored)
    }

    func testTheNewWordsAreTranslated() {
        for code in ["fr", "ja", "pt-BR", "ru", "zh-Hans"] {
            let locale = Locale(identifier: code)
            XCTAssertNotEqual(L10n.t("Add another key", locale: locale), "Add another key", code)
            XCTAssertNotEqual(L10n.t("Remove", locale: locale), "Remove", code)
            let named = L10n.t("There is already a key called \("Work")", locale: locale)
            XCTAssertTrue(named.contains("Work"), named)
            XCTAssertNotEqual(named, "There is already a key called Work", code)
            XCTAssertTrue(L10n.t("Key \(2)", locale: locale).contains("2"), code)
        }
    }

    // MARK: Fixtures

    private static let glmBody = """
    { "code": 200, "success": true, "msg": "",
      "data": { "level": "pro",
        "limits": [
          { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12.5,
            "nextResetTime": 1788682200000 } ] } }
    """

    private static let minimaxBody = """
    { "base_resp": { "status_code": 0 },
      "current_subscribe_title": "Max",
      "model_remains": [
        { "current_interval_total_count": 1000,
          "current_interval_usage_count": 250,
          "start_time": 1700000000000,
          "end_time": 1700018000000,
          "remains_time": 240000 } ] }
    """

    private static let ollamaBody = """
    { "limits": {
        "session": { "usage": 0.12, "models": [] },
        "weekly":  { "usage": 0.41, "models": [] } } }
    """
}

@MainActor
private final class StubProvider: UsageProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.glm
    let error: UsageProviderError?
    var calls = 0

    init(id: String, name: String, error: UsageProviderError? = nil) {
        self.id = id
        self.displayName = name
        self.error = error
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        calls += 1
        if let error { throw error }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok,
                                windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.3)])
    }
}

private final class ExtraKeyEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func reset(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.withLock { self.handler = handler; recorded = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.lock.withLock { () -> (Int, Data) in
            Self.recorded.append(request)
            return Self.handler(request)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
