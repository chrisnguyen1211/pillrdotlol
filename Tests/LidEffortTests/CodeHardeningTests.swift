import XCTest
@testable import LidEffort

final class CodeHardeningTests: XCTestCase {
    func testClaudeSignInCommandQuotesTheRealPath() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/o'neil/my dir/.claude-work"))
        XCTAssertEqual(profile.signInCommand,
                       "CLAUDE_CONFIG_DIR='/Users/o'\"'\"'neil/my dir/.claude-work' claude")
    }

    func testKeychainFallbackNeedsConsentAndARefusal() {
        let refused = errSecInteractionNotAllowed
        XCTAssertTrue(KeychainSecret.shouldRescue(interactive: false, status: refused, hasRescue: true, allowed: true))
        XCTAssertFalse(KeychainSecret.shouldRescue(interactive: false, status: refused, hasRescue: true, allowed: false))
        XCTAssertFalse(KeychainSecret.shouldRescue(interactive: true, status: refused, hasRescue: true, allowed: true))
        XCTAssertFalse(KeychainSecret.shouldRescue(interactive: false, status: refused, hasRescue: false, allowed: true))
        XCTAssertFalse(KeychainSecret.shouldRescue(interactive: false, status: errSecItemNotFound, hasRescue: true, allowed: true))
    }

    @MainActor
    func testNewPreferencesDefaultsAndPersistence() {
        let name = "CodeHardeningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = Preferences(defaults: defaults)
        XCTAssertFalse(fresh.allowSilentKeychainRead)
        XCTAssertTrue(fresh.autoRefreshClaudeToken)
        fresh.allowSilentKeychainRead = true
        fresh.autoRefreshClaudeToken = false
        let again = Preferences(defaults: defaults)
        XCTAssertTrue(again.allowSilentKeychainRead)
        XCTAssertFalse(again.autoRefreshClaudeToken)
    }

    func testPromptSocketDirectoryAndSocketArePrivate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pb\(UInt32.random(in: 0...99999))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("p.sock").path
        let broker = PromptBroker(path: path)
        try broker.start()
        defer { broker.stop() }
        func mode(_ p: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(root.path), 0o700)
        XCTAssertEqual(try mode(path), 0o600)
    }
}
