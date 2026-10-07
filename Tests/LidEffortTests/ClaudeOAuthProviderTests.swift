import XCTest
@testable import LidEffort

/// The token path of `ClaudeOAuthProvider`.
///
/// It had no tests at all — only the pure helpers (`backoff`, `retryAfter`) were
/// covered — which is how a back-off that re-stamped itself on every failed tick
/// shipped and locked the provider until the app was restarted.
///
/// Every assertion here is about one question: **after a failure, does the next
/// tick actually go and ask again?** Hence the counters. Asserting on the returned
/// error is not enough — the broken version returned exactly the right error while
/// never touching the keychain or the network.
final class ClaudeOAuthProviderTests: XCTestCase {

    // MARK: - Back-off against the refresh tick

    /// A window that opens in 15ms is open. Refusing it does not delay the
    /// fetch by 15ms — the caller is a timer, so it delays it by a whole
    /// refresh interval, and the server's 60s penalty becomes 120s.
    func testAWindowAboutToOpenCountsAsOpen() {
        let now = Date()
        XCTAssertFalse(ClaudeOAuthProvider.shouldHoldOff(
            until: now.addingTimeInterval(0.015), slack: 1, now: now))
        XCTAssertFalse(ClaudeOAuthProvider.shouldHoldOff(
            until: now.addingTimeInterval(0.42), slack: 1, now: now))
    }

    func testARealPenaltyIsStillHonoured() {
        let now = Date()
        XCTAssertTrue(ClaudeOAuthProvider.shouldHoldOff(
            until: now.addingTimeInterval(45), slack: 1, now: now))
    }

    func testNoPenaltyMeansNoHoldOff() {
        XCTAssertFalse(ClaudeOAuthProvider.shouldHoldOff(until: nil, slack: 1))
    }

    override func tearDown() {
        StubEndpoint.reset([])
        super.tearDown()
    }

    /// A 401 must not stop the next tick from trying.
    ///
    /// The endpoint rejects the token and then starts answering again — a token
    /// rotated behind the app's back. This is the manual repro (a local server
    /// switched from 401 to 200) reduced to a test.
    func testA401DoesNotStopTheNextTickFromTrying() async throws {
        StubEndpoint.reset([
            .init(status: 401),                       // the tick's first attempt
            .init(status: 401),                       // its one retry on unauthorized
            .init(status: 200, body: Self.usagePayload)
        ])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source)

        await assertNeedsAuth(from: provider)
        XCTAssertEqual(StubEndpoint.requestCount, 2, "the retry on 401 did not happen")

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(StubEndpoint.requestCount, 3,
                       "the next tick never reached the endpoint")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows.first?.id, "session")
    }

    /// A keychain read that failed must not stop the next tick from reading again.
    ///
    /// This is what happened in the field: the Mac was in dark wake, the keychain
    /// answered `-25320` ("no UI possible"), and that fell through to `needsAuth`.
    /// The credential was readable again seconds later; the provider never looked.
    func testAKeychainFailureDoesNotStopTheNextTickFromReading() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: false)
        let provider = makeProvider(source: source)

        await assertNeedsAuth(from: provider)
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(StubEndpoint.requestCount, 0,
                       "it went to the network without a token")

        source.makeReadable()   // the machine woke up

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(source.reads, 2, "the next tick never went back to the keychain")
        XCTAssertEqual(snapshot.status, .ok)
    }

    /// Failing repeatedly must not become failing silently.
    ///
    /// The bug's signature was a request count frozen at two while the poll kept
    /// firing every 60 seconds. Three ticks against a rejecting endpoint have to
    /// produce three attempts, not one.
    func testItKeepsAskingWhileTheEndpointKeepsRejecting() async {
        StubEndpoint.reset(Array(repeating: .init(status: 401), count: 6))
        let provider = makeProvider(source: CredentialSource(readable: true))

        for _ in 0..<3 { await assertNeedsAuth(from: provider) }

        XCTAssertEqual(StubEndpoint.requestCount, 6,
                       "the provider stopped asking after the first failure")
    }

    // MARK: - Helpers

    private static let usagePayload = Data("""
    {"limits":[{"kind":"session","percent":42,"resets_at":"2099-01-01T00:00:00Z"}]}
    """.utf8)

    private func makeProvider(source: CredentialSource,
                              cli: ClaudeUsageCLI? = nil,
                              cliRefreshInterval: TimeInterval = 5 * 60,
                              profile: ClaudeProfile = .default(),
                              desktopCache: ClaudeDesktopUsageCache? = nil,
                              desktopFreshness: TimeInterval = 30 * 60,
                              desktopRescanInterval: TimeInterval = 5 * 60) -> ClaudeOAuthProvider {
        // A private defaults suite per test: the archive persists the 429 back-off
        // deadline, and a leaked one would silently skip fetches in the next test.
        let name = "ClaudeOAuthProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        // No CLI, because these are the token path's tests. Left to find one,
        // the provider would answer off `claude "/usage"` on a machine that has
        // Claude Code installed and off the endpoint on one that does not, and
        // every assertion below about retries and back-off would depend on the
        // developer's own setup rather than on the code.
        // No desktop cache by default, for exactly the reason there is no CLI by
        // default: left to find the real one, these tests would answer off
        // whatever Claude Desktop happened to have cached on the machine running
        // them, and every assertion about retries and back-off would depend on
        // the developer's own setup rather than on the code.
        return ClaudeOAuthProvider(profile: profile,
                                   session: StubEndpoint.session(),
                                   archive: UsageArchive(defaults: defaults),
                                   loadCredentials: { try source.read() },
                                   cli: cli,
                                   cliRefreshInterval: cliRefreshInterval,
                                   desktopCache: desktopCache,
                                   desktopFreshness: desktopFreshness,
                                   desktopRescanInterval: desktopRescanInterval)
    }

    // MARK: - The CLI path

    /// The point of the whole thing: when `claude "/usage"` answers, nothing
    /// asks macOS for a credential and nothing calls the endpoint.
    ///
    /// Counting is the only way to know. A provider that read the keychain and
    /// then threw the result away would return exactly the same snapshot, and
    /// the keychain prompt this exists to avoid would still have appeared.
    func testAWorkingCLIMeansNoKeychainReadAndNoRequest() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, cli: Self.cli(answering: Self.cliUsage))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(source.reads, 0, "the keychain was read even though the CLI answered")
        XCTAssertEqual(StubEndpoint.requestCount, 0, "the endpoint was called even though the CLI answered")
    }

    /// A CLI that cannot answer is a reason to ask the endpoint, never a reason
    /// to fail the refresh — otherwise installing Claude Code and signing out
    /// of it would take the ring down on a machine whose token is fine.
    func testAFailingCLIFallsBackToTheToken() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source,
                                    cli: Self.cli(answering: "Please run /login first"))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.first?.id, "session")
        XCTAssertEqual(source.reads, 1, "the token path was not reached")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// `UsageStore` polls every 60s while a session is busy, and each ask is a
    /// subprocess. The windows do not move enough in a minute to be worth one.
    func testTheCLIIsNotSpawnedOnEveryTick() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage })

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 1, "the CLI was spawned again inside its own interval")
    }

    /// And it is asked again once the interval has passed, or the ring would
    /// show one reading for the rest of the session.
    func testTheCLIIsAskedAgainOnceTheIntervalPasses() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    cliRefreshInterval: 0)

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 2)
    }

    // MARK: - The Claude Desktop cache path

    /// Why the whole source exists. On this machine `claude "/usage"` prints a
    /// cost summary and no windows at all, and the keychain token has not been
    /// re-minted since Claude Code last ran — so both existing paths fail while
    /// Claude Desktop sits there displaying the real numbers. Reading its cache
    /// has to be enough on its own, without a keychain read and without a request.
    func testAFreshDesktopSnapshotNeedsNoKeychainAndNoRequest() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(snapshot.usedFraction, 0.30, "the headline is not Desktop's session window")
        XCTAssertEqual(source.reads, 0, "the keychain was read even though the cache answered")
        XCTAssertEqual(StubEndpoint.requestCount, 0,
                       "the endpoint was called even though the cache answered")
    }

    /// Desktop is preferred over the CLI, not merely over the token: it is the
    /// cheaper of the two and cannot be refused, and on the machine this was
    /// written for the CLI is the source that lies by omission.
    func testDesktopIsPreferredOverTheCLI() async throws {
        let spawns = Counter()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        // 30% is Desktop's; 38% would be the CLI's.
        XCTAssertEqual(snapshot.usedFraction, 0.30)
        XCTAssertEqual(spawns.value, 0, "a subprocess was spawned even though the cache answered")
    }

    /// The honesty requirement. Once Desktop stops updating, its numbers may not
    /// keep being presented as live — so a snapshot past the window is not
    /// returned at all, and the existing sources take over. Whatever the last
    /// good reading was is then `UsageStore`'s to re-show, dimmed and dated.
    func testAStaleDesktopSnapshotFallsThroughToTheExistingSources() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 4 * 3600))

        let snapshot = try await provider.fetchSnapshot()

        // The endpoint's fixture is 42%; Desktop's stale one is 30%.
        XCTAssertEqual(snapshot.usedFraction, 0.42, "a stale cache reading was shown as live")
        XCTAssertEqual(source.reads, 1, "the token path was not reached")
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// Claude Desktop is signed into one account; pillr draws a ring per
    /// Claude Code profile. A profile whose organization does not match the
    /// cached URL gets nothing from Desktop — the alternative is the personal
    /// account's session percentage on the work ring.
    func testACacheForAnotherOrganizationIsNotUsed() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let provider = makeProvider(
            source: source,
            profile: desktopProfile(organization: "99999999-8888-7777-6666-555555555555"),
            desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42, "another account's reading reached this ring")
        XCTAssertEqual(source.reads, 1)
    }

    /// A profile Claude Code has never signed in to has no organization to match
    /// on, and must not fall back to "whatever is in the cache".
    func testAProfileWithNoRecordedOrganizationIsNotMatched() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pillr-nohome-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider(source: source, profile: .default(home: home),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42)
        XCTAssertEqual(source.reads, 1)
    }

    /// With no Claude Desktop at all — no directory, nothing cached — the
    /// provider behaves exactly as it did before this source existed.
    func testNoDesktopCacheLeavesTheOldBehaviourIntact() async throws {
        StubEndpoint.reset([.init(status: 200, body: Self.usagePayload)])
        let source = CredentialSource(readable: true)
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pillr-absent-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider(source: source, profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: absent))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42)
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(StubEndpoint.requestCount, 1)
    }

    /// `UsageStore` polls every 60s while a session is busy, and a miss means a
    /// scan of a few thousand directory entries. Missing once must not mean
    /// scanning on every tick afterwards.
    ///
    /// Asserted by behaviour rather than by counting: an entry that appears
    /// during the interval is not picked up, which is only true if no scan
    /// happened. It is also the cost of the throttle, stated plainly — a Desktop
    /// that has just started writing again waits out one interval.
    func testAMissSuppressesTheNextScan() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 3))
        let directory = makeCacheDirectory()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory))

        // Nothing cached yet: a miss, which arms the throttle.
        _ = try await provider.fetchSnapshot()
        writeUsageEntry(into: directory, age: 0)

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction, 0.42, "the cache was rescanned inside the interval")
    }

    /// And the scan does happen once the interval has passed, or a Desktop that
    /// comes back would never be noticed.
    func testTheScanHappensAgainOnceTheIntervalPasses() async throws {
        StubEndpoint.reset(Array(repeating: .init(status: 200, body: Self.usagePayload), count: 3))
        let directory = makeCacheDirectory()
        let provider = makeProvider(source: CredentialSource(readable: true),
                                    profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory),
                                    desktopRescanInterval: 0)

        _ = try await provider.fetchSnapshot()
        writeUsageEntry(into: directory, age: 0)

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction, 0.30, "the cache was never looked at again")
    }

    // MARK: - Desktop helpers

    /// A profile whose `.claude.json` records `organization`, so the provider has
    /// something to match a cache entry against. Nothing else about it is real.
    private func desktopProfile(
        organization: String = ClaudeDesktopUsageCacheTests.organization
    ) -> ClaudeProfile {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pillr-home-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"emailAddress":"someone@example.com","organizationUuid":"\#(organization)"}}"#
        try? Data(json.utf8).write(to: home.appendingPathComponent(".claude.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return .default(home: home)
    }

    /// A cache directory holding one usage entry, written `age` seconds ago.
    private func desktopCache(age: TimeInterval) -> ClaudeDesktopUsageCache {
        let directory = makeCacheDirectory()
        writeUsageEntry(into: directory, age: age)
        return ClaudeDesktopUsageCache(directory: directory)
    }

    /// An empty throwaway directory shaped like `Cache_Data`.
    private func makeCacheDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pillr-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeUsageEntry(into directory: URL, age: TimeInterval) {
        var entry = ClaudeDesktopUsageCacheTests.Entry()
        // No `Date:` header, so the entry's modification time is what dates it —
        // which is the half a test can control.
        entry.responseDate = nil
        let file = directory.appendingPathComponent("entry_0")
        try? entry.data().write(to: file)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    private static let cliUsage = """
    Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
    Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)
    """

    private static func cli(answering text: String) -> ClaudeUsageCLI {
        cli { text }
    }

    private static func cli(_ answer: @escaping @Sendable () -> String) -> ClaudeUsageCLI {
        // The path is never run — `output` is what the provider reaches.
        ClaudeUsageCLI(binary: URL(fileURLWithPath: "/nonexistent/claude")) { _ in answer() }
    }

    private func assertNeedsAuth(from provider: ClaudeOAuthProvider,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth, got a snapshot", file: file, line: line)
        } catch UsageProviderError.needsAuth {
            // expected
        } catch {
            XCTFail("expected needsAuth, got \(error)", file: file, line: line)
        }
    }
}

/// How many times the CLI was actually asked. "Did it spawn again?" is the
/// question the throttle exists to answer, and only a count answers it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Stands in for the keychain, and counts reads.
///
/// "Did it go back and ask?" is the whole question, and only a counter answers it.
private final class CredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var readable: Bool
    private var readCount = 0

    init(readable: Bool) { self.readable = readable }

    var reads: Int {
        lock.lock(); defer { lock.unlock() }
        return readCount
    }

    func makeReadable() {
        lock.lock(); readable = true; lock.unlock()
    }

    func read() throws -> ClaudeCredentials {
        lock.lock()
        readCount += 1
        let allowed = readable
        lock.unlock()

        // The shape a dark-wake or not-found read takes by the time it leaves
        // `ClaudeCredentials.read()`.
        guard allowed else { throw UsageProviderError.needsAuth }
        return ClaudeCredentials(accessToken: "token",
                                 expiresAt: .distantFuture,
                                 subscriptionType: "max")
    }
}

/// Canned answers for the usage endpoint, and a count of how many requests
/// actually arrived. The repo had no URL stubbing, which is why nothing above
/// `retryAfter(from:)` was ever tested.
private final class StubEndpoint: URLProtocol {
    struct Answer {
        let status: Int
        var body: Data = Data()
    }

    private static let lock = NSLock()
    private static var queued: [Answer] = []
    private static var served = 0

    static func reset(_ answers: [Answer]) {
        lock.lock(); queued = answers; served = 0; lock.unlock()
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubEndpoint.self]
        return URLSession(configuration: configuration)
    }

    private static func next() -> Answer {
        lock.lock(); defer { lock.unlock() }
        served += 1
        // Running dry is a test bug, and a 500 says so more clearly than a crash
        // inside URLSession's callback would.
        return queued.isEmpty ? Answer(status: 500) : queued.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = Self.next()
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: answer.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `account()` must read through the injected credential source, like every
/// other read here.
///
/// It used to call the keychain directly, which made it impossible for a test
/// to build a real provider without touching the login keychain. On a test host
/// rebuilt with a fresh ad-hoc signature that means an authorization prompt,
/// and a prompt nobody answers hangs the whole suite — which is exactly what it
/// did, on `providerSummaries`.
final class ClaudeAccountSourceTests: XCTestCase {
    private func provider(_ load: @escaping @Sendable () throws -> ClaudeCredentials)
        -> ClaudeOAuthProvider {
        let name = "ClaudeAccountSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        // `cli: nil` as well as the injected source: `account()` answers from
        // Claude Code's own config where it can find it, so without this the
        // answer would come from whatever the developer has installed rather
        // than from the credential this test handed it.
        return ClaudeOAuthProvider(archive: UsageArchive(defaults: defaults),
                                   loadCredentials: load,
                                   cli: nil)
    }

    func testTheAccountComesFromTheInjectedSource() throws {
        var reads = 0
        let account = provider {
            reads += 1
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture,
                                     subscriptionType: "team")
        }.account()

        XCTAssertEqual(reads, 1, "the keychain must not be consulted behind our back")
        XCTAssertEqual(account?.plan, "team")
    }

    /// A source that has nothing is no account, and no crash.
    func testNoCredentialIsNoAccount() {
        XCTAssertNil(provider { throw UsageProviderError.needsAuth }.account())
    }
}

/// Only a person asking may raise the keychain dialogue.
///
/// Claude Code recreates its keychain item on every token rotation, and a new
/// item admits only Apple's own tools, so an app that is let in once is
/// refused again an hour later. Reading from a poll therefore raised the
/// password dialogue on a timer. Background reads must never prompt; the one
/// read that may is the one somebody clicked "Allow access…" for.
final class ClaudeKeychainPromptTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        var interactive: [Bool] = []
        var fails = false
    }

    private func keychain(_ reads: Reads) -> ClaudeKeychain {
        ClaudeKeychain(services: ["pillr-test-\(UUID().uuidString)"]) { _, interactive in
            reads.interactive.append(interactive)
            if reads.fails { throw UsageProviderError.accessDenied }
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture,
                                     subscriptionType: nil)
        }
    }

    func testABackgroundReadNeverPrompts() throws {
        let reads = Reads()
        _ = try keychain(reads).load()
        XCTAssertEqual(reads.interactive, [false])
    }

    /// The server rejecting a token, and the token refresher checking its
    /// work, both drop the cache too — and neither is a person.
    func testDroppingTheCacheOnItsOwnDoesNotPrompt() throws {
        let reads = Reads(), k = keychain(reads)
        _ = try k.load()
        k.forgetCached()
        _ = try k.load()
        XCTAssertEqual(reads.interactive, [false, false])
    }

    func testAskingAgainPromptsForTheNextReadOnly() throws {
        let reads = Reads(), k = keychain(reads)
        _ = try k.load()
        k.askAgain()
        _ = try k.load()
        k.forgetCached()
        _ = try k.load()
        XCTAssertEqual(reads.interactive, [false, true, false])
    }

    /// A Deny must not leave the permission lying around for the next poll to
    /// spend: the dialogue would then appear on a timer, which is the bug.
    func testADeniedPromptDoesNotLeaveTheNextPollAllowedToPrompt() {
        let reads = Reads(), k = keychain(reads)
        reads.fails = true
        k.askAgain()
        XCTAssertThrowsError(try k.load())
        k.forgetCached()
        XCTAssertThrowsError(try k.load())
        XCTAssertEqual(reads.interactive, [true, false])
    }
}

extension ClaudeKeychainPromptTests {
    /// An "Allow access…" whose refresh never reached the keychain — the CLI
    /// answered instead — must not be spent by a poll much later.
    func testAnUnspentPermissionExpires() throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        var interactive: [Bool] = []
        let k = ClaudeKeychain(services: ["pillr-test-\(UUID().uuidString)"],
                               now: { clock.now }) { _, flag in
            interactive.append(flag)
            return ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture, subscriptionType: nil)
        }
        k.askAgain()
        clock.now = clock.now.addingTimeInterval(ClaudeKeychain.promptWindow + 1)
        _ = try k.load()
        XCTAssertEqual(interactive, [false])
    }
}
