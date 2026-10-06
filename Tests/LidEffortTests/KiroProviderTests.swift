// Ported from Codenotch (MIT).
import SQLite3
import XCTest
@testable import LidEffort

/// Contract for `KiroProvider`'s injectable surface.
///
/// Production `KiroProvider()` may default these. Tests always inject so they
/// never spawn kiro-cli, never hit a live host, never write kiro-cli's sqlite,
/// and never share `UserDefaults.standard` with the rest of the suite.
///
///     KiroProvider(
///         session: URLSession,
///         cli: @escaping @Sendable () throws -> String,
///         database: URL,
///         archive: UsageArchive,
///         authURL: URL
///     )
///
/// `cli` may be wrapped as `KiroUsageCLI(binary:output:)` — the injected
/// value is still an output closure, never a live process. `authURL` is the
/// GetUsageLimits endpoint the stub answers for.
final class KiroProviderTests: XCTestCase {

    override func tearDown() {
        KiroEndpoint.reset([])
        super.tearDown()
    }

    /// `kiro-cli chat --no-interactive "/usage"` for a Free plan at 25%.
    /// The bar and the "X of Y covered in plan" line are the two readings
    /// the CLI actually prints; the ring is the percentage.
    private static let freeFixture = """
    | KIRO FREE |
    ████████████████████████████████████████████████████ 25%
    (12.50 of 50 covered in plan), resets on 01/15
    """

    private static let loggedOutFixture = """
    Not logged in. Run kiro-cli login.
    """

    /// Distinct from the CLI's 12.50/50 so a snapshot that kept the CLI
    /// fraction cannot pass as enrichment.
    private static let planUsed = 8
    private static let planLimit = 40

    /// Paid card with a bonus wallet. Enrichment must not drop that window.
    private static let proBonusFixture = """
    | KIRO PRO |
    ████████████████████████████████████████████████████ 80%
    (40.00 of 50 covered in plan), resets on 02/01
    Bonus credits: 5.00/10 credits used, expires in 7 days
    """

    private static let authURL = URL(string: "https://kiro.test/GetUsageLimits")!

    private static var usageLimitsJSON: String {
        """
        {"planUsed":\(planUsed),"planLimit":\(planLimit),"nextDateReset":1788220800,\
        "subscriptionInfo":{"subscriptionTitle":"Kiro Free","type":"FREE"},\
        "usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":\(planUsed),\
        "usageLimitWithPrecision":\(planLimit),"currentOveragesWithPrecision":0,"bonuses":[]}]}
        """
    }

    func testTheCLIFreeFixtureFillsCreditsWithoutHTTP() async throws {
        KiroEndpoint.reset([])
        let provider = makeProvider(cli: { Self.freeFixture }, database: missingDatabase())

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(KiroEndpoint.requestCount, 0, "CLI output is enough; GetUsageLimits is enrichment")
        let credits = try XCTUnwrap(creditsWindow(in: snapshot))
        XCTAssertEqual(credits.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.plan, "Kiro Free")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.id, "kiro")
        XCTAssertEqual(snapshot.glyph, .kiro)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.headlineID, "credits")
        XCTAssertNil(snapshot.weeklyID)
    }

    /// Bonus is a tooltip wallet. Putting it on `weeklyID` would draw a second
    /// ring for a number that is not a week.
    func testBonusDoesNotBecomeAWeeklyRing() async throws {
        KiroEndpoint.reset([])
        let bonus = """
        | KIRO PRO |
        ████████████████████████████████████████████████████ 80%
        (40.00 of 50 covered in plan), resets on 02/01
        Bonus credits: 5.00/10 credits used, expires in 7 days
        """
        let provider = makeProvider(cli: { bonus }, database: missingDatabase())

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["credits", "bonus"])
        XCTAssertEqual(snapshot.headlineID, "credits")
        XCTAssertNil(snapshot.weeklyID)
        XCTAssertNil(snapshot.weeklyWindow)
        XCTAssertNil(snapshot.weeklyFraction)
    }

    func testGetUsageLimitsEnrichesCreditsFromPlanUsedAndPlanLimit() async throws {
        KiroEndpoint.reset([(200, Self.usageLimitsJSON)])
        let database = try makeDatabase()
        let provider = makeProvider(cli: { Self.freeFixture }, database: database)

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertGreaterThanOrEqual(KiroEndpoint.requestCount, 1)
        XCTAssertEqual(KiroEndpoint.lastURL?.host, Self.authURL.host)
        XCTAssertTrue(
            KiroEndpoint.lastURL?.absoluteString.contains("GetUsageLimits") == true,
            "enrichment must call the injected GetUsageLimits URL, got \(String(describing: KiroEndpoint.lastURL))"
        )
        let credits = try XCTUnwrap(creditsWindow(in: snapshot))
        XCTAssertEqual(
            credits.usedFraction ?? -1,
            Double(Self.planUsed) / Double(Self.planLimit),
            accuracy: 0.0001
        )
        XCTAssertEqual(try XCTUnwrap(credits.used), Self.planUsed)
        XCTAssertEqual(snapshot.plan, "Kiro Free")
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testALoggedOutCLIIsNeedsAuth() async throws {
        KiroEndpoint.reset([])
        let provider = makeProvider(cli: { Self.loggedOutFixture }, database: missingDatabase())

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth")
        } catch UsageProviderError.needsAuth {
            // expected
        }
        XCTAssertEqual(KiroEndpoint.requestCount, 0)
    }

    func testAGetUsageLimitsFailureKeepsTheCLIWindows() async throws {
        KiroEndpoint.reset([(500, "")])
        let provider = makeProvider(cli: { Self.freeFixture }, database: try makeDatabase())

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertGreaterThanOrEqual(KiroEndpoint.requestCount, 1)
        let credits = try XCTUnwrap(creditsWindow(in: snapshot))
        XCTAssertEqual(credits.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.plan, "Kiro Free")
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testARateLimitKeepsTheCLIWindows() async throws {
        KiroEndpoint.reset([(429, "")])
        let provider = makeProvider(cli: { Self.freeFixture }, database: try makeDatabase())

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertGreaterThanOrEqual(KiroEndpoint.requestCount, 1)
        let credits = try XCTUnwrap(creditsWindow(in: snapshot))
        XCTAssertEqual(credits.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.status, .ok)

        // Back-off is enrichment-only. A second tick must still return the
        // CLI numbers, not throw `rateLimited` and blank the ring.
        let again = try await provider.fetchSnapshot()
        XCTAssertEqual(creditsWindow(in: again)?.usedFraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(again.status, .ok)
        XCTAssertEqual(KiroEndpoint.requestCount, 1, "a 429 must not be retried on the next tick")
    }

    func testEnrichmentDoesNotDropTheCLIBonusWallet() async throws {
        KiroEndpoint.reset([(200, Self.usageLimitsJSON)])
        let provider = makeProvider(cli: { Self.proBonusFixture }, database: try makeDatabase())

        let snapshot = try await provider.fetchSnapshot()

        let credits = try XCTUnwrap(creditsWindow(in: snapshot))
        XCTAssertEqual(
            credits.usedFraction ?? -1,
            Double(Self.planUsed) / Double(Self.planLimit),
            accuracy: 0.0001
        )
        let bonus = try XCTUnwrap(snapshot.windows.first { $0.id == "bonus" })
        XCTAssertEqual(bonus.usedFraction ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bonus.remaining, 5)
        XCTAssertNil(snapshot.weeklyID)
        XCTAssertEqual(snapshot.plan, "Kiro Pro")
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testUnseparatedAPIBonusLeavesTheCLICreditsStanding() async throws {
        let json = Self.usageLimitsJSON.replacingOccurrences(
            of: "\"bonuses\":[]",
            with: "\"bonuses\":[{}]"
        )
        KiroEndpoint.reset([(200, json)])
        let provider = makeProvider(cli: { Self.proBonusFixture }, database: try makeDatabase())

        let snapshot = try await provider.fetchSnapshot()

        let credits = try XCTUnwrap(creditsWindow(in: snapshot))
        XCTAssertEqual(credits.usedFraction ?? -1, 0.80, accuracy: 0.0001)
        XCTAssertNotNil(snapshot.windows.first { $0.id == "bonus" })
        XCTAssertNil(snapshot.weeklyID)
    }

    func testAMissingCLIIsNotASignInPrompt() async {
        KiroEndpoint.reset([])
        let provider = makeProvider(database: missingDatabase(), locateBinary: { nil })

        XCTAssertFalse(provider.isVisibleWhenAbsent)
        XCTAssertNil(provider.account())
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected nothingMetered")
        } catch UsageProviderError.nothingMetered {
            // expected
        } catch {
            XCTFail("missing kiro-cli must not be \(error)")
        }
        XCTAssertEqual(KiroEndpoint.requestCount, 0)
    }

    func testTheInjectedDatabaseBytesDoNotChange() async throws {
        KiroEndpoint.reset([(500, "")])
        let database = try makeDatabase()
        let before = try Data(contentsOf: database)
        let provider = makeProvider(cli: { Self.freeFixture }, database: database)

        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(try Data(contentsOf: database), before)
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: database.path + suffix),
                "opening \(suffix) means the sqlite was not read-only"
            )
        }
    }

    // MARK: - Construction

    private func makeProvider(
        cli: (@Sendable () throws -> String)? = nil,
        database: URL,
        locateBinary: @escaping @Sendable () -> URL? = { nil }
    ) -> KiroProvider {
        let suite = "KiroProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiroEndpoint.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return KiroProvider(
            session: URLSession(configuration: configuration),
            cli: cli,
            database: database,
            archive: UsageArchive(defaults: defaults),
            authURL: Self.authURL,
            locateBinary: locateBinary
        )
    }

    private func missingDatabase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-kiro-\(UUID().uuidString).sqlite")
    }

    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiro-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        // kiro-cli runs WAL. A read-write open of a WAL database creates
        // -wal/-shm even for SELECT; read-only must not.
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE probe (id INTEGER PRIMARY KEY, payload TEXT);
        INSERT INTO probe VALUES (1, 'do-not-touch');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        return url
    }

    private func creditsWindow(in snapshot: ProviderSnapshot) -> LimitWindow? {
        snapshot.windows.first { $0.id == "credits" } ?? snapshot.headline
    }
}

/// Canned GetUsageLimits answers. `canInit` is unconditional so a provider
/// that talks to a different host still cannot reach the network.
private final class KiroEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(Int, String)] = []
    private static var count = 0
    private static var url: URL?

    static var requestCount: Int { lock.withLock { count } }
    static var lastURL: URL? { lock.withLock { url } }

    static func reset(_ values: [(Int, String)]) {
        lock.withLock {
            answers = values
            count = 0
            url = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let answer = Self.lock.withLock {
            Self.count += 1
            Self.url = request.url
            return Self.answers.isEmpty ? (500, "") : Self.answers.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
