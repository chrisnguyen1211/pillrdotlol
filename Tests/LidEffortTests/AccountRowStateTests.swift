import XCTest
import SwiftUI
@testable import LidEffort

/// Settings → Accounts ends each row in the control for what it can do next:
/// Connect when it is off, the fix when it is on but cannot be read, and
/// Disconnect once it reads. Only a local model keeps the old switch.
@MainActor
final class AccountRowStateTests: XCTestCase {
    private let codexApp = SignInRoute.openApp(bundleID: "com.openai.codex", name: "Codex")
    private let account = ProviderAccount(label: "me@example.com", plan: "pro", source: "Codex", manageURL: nil)

    private func summary(id: String = "codex", account: ProviderAccount? = nil, route: SignInRoute? = nil,
                         command: String? = nil, refused: Bool = false, renewal: Bool = false) -> ProviderSummary {
        ProviderSummary(id: id, name: id.capitalized, glyph: .openai, account: account,
                        signIn: route ?? codexApp, signInCommand: command,
                        wasRefusedAccess: refused, needsSignInRenewal: renewal)
    }

    // MARK: - Which control

    func testALocalModelKeepsItsSwitchEitherWay() {
        XCTAssertEqual(AccountRowState.resolve(isLocalModel: true, isConnected: true, need: nil), .toggle)
        XCTAssertEqual(AccountRowState.resolve(isLocalModel: true, isConnected: false, need: nil), .toggle)
    }

    func testASwitchedOffProviderOffersConnect() {
        let need = ConnectNeed(reason: "Not signed in", buttonTitle: "Open Codex", action: .openApp)
        XCTAssertEqual(AccountRowState.resolve(isLocalModel: false, isConnected: false, need: need), .connect,
                       "off is off, whatever it would need once on")
    }

    func testAConnectedProviderThatNeedsSomethingSaysWhat() {
        let need = ConnectNeed(reason: "Sign-in expired", buttonTitle: "Sign in in Terminal", action: .terminal("claude"))
        XCTAssertEqual(AccountRowState.resolve(isLocalModel: false, isConnected: true, need: need), .needs(need))
    }

    func testAConnectedProviderWithNothingToFixIsReading() {
        XCTAssertEqual(AccountRowState.resolve(isLocalModel: false, isConnected: true, need: nil), .reading)
    }

    func testOnlyANeedWithSomethingToDoFromSettingsGetsAButton() {
        XCTAssertFalse(ConnectNeed(reason: "x", buttonTitle: "Settings…", action: .settings).offersButton,
                       "Settings is where the row already is")
        XCTAssertTrue(ConnectNeed(reason: "x", buttonTitle: "Open Codex", action: .openApp).offersButton)
        XCTAssertTrue(ConnectNeed(reason: "x", buttonTitle: "Allow access…", action: .allowAccess).offersButton)
    }

    // MARK: - Where the need comes from

    func testOnTheNotchTheStoresAnswerWins() {
        let live = ConnectNeed(reason: "Signed out", buttonTitle: "Open Codex", action: .openApp)
        let need = AccountRowState.need(live: live, isOnNotch: true, summary: summary(account: account),
                                        appInstalled: { _ in true })
        XCTAssertEqual(need, live)
    }

    func testOnTheNotchAndReadingTheStaleSummaryIsIgnored() {
        // The summary is only re-read when the window comes forward, so it can
        // still say "no account" after a sign-in has already landed.
        let need = AccountRowState.need(live: nil, isOnNotch: true, summary: summary(account: nil),
                                        appInstalled: { _ in true })
        XCTAssertNil(need)
    }

    func testARefusalComesFromTheSummaryEvenOnTheNotch() {
        // A refusal leaves the last reading's status alone, so the store's
        // snapshot never reports it.
        let need = AccountRowState.need(live: nil, isOnNotch: true, summary: summary(account: account, refused: true),
                                        appInstalled: { _ in true })
        XCTAssertEqual(need?.action, .allowAccess)
        XCTAssertEqual(need?.buttonTitle, "Allow access…")
    }

    func testARefusalWinsOverAnOlderExpiredNeed() {
        // An "expired" left from before can outlive a later refusal; only
        // Allow access… fixes the refusal, so it is the one offered.
        let stale = ConnectNeed.need(status: .needsAuth, expired: true, route: .guidance("Run claude"),
                                     command: "claude", appInstalled: { _ in true })
        let need = AccountRowState.need(live: stale, isOnNotch: true, summary: summary(account: account, refused: true),
                                        appInstalled: { _ in true })
        XCTAssertEqual(need?.action, .allowAccess)
    }

    func testJustConnectedIsJudgedFromTheSummary() {
        let noAccount = AccountRowState.need(live: nil, isOnNotch: false,
                                             summary: summary(route: .guidance("Run claude"), command: "claude"),
                                             appInstalled: { _ in false })
        XCTAssertEqual(noAccount?.action, .terminal("claude"))
        XCTAssertEqual(noAccount?.buttonTitle, "Sign in in Terminal")

        let modal = AccountRowState.need(live: nil, isOnNotch: false,
                                         summary: summary(id: "deepseek", route: .modal(name: "DeepSeek")),
                                         appInstalled: { _ in false })
        XCTAssertEqual(modal?.buttonTitle, "Sign in to DeepSeek")

        let signedIn = AccountRowState.need(live: nil, isOnNotch: false, summary: summary(account: account),
                                            appInstalled: { _ in true })
        XCTAssertNil(signedIn)
    }

    func testAnAgedOutLoginStillNeedsRenewingWithAnAccount() {
        let need = AccountRowState.need(live: nil, isOnNotch: false, summary: summary(account: account, renewal: true),
                                        appInstalled: { _ in true })
        XCTAssertEqual(need?.reason, "Sign-in expired")
        XCTAssertEqual(need?.action, .openApp)
    }

    func testGuidanceWithNothingToRunHasNoButton() {
        let need = AccountRowState.need(live: nil, isOnNotch: false,
                                        summary: summary(id: "gemini-api", route: .guidance("Set GEMINI_API_KEY")),
                                        appInstalled: { _ in true })
        XCTAssertEqual(need?.action, .settings)
        XCTAssertEqual(need?.offersButton, false)
    }

    // MARK: - Connect in the store

    func testConnectingASignedInProviderOnlyReadsIt() throws {
        let provider = ConnectStub(route: .modal(name: "Stub"), signedIn: true)
        let store = try makeStore(provider)
        XCTAssertTrue(store.beginConnect(providerID: provider.id))
        XCTAssertFalse(provider.presented, "no sign-in window over a signed-in account")
        XCTAssertTrue(store.isFollowingUpForTesting.isEmpty)
    }

    func testConnectingOpensTheProvidersOwnSignIn() throws {
        let provider = ConnectStub(route: .modal(name: "Stub"), signedIn: false)
        let store = try makeStore(provider)
        XCTAssertTrue(store.beginConnect(providerID: provider.id))
        XCTAssertTrue(provider.presented)
        XCTAssertTrue(store.isFollowingUpForTesting.contains(provider.id), "watches for the sign-in to land")
    }

    func testConnectingWithNothingToOpenOrRunStartsNothing() throws {
        let provider = ConnectStub(route: .guidance("Paste a key"), signedIn: false)
        let store = try makeStore(provider)
        XCTAssertFalse(store.beginConnect(providerID: provider.id))
        XCTAssertTrue(store.isFollowingUpForTesting.isEmpty)
    }

    func testTheSummaryCarriesTheSignInCommand() throws {
        let provider = ConnectStub(route: .guidance("Run stub"), signedIn: false, command: "stub login")
        let store = try makeStore(provider)
        XCTAssertEqual(store.providerSummaries.first?.signInCommand, "stub login")
    }

    // MARK: - Drawing

    /// Every state on screen at once, so a crowded row shows up in a render.
    func testTheAccountsPaneDrawsEveryState() throws {
        let suite = "AccountRowStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.disconnectedProviders = ["deepseek"]
        let rows = [
            summary(id: "codex", account: account),
            summary(id: "claude", route: .guidance("Run claude"), command: "claude"),
            summary(id: "cursor", account: account, refused: true),
            summary(id: "deepseek", route: .modal(name: "DeepSeek")),
        ]
        for dark in [true, false] {
            preferences.interfaceMode = dark ? .dark : .light
            var view = SettingsView(preferences: preferences, providers: { rows }, signOut: { _ in }, signIn: { _ in false },
                                    switchAccount: { _ in false }, retry: { _ in }, resetPosition: {}, quit: {},
                                    updater: Updater())
            view.startSection = .accounts
            let size = CGSize(width: SettingsView.width, height: SettingsView.height)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentView = nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir)
                    .appendingPathComponent("settings-accounts-states-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func makeStore(_ provider: ConnectStub) throws -> UsageStore {
        let suite = "AccountRowStateTests.store.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))
    }
}

/// A provider whose sign-in route, account and command are chosen by the test,
/// and which records whether its own sign-in window was asked for.
private final class ConnectStub: UsageProvider, @unchecked Sendable {
    let id = "stub"
    let displayName = "Stub"
    let glyph = ProviderGlyph.claude
    let route: SignInRoute
    let signedIn: Bool
    let command: String?
    var presented = false

    init(route: SignInRoute, signedIn: Bool, command: String? = nil) {
        self.route = route
        self.signedIn = signedIn
        self.command = command
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard signedIn else { throw UsageProviderError.needsAuth }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok,
                                windows: [])
    }
    func account() -> ProviderAccount? {
        signedIn ? ProviderAccount(label: nil, plan: nil, source: "Stub", manageURL: nil) : nil
    }
    nonisolated var signInRoute: SignInRoute { route }
    nonisolated var signInCommand: String? { command }
    func signOut() async {}
    func presentSignIn() { presented = true }
    nonisolated func forgetCachedCredential() {}
}

/// Connect in Settings waits for one real reading: a provider that cannot be
/// read is never called connected.
@MainActor
final class ConnectProbeTests: XCTestCase {
    private func store(_ provider: any UsageProvider) -> UsageStore {
        let name = "ConnectProbeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))
    }

    func testASignedInProviderReadsOK() async {
        let status = await store(ConnectStub(route: .guidance("x"), signedIn: true)).probe(providerID: "stub")
        XCTAssertEqual(status, .ok)
    }

    func testANotSignedInProviderSaysSoInsteadOfConnecting() async {
        let status = await store(ConnectStub(route: .guidance("x"), signedIn: false)).probe(providerID: "stub")
        XCTAssertEqual(status, .needsAuth)
    }

    func testProbingNeverSwitchesAProviderOn() async {
        let store = store(ConnectStub(route: .guidance("x"), signedIn: true))
        store.disconnected = ["stub"]
        _ = await store.probe(providerID: "stub")
        XCTAssertTrue(store.ringIDs.isEmpty, "a check is not a ring")
    }
}

/// Signing in again after a login expired: the tool rewrites its sign-in
/// file, and the ring is read at once — the "needs renewing" warning goes
/// with the first reading that comes back, not at some later pass.
@MainActor
final class SignInAgainTests: XCTestCase {
    func testANewSignInFileIsReadAtOnceWhileTheProviderIsFailing() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("auth-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let provider = FileSignInStub(file: file)
        let suite = "SignInAgainTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))

        // Expired: the first reading fails and the warning is up.
        await store.refresh(providerID: provider.id)?.value
        XCTAssertTrue(store.providerSummaries.first?.needsSignInRenewal ?? false)
        store.readNewSignIns()                       // remembers the file as it is
        XCTAssertEqual(provider.reads, 1, "an unchanged file is not a reason to read")

        // `grok login`: a fresh token written to the same file.
        provider.signedIn = true
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        store.readNewSignIns()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(provider.reads, 2, "read the moment the sign-in changed")
        XCTAssertFalse(store.providerSummaries.first?.needsSignInRenewal ?? true, "the warning went with the reading")

        // Working again: further changes wait for the schedule.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        store.readNewSignIns()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(provider.reads, 2)
    }
}

private final class FileSignInStub: UsageProvider, @unchecked Sendable {
    let id = "grok"
    let displayName = "Grok"
    let glyph = ProviderGlyph.grok
    let file: URL
    var signedIn = false
    var reads = 0

    init(file: URL) { self.file = file }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        reads += 1
        guard signedIn else { throw UsageProviderError.credentialExpired }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok,
                                windows: [LimitWindow(id: "credits", label: "Credits", usedFraction: 0.1)])
    }
    func account() -> ProviderAccount? { ProviderAccount(label: "me@x.ai", plan: nil, source: "Grok", manageURL: nil) }
    nonisolated var signInRoute: SignInRoute { .guidance("Run grok login") }
    nonisolated var signInCommand: String? { "grok login" }
    nonisolated var credentialFiles: [URL] { [file] }
    func signOut() async {}
    func presentSignIn() {}
    nonisolated func forgetCachedCredential() {}
}
