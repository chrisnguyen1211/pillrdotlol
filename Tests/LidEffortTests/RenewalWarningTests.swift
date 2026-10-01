import XCTest
@testable import LidEffort

/// The warning that says a saved login has aged out.
///
/// It exists because the failure it reports is invisible everywhere else: an
/// expired token leaves the last reading on screen, still roughly true, and
/// nothing about the ring says the number stopped moving. That is how a frozen
/// reading went twelve hours without being noticed. So the warning is tied to
/// the credential, never to whether there is a number.
@MainActor
final class RenewalWarningTests: XCTestCase {
    private final class Provider: UsageProvider, @unchecked Sendable {
        let id = "claude"
        let displayName = "Claude"
        let glyph = ProviderGlyph.claude
        /// Set to make the next fetch fail the way an aged-out token does.
        var tokenExpired = false

        func fetchSnapshot() async throws -> ProviderSnapshot {
            if tokenExpired { throw UsageProviderError.credentialExpired }
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok,
                                    windows: [LimitWindow(id: "w", label: "W",
                                                          usedFraction: 0.4)])
        }

        func signOut() async {}
    }

    private func store(_ provider: Provider) -> UsageStore {
        let name = "RenewalWarningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))
    }

    private func warning(_ store: UsageStore) -> Bool {
        store.providerSummaries.first { $0.id == "claude" }?.needsSignInRenewal ?? false
    }

    // MARK: - Appearance

    func testNothingIsShownUntilARenewalActuallyFails() async {
        let store = store(Provider())
        await store.refresh()
        XCTAssertFalse(warning(store))
    }

    func testItAppearsWhenARenewalFails() {
        let store = store(Provider())
        store.reportRenewalFailed(providerID: "claude")
        XCTAssertTrue(warning(store))
    }

    // MARK: - Persistence behind a stale reading

    /// The regression this is really for. After the token ages out the fetch
    /// fails, but the remembered reading stays on screen and keeps its numbers
    /// — so anything that keyed the warning off "is there a reading" would hide
    /// it behind exactly the stale figure it is warning about.
    func testAStaleReadingDoesNotHideIt() async {
        let provider = Provider()
        let store = store(provider)
        await store.refresh()                       // a real reading, remembered
        XCTAssertEqual(store.snapshots.first?.windows.count, 1)

        provider.tokenExpired = true
        store.reportRenewalFailed(providerID: "claude")
        await store.refresh()

        XCTAssertTrue(store.snapshots.first?.hasReading == true,
                      "the old number is still on screen, which is the point")
        XCTAssertTrue(warning(store), "and the warning is still there behind it")
    }

    /// Repeated failures do not pile up or flap.
    func testReportingTwiceChangesNothing() {
        let store = store(Provider())
        store.reportRenewalFailed(providerID: "claude")
        store.reportRenewalFailed(providerID: "claude")
        XCTAssertEqual(store.needsRenewal, ["claude"])
    }

    // MARK: - Disappearance

    /// A reading that came back is proof the credential works, whatever was
    /// believed a moment ago. This is the only thing that clears the warning —
    /// no timer, and nothing retries on its own.
    func testItClearsOnceAReadingComesBack() async {
        let provider = Provider()
        let store = store(provider)
        provider.tokenExpired = true
        store.reportRenewalFailed(providerID: "claude")
        await store.refresh()
        XCTAssertTrue(warning(store))

        provider.tokenExpired = false
        await store.refresh()

        XCTAssertFalse(warning(store), "a fresh reading takes the warning away by itself")
        XCTAssertTrue(store.needsRenewal.isEmpty)
    }

    /// A failed fetch is not proof of anything, so it must not clear it either.
    func testAFailedFetchDoesNotClearIt() async {
        let provider = Provider()
        let store = store(provider)
        provider.tokenExpired = true
        store.reportRenewalFailed(providerID: "claude")
        await store.refresh()
        await store.refresh()
        XCTAssertTrue(warning(store))
    }
}
