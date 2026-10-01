import XCTest
import SwiftUI
@testable import LidEffort

@MainActor
final class LMStudioProviderTests: XCTestCase {
    func testTheListingIsReadWithoutATokenWhenNoneIsStored() async throws {
        let requested = expectation(description: "listing")
        let provider = makeProvider(token: nil) { request in
            XCTAssertEqual(request.url?.path, "/api/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                         "a server that never asked for a token must not be sent one")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.timeoutInterval, 3)
            requested.fulfill()
            return (200, Data(LMStudioFixtures.listing.utf8))
        }
        let snapshot = try await provider.fetchSnapshot()
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(snapshot.kind, .localRuntime)
        XCTAssertEqual(snapshot.id, "lmstudio")
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.notchSnapshots.map(\.id), ["lmstudio:model:qwen3.8-27b"])
        XCTAssertNil(provider.account())
        XCTAssertFalse(provider.isVisibleWhenAbsent)
        XCTAssertEqual(provider.signInRoute, .openApp(bundleID: "ai.elementlabs.lmstudio", name: "LM Studio"))
    }

    func testTheListingIsAnsweredFromMemoryForAFewSeconds() async throws {
        var requests = 0
        var clock = Date(timeIntervalSince1970: 1_000)
        LMStudioStubProtocol.handler = { _ in requests += 1; return (200, Data(LMStudioFixtures.listing.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LMStudioStubProtocol.self]
        let provider = LMStudioLocalProvider(endpoint: URL(string: LMStudioEndpoint.defaultAddress)!,
                                             session: URLSession(configuration: configuration), token: { nil },
                                             inventoryInterval: 5, now: { clock })
        _ = try await provider.fetchSnapshot()
        clock.addTimeInterval(1)
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(requests, 1, "LM Studio logs every listing; a second-old one is answered from memory")
        clock.addTimeInterval(5)
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(requests, 2)
        provider.endpoint = try LMStudioEndpoint.parse("http://127.0.0.1:41343")
        _ = try await provider.fetchSnapshot()
        XCTAssertEqual(requests, 3, "a new address is never answered from the old one's memory")
    }

    func testAStoredTokenIsSentAsABearer() async throws {
        let provider = makeProvider(token: "sk-lm-tL9sH4ED:MQZTWwaOsmlIEKL4EruT") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-lm-tL9sH4ED:MQZTWwaOsmlIEKL4EruT")
            return (200, Data(#"{"models":[]}"#.utf8))
        }
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertTrue(snapshot.hasReading)
    }

    func testARefusalSaysATokenIsNeededRatherThanSignedOut() async {
        for status in [401, 403] {
            let provider = makeProvider(token: nil) { _ in
                (status, Data(#"{"error":{"type":"invalid_request","code":"invalid_api_key","message":"An LM Studio API token is required"}}"#.utf8))
            }
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("HTTP \(status) succeeded")
            } catch {
                XCTAssertEqual(error as? LMStudioError, .needsToken)
                XCTAssertTrue(error.localizedDescription.contains("API token"))
            }
        }
    }

    func testOtherFailuresStayVisible() async {
        for status in [301, 404, 500] {
            let provider = makeProvider(token: nil) { _ in (status, Data()) }
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("HTTP \(status) succeeded")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("HTTP \(status)"))
            }
        }
        // LM Studio answers an unknown path with 200 and an error body.
        let wrongService = makeProvider(token: nil) { _ in (200, Data(#"{"error":"Unexpected endpoint or method. (GET /api/v1/models)"}"#.utf8)) }
        do {
            _ = try await wrongService.fetchSnapshot()
            XCTFail("An error body succeeded")
        } catch {
            XCTAssertEqual(error as? LMStudioError, .invalidResponse)
        }
        let down = makeProvider(token: nil) { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await down.fetchSnapshot()
            XCTFail("A refused connection succeeded")
        } catch {
            XCTAssertEqual(error as? LMStudioError, .unavailable)
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
        let cancelled = makeProvider(token: nil) { _ in throw URLError(.cancelled) }
        do {
            _ = try await cancelled.fetchSnapshot()
            XCTFail("Cancelled request succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancellation became \(error)")
        }
    }

    func testTheStoreClearsTheReadingWhenTheAddressChangesAndDoesNotEnableMonitoring() throws {
        let provider = LMStudioLocalProvider(endpoint: try LMStudioEndpoint.parse(LMStudioEndpoint.defaultAddress))
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()),
                               disconnected: ["lmstudio"])
        let updated = try LMStudioEndpoint.parse("http://127.0.0.1:41343")
        store.updateLMStudioEndpoint(updated)
        XCTAssertEqual(provider.endpoint, updated)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.refreshing.isEmpty)
    }

    func testTheSettingsRowsNameTheRuntimeAModelIsLoadedIn() async throws {
        let provider = makeProvider(token: nil) { _ in (200, Data(LMStudioFixtures.listing.utf8)) }
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: isolatedDefaults()))
        await store.refresh()
        let summary = try XCTUnwrap(store.localModelSummaries.first)
        XCTAssertEqual(summary.id, "lmstudio:model:qwen3.8-27b")
        XCTAssertEqual(summary.runtimeName, "LM Studio")
        XCTAssertEqual(summary.sourceProviderID, "lmstudio")
        XCTAssertEqual(summary.signIn, .guidance("Loaded in LM Studio."))
        XCTAssertEqual(summary.localModel?.memoryLabel, "Model size")
    }

    func testTheEndpointPreferenceIsLoopbackOnlyAndPersists() {
        let defaults = isolatedDefaults()
        let fresh = Preferences(defaults: defaults)
        XCTAssertFalse(fresh.isConnected("lmstudio"), "off by default: only the three lid-driven agents start connected")
        XCTAssertNoThrow(try LMStudioEndpoint.parse(fresh.lmstudioEndpoint))
        XCTAssertTrue(fresh.lmstudioEndpoint.hasPrefix("http://127.0.0.1:"))
        fresh.lmstudioEndpoint = "http://127.0.0.1:41343"
        XCTAssertEqual(Preferences(defaults: defaults).lmstudioEndpoint, "http://127.0.0.1:41343")
        defaults.set("http://10.0.0.1:1234", forKey: "lmstudioEndpoint")
        XCTAssertEqual(Preferences(defaults: defaults).lmstudioEndpoint, LMStudioEndpoint.defaultAddress,
                       "a stored remote address is not honoured")
    }

    func testTheGlyphAssetRendersAsAMarkNotASquare() throws {
        let asset = try XCTUnwrap(Assets.image(named: ProviderGlyph.lmstudio.assetName))
        XCTAssertGreaterThan(asset.size.width, 0)
        let renderer = ImageRenderer(content: ProviderGlyphView(glyph: .lmstudio, size: 32).foregroundStyle(.white))
        let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var ink = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
        }
        let coverage = Double(ink) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(coverage, 0.05)
        XCTAssertLessThan(coverage, 0.85)
    }

    private func makeProvider(token: String?, _ handler: @escaping (URLRequest) throws -> (Int, Data)) -> LMStudioLocalProvider {
        LMStudioStubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LMStudioStubProtocol.self]
        return LMStudioLocalProvider(endpoint: URL(string: LMStudioEndpoint.defaultAddress)!,
                                     session: URLSession(configuration: configuration), token: { token })
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "LMStudioProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

private final class LMStudioStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
