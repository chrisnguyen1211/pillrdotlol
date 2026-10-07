import XCTest
@testable import LidEffort

/// An agent that is not on this Mac is told how to get it — from the
/// vendor's own page — and one that is, by any sign, is not.
final class AgentInstallTests: XCTestCase {
    func testEveryGuideIsTheVendorsOwnHTTPSPageWithASign() {
        for (id, guide) in AgentInstall.catalog {
            XCTAssertEqual(guide.page.scheme, "https", id)
            XCTAssertFalse(guide.bundleIDs.isEmpty && guide.binaries.isEmpty && guide.folders.isEmpty,
                           "\(id) needs something to recognise it by")
            if guide.kind == .cli { XCTAssertNotNil(guide.command, "\(id): a CLI comes with its install command") }
        }
        XCTAssertNotNil(AgentInstall.guide(for: "claude"))
        XCTAssertNotNil(AgentInstall.guide(for: "codex"))
        XCTAssertNil(AgentInstall.guide(for: "apikey_openrouter-k00001"), "an API key has nothing to install")
    }

    func testAnySignMeansInstalled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: home) }
        let guide = AgentInstall(kind: .cli, page: URL(string: "https://example.com")!, command: "x",
                                 bundleIDs: ["com.example.app"], binaries: ["tool"], folders: [".tool"])
        XCTAssertFalse(guide.isInstalled(home: home, appExists: { _ in false }))
        XCTAssertTrue(guide.isInstalled(home: home, appExists: { $0 == "com.example.app" }), "the app")

        try FileManager.default.createDirectory(atPath: home + "/.tool", withIntermediateDirectories: true)
        XCTAssertTrue(guide.isInstalled(home: home, appExists: { _ in false }), "its folder")
        try FileManager.default.removeItem(atPath: home + "/.tool")

        let bin = home + "/.local/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin + "/tool", contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(guide.isInstalled(home: home, appExists: { _ in false }), "its binary on the usual path")
    }
}

/// What this Mac has, by the guide's signs. Prints only; skipped unless
/// `PILLR_LIVE_INSTALLS` is set.
final class LiveAgentInstallDiagnostics: XCTestCase {
    func testPrintWhatIsInstalled() throws {
        guard ProcessInfo.processInfo.environment["PILLR_LIVE_INSTALLS"] != nil else { throw XCTSkip("set PILLR_LIVE_INSTALLS") }
        for id in AgentInstall.catalog.keys.sorted() {
            print("INSTALLED \(id): \(AgentInstall.catalog[id]!.isInstalled())")
        }
    }
}
