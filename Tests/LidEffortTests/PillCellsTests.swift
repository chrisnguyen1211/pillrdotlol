import XCTest
@testable import LidEffort

/// The pill draws only agents with something to show; Settings and the setup
/// still list every one that is switched on, with what it needs.
@MainActor
final class PillCellsTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        enum Mode { case reading, signedOut, expired, nothing }
        let id: String
        var displayName: String { id.capitalized }
        let glyph = ProviderGlyph.claude
        var mode: Mode

        init(_ id: String, _ mode: Mode) { self.id = id; self.mode = mode }

        func fetchSnapshot() async throws -> ProviderSnapshot {
            switch mode {
            case .signedOut: throw UsageProviderError.needsAuth
            case .expired: throw UsageProviderError.credentialExpired
            case .nothing:
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official,
                                        status: .ok, windows: [])
            case .reading:
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official,
                                        status: .ok, windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.3)])
            }
        }
        func account() -> ProviderAccount? {
            mode == .signedOut ? nil : ProviderAccount(label: nil, plan: nil, source: "Stub", manageURL: nil)
        }
        nonisolated var signInRoute: SignInRoute { .guidance("x") }
        func signOut() async {}
        func presentSignIn() {}
        nonisolated func forgetCachedCredential() {}
    }

    private func store(_ providers: [UsageProvider]) -> UsageStore {
        UsageStore(providers: providers, archive: UsageArchive(defaults: UserDefaults(suiteName: "PillCellsTests.\(UUID().uuidString)")!))
    }

    func testOnlyAgentsWithDataAreOnThePill() async {
        let store = store([Stub("claude", .reading), Stub("codex", .signedOut), Stub("grok", .nothing)])
        await store.refresh()
        XCTAssertEqual(store.ringIDs, ["claude"], "signed out or nothing read: not on the pill")
        XCTAssertEqual(store.connectedCells.map(\.id).filter { $0 != APIKeyGroup.id }, ["claude", "codex", "grok"],
                       "still listed for Settings")
        XCTAssertNotNil(store.connectNeeds()["codex"], "and the sign-in it needs is still known")
        XCTAssertTrue(store.notchSnapshots.contains { $0.id == APIKeyGroup.id }, "the API keys cell stands regardless")
    }

    func testAnAgentJoinsThePillOnceReadAndLeavesWhenSignedOut() async {
        let codex = Stub("codex", .signedOut)
        let store = store([codex])
        await store.refresh()
        XCTAssertEqual(store.ringIDs, [])

        codex.mode = .reading
        await store.refresh()
        XCTAssertEqual(store.ringIDs, ["codex"], "connected and read: on the pill")

        codex.mode = .expired
        await store.refresh()
        XCTAssertEqual(store.ringIDs, ["codex"], "a token aging out keeps the last reading: the ring stays")

        codex.mode = .signedOut
        await store.refresh()
        XCTAssertEqual(store.ringIDs, [], "signed out, the reading is no longer true: off the pill")
        XCTAssertNotNil(store.connectNeeds()["codex"], "Settings still offers the sign-in")
    }
}
