import XCTest
@testable import LidEffort

/// spyx became pillr: what it kept under its name comes across once, and
/// nothing of anyone else's is touched.
final class RebrandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RebrandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func touch(_ path: String, _ text: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheOldFoldersComeAcrossOnce() throws {
        try touch("Application Support/spyx/costs/index.json", "costs")
        try touch("WebKit/lol.spyx.app/WebsiteData/cookies", "web")
        try touch("HTTPStorages/lol.spyx.app.binarycookies", "jar")
        Rebrand.carryOver(library: root, bundleID: "lol.pillr.app")

        XCTAssertEqual(read("Application Support/pillr/costs/index.json"), "costs")
        XCTAssertNil(read("Application Support/spyx/costs/index.json"), "moved, not copied")
        XCTAssertEqual(read("WebKit/lol.pillr.app/WebsiteData/cookies"), "web", "browser sign-ins kept")
        XCTAssertEqual(read("WebKit/lol.spyx.app/WebsiteData/cookies"), "web", "and left for an older copy")
        XCTAssertEqual(read("HTTPStorages/lol.pillr.app.binarycookies"), "jar")
    }

    func testWhatPillrAlreadyHasIsNeverOverwritten() throws {
        try touch("Application Support/spyx/costs/index.json", "old")
        try touch("Application Support/pillr/costs/index.json", "new")
        Rebrand.carryOver(library: root, bundleID: "lol.pillr.app")
        XCTAssertEqual(read("Application Support/pillr/costs/index.json"), "new")
        XCTAssertEqual(read("Application Support/spyx/costs/index.json"), "old", "left where it was")
    }

    func testOnlyACopyStillNamedSpyxIsRenamed() throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        XCTAssertEqual(Rebrand.renamedLocation(for: apps.appendingPathComponent("spyx.app"))?.lastPathComponent, "pillr.app")
        XCTAssertNil(Rebrand.renamedLocation(for: apps.appendingPathComponent("pillr.app")))
        XCTAssertNil(Rebrand.renamedLocation(for: apps.appendingPathComponent("spyx copy.app")))
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("pillr.app"), withIntermediateDirectories: true)
        XCTAssertNil(Rebrand.renamedLocation(for: apps.appendingPathComponent("spyx.app")), "a pillr.app already there stays")
    }

    func testOwnKeychainNamesMapToSpyxsAndNoOneElsesDo() {
        XCTAssertEqual(KeychainItem.legacy(service: "pillr-extra-key", account: "glm-k00a01")?.service, "spyx-extra-key")
        XCTAssertEqual(KeychainItem.legacy(service: "pillr-extra-key", account: "glm-k00a01")?.account, "glm-k00a01")
        XCTAssertEqual(KeychainItem.legacy(service: "Ollama", account: "pillr")?.account, "spyx")
        XCTAssertEqual(KeychainItem.legacy(service: "lol.pillr.custom-endpoint", account: nil)?.service, "lol.spyx.custom-endpoint")
        XCTAssertNil(KeychainItem.legacy(service: "Claude Code-credentials", account: nil), "another app's item never moves")
    }

    @MainActor func testSettingsComeFromSpyxBeforeTheOlderName() throws {
        let fresh = UserDefaults(suiteName: "RebrandTests.fresh.\(UUID().uuidString)")!
        let spyx = "RebrandTests.spyx.\(UUID().uuidString)", older = "RebrandTests.older.\(UUID().uuidString)"
        UserDefaults.standard.setPersistentDomain(["edge": "left"], forName: spyx)
        UserDefaults.standard.setPersistentDomain(["edge": "top"], forName: older)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: spyx)
            UserDefaults.standard.removePersistentDomain(forName: older)
        }
        Preferences.migrateFromPreviousDomain(into: fresh, from: [spyx, older])
        XCTAssertEqual(fresh.string(forKey: "edge"), "left")
        XCTAssertEqual(Preferences.previousDomains.first, "lol.spyx.app")
    }
}
