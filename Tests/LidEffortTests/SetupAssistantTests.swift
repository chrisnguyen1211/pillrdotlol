import XCTest
import SwiftUI
@testable import LidEffort

final class SetupPlanTests: XCTestCase {
    func testEveryStepWhenTheMacNeedsThemAll() {
        let plan = SetupPlan(needsMove: true, claudeDesktopInstalled: true)
        XCTAssertEqual(plan.steps, SetupStep.allCases)
    }

    func testInstalledCopyWithoutClaudeDesktopSkipsThosePages() {
        let plan = SetupPlan(needsMove: false, claudeDesktopInstalled: false)
        XCTAssertFalse(plan.steps.contains(.move))
        XCTAssertFalse(plan.steps.contains(.claudeDesktop))
        XCTAssertEqual(plan.steps.first, .welcome)
        XCTAssertEqual(plan.steps.last, .ready)
    }

    func testNavigationStopsAtTheEnds() {
        let plan = SetupPlan(needsMove: false, claudeDesktopInstalled: false)
        XCTAssertNil(plan.previous(before: .welcome))
        XCTAssertNil(plan.next(after: .ready))
        XCTAssertEqual(plan.next(after: .welcome), .claude)
        XCTAssertEqual(plan.next(after: .terminals), .agents, "skips the Claude Desktop page it doesn't have")
        XCTAssertEqual(plan.previous(before: .agents), .terminals)
    }

    func testPositionCountsFromOne() {
        let plan = SetupPlan(needsMove: true, claudeDesktopInstalled: false)
        XCTAssertEqual(plan.position(of: .welcome).current, 1)
        XCTAssertEqual(plan.position(of: .ready).current, plan.steps.count)
        XCTAssertEqual(plan.position(of: .move).total, 6)
    }

    func testOnlyMovingIsNotOptional() {
        XCTAssertFalse(SetupStep.move.isOptional)
        XCTAssertTrue(SetupStep.terminals.isOptional)
    }

    func testGateShowsOnceUnlessAsked() {
        XCTAssertTrue(SetupGate.shouldShow(seen: false, forced: false))
        XCTAssertFalse(SetupGate.shouldShow(seen: true, forced: false))
        XCTAssertTrue(SetupGate.shouldShow(seen: true, forced: true))
    }
}

final class SetupProbeTests: XCTestCase {
    func testWhereTheAppRunsFrom() {
        let home = "/Users/someone"
        XCTAssertEqual(AppLocation.classify(path: "/Applications/LidEffort.app", home: home), .applications)
        XCTAssertEqual(AppLocation.classify(path: "/Users/someone/Applications/LidEffort.app", home: home), .applications)
        XCTAssertEqual(AppLocation.classify(path: "/Volumes/Lid Effort/LidEffort.app", home: home), .diskImage)
        XCTAssertEqual(AppLocation.classify(
            path: "/private/var/folders/x/T/AppTranslocation/1234-ABCD/d/LidEffort.app", home: home), .translocated)
        XCTAssertEqual(AppLocation.classify(path: "/Users/someone/Downloads/LidEffort.app", home: home), .elsewhere)
        XCTAssertEqual(AppLocation.classify(path: "/Users/someone/Effort Lid/build/LidEffort.app", home: home), .elsewhere)
    }

    func testOnlyApplicationsNeedsNoMove() {
        XCTAssertFalse(AppLocation.applications.needsMove)
        XCTAssertTrue(AppLocation.diskImage.needsMove)
        XCTAssertTrue(AppLocation.translocated.needsMove)
        XCTAssertTrue(AppLocation.elsewhere.needsMove)
    }

    func testAutomationAnswers() {
        XCTAssertEqual(AutomationAccess.from(noErr, appName: "Terminal"), .granted)
        XCTAssertEqual(AutomationAccess.from(OSStatus(errAEEventNotPermitted), appName: "Terminal"), .denied)
        XCTAssertEqual(AutomationAccess.from(OSStatus(errAEEventWouldRequireUserConsent), appName: "Terminal"), .notAsked)
        guard case .unknown(let why) = AutomationAccess.from(OSStatus(procNotFound), appName: "iTerm2") else {
            return XCTFail("not running is not a refusal")
        }
        XCTAssertTrue(why.contains("iTerm2"))
    }

    func testOnlyTheScriptableTerminalsAskForPermission() {
        let asking = AutomationTarget.all.filter(\.needsPermission).map(\.name)
        XCTAssertEqual(asking, ["Terminal", "iTerm2", "cmux"])
        XCTAssertTrue(AutomationTarget.all.contains { $0.name == "Superset" && !$0.needsPermission })
    }

    func testTerminalIsAlwaysOfferedOthersOnlyWhenInstalled() {
        XCTAssertEqual(AutomationTarget.installed(isInstalled: { _ in false }).map(\.name), ["Terminal"])
        XCTAssertEqual(AutomationTarget.installed(isInstalled: { $0 == "com.cmuxterm.app" }).map(\.name), ["Terminal", "cmux"])
        XCTAssertEqual(AutomationTarget.installed(isInstalled: { _ in true }).count, AutomationTarget.all.count)
    }
}

/// Every page of the assistant, drawn by AppKit offscreen, and written out
/// when EFFORT_RENDER_DIR is set.
@MainActor
final class SetupAssistantRenderTests: XCTestCase {
    func testEveryPageDraws() async throws {
        let suite = "SetupAssistantRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.disconnectedProviders = ["stub-off"]
        let store = UsageStore(providers: [Expired(), Reading(), Off()], archive: UsageArchive(defaults: defaults),
                               disconnected: preferences.disconnectedProviders)
        await store.refresh()
        let model = SetupModel(preferences: preferences, store: store, effort: { nil })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(model.catalog.map(\.id), ["stub-expired", "stub-reading", "stub-off"])
        XCTAssertEqual(model.sortedCatalog.last?.id, "stub-off", "switched-off agents go last")
        XCTAssertEqual(model.needs["stub-expired"]?.reason, "Sign-in expired")
        XCTAssertFalse(model.isDone(.agents), "an expired login is something left to do")
        let size = CGSize(width: SetupAssistantView.width, height: SetupAssistantView.height)
        for dark in [false, true] {
            for step in model.plan.steps {
                model.go(to: step)
                let host = NSHostingView(rootView: SetupAssistantView(model: model, finish: {}, openSettings: {}))
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                window.orderOut(nil)
                window.contentView = nil
                XCTAssertGreaterThan(rep.pixelsWide, 0)
                if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
                    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    try png.write(to: URL(fileURLWithPath: dir)
                        .appendingPathComponent("setup-\(step.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}

private struct Expired: UsageProvider {
    let id = "stub-expired"
    let displayName = "Expired"
    let glyph = ProviderGlyph.openai
    var signInCommand: String? { "stub login" }
    func fetchSnapshot() async throws -> ProviderSnapshot { throw UsageProviderError.credentialExpired }
}

private struct Reading: UsageProvider {
    let id = "stub-reading"
    let displayName = "Reading"
    let glyph = ProviderGlyph.grok
    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok, windows: [])
    }
}

private struct Off: UsageProvider {
    let id = "stub-off"
    let displayName = "Off"
    let glyph = ProviderGlyph.cursor
    func fetchSnapshot() async throws -> ProviderSnapshot { throw UsageProviderError.needsAuth }
}

@MainActor
final class ExpiredLoginTests: XCTestCase {
    func testAnExpiredLoginOffersToSignInAgain() async {
        let defaults = UserDefaults(suiteName: "ExpiredLoginTests.\(UUID().uuidString)")!
        let store = UsageStore(providers: [Expired()], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(store.connectNeeds()["stub-expired"]?.reason, "Sign-in expired")
        XCTAssertEqual(store.connectNeeds()["stub-expired"]?.action, .terminal("stub login"))
    }

    /// Claude's token refresher renews it, and says itself when it can't.
    func testClaudeIsLeftToItsRefresher() async {
        struct ClaudeExpired: UsageProvider {
            let id = "claude"
            let displayName = "Claude"
            let glyph = ProviderGlyph.claude
            func fetchSnapshot() async throws -> ProviderSnapshot { throw UsageProviderError.credentialExpired }
        }
        let defaults = UserDefaults(suiteName: "ExpiredLoginTests.\(UUID().uuidString)")!
        let store = UsageStore(providers: [ClaudeExpired()], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertFalse(store.needsRenewal.contains("claude"))
    }
}

private final class Refused: UsageProvider, @unchecked Sendable {
    let id = "stub-refused"
    let displayName = "Refused"
    let glyph = ProviderGlyph.cursor
    var allowed = false
    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard allowed else { throw UsageProviderError.accessDenied }
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official, status: .ok, windows: [])
    }
}

@MainActor
final class ConnectFollowUpTests: XCTestCase {
    /// The sign-in finishes somewhere else; the button has to go once it
    /// has, without waiting for the idle poll.
    func testConnectLooksAgainUntilTheLoginReads() async throws {
        let interval = UsageStore.followUpInterval
        UsageStore.followUpInterval = 0.05
        defer { UsageStore.followUpInterval = interval }
        let provider = Refused()
        let defaults = UserDefaults(suiteName: "ConnectFollowUpTests.\(UUID().uuidString)")!
        let store = UsageStore(providers: [provider], archive: UsageArchive(defaults: defaults))
        await store.refresh()
        XCTAssertEqual(store.connectNeeds()["stub-refused"]?.action, .allowAccess)

        XCTAssertTrue(store.connect(providerID: "stub-refused"))
        XCTAssertEqual(store.isFollowingUpForTesting, ["stub-refused"])
        try await Task.sleep(nanoseconds: 200_000_000)
        provider.allowed = true   // the person clicked Always Allow

        for _ in 0..<40 where !store.isFollowingUpForTesting.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(store.connectNeeds()["stub-refused"])
        XCTAssertTrue(store.isFollowingUpForTesting.isEmpty, "stops once it reads")
    }
}
