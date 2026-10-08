import XCTest
import SwiftUI
import LidEffortCore
@testable import LidEffort

/// Every pane of the settings window, drawn by AppKit in an offscreen
/// window — `cacheDisplay` draws the real controls, which an
/// `ImageRenderer` cannot — and written out when EFFORT_RENDER_DIR is set.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private func snapshot(_ view: some View, size: CGSize, name: String, dark: Bool) throws {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    func testEveryPaneDraws() throws {
        let suite = "SettingsRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let pane = CGSize(width: SettingsView.width, height: 1500)
        let panes: [(String, AnyView)] = [
            ("lid", AnyView(LidPane(effort: EffortController(defaults: defaults)))),
            ("notch", AnyView(NotchPane(preferences: preferences, displays: [], resetPosition: {}))),
            ("sessions", AnyView(SessionsPane(preferences: preferences))),
            ("notifications", AnyView(NotificationsPane(preferences: preferences, previewResetAlert: {},
                                                        previewSessionLimitAlert: {}, previewWeeklyLimitAlert: {},
                                                        showAccounts: {}))),
            ("general", AnyView(GeneralPane(preferences: preferences, updater: Updater()))),
            ("costs", AnyView(CostSettingsPane())),
        ]
        for dark in [true, false] {
            preferences.interfaceMode = dark ? .dark : .light
            for (name, view) in panes {
                try snapshot(view.scrollContentBackground(.hidden), size: pane, name: name, dark: dark)
            }
            let window = SettingsView(preferences: preferences, providers: { [] }, signOut: { _ in }, signIn: { _ in false },
                                      switchAccount: { _ in false }, retry: { _ in }, resetPosition: {}, quit: {},
                                      updater: Updater())
            try snapshot(window, size: CGSize(width: SettingsView.width, height: SettingsView.height), name: "window", dark: dark)
            var accounts = window
            accounts.startSection = .accounts
            try snapshot(accounts, size: CGSize(width: SettingsView.width, height: SettingsView.height), name: "accounts", dark: dark)
            var api = window
            api.startSection = .api
            try snapshot(api, size: CGSize(width: SettingsView.width, height: SettingsView.height), name: "api-window", dark: dark)
        }
    }

    /// The API tab empty, with a few keys in every state, with the add form
    /// open, and the provider picker's list on its own — a popover does not
    /// draw into an offscreen window.
    func testTheAPIPaneDraws() throws {
        let suite = "SettingsRenderTests.api.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = Preferences(defaults: defaults)
        let pane = CGSize(width: SettingsView.width, height: 900)

        let keysSuite = "SettingsRenderTests.apikeys.\(UUID().uuidString)"
        let keysDefaults = try XCTUnwrap(UserDefaults(suiteName: keysSuite))
        defer { keysDefaults.removePersistentDomain(forName: keysSuite) }
        let withKeys = Preferences(defaults: keysDefaults)
        let keys = [
            ExtraKey(id: "apikey_openrouter-k00001", base: "openrouter", name: "Work", region: nil),
            ExtraKey(id: "apikey_moonshot-k00002", base: "moonshot", name: "China", region: "china"),
            ExtraKey(id: "apikey_elevenlabs-k00003", base: "elevenlabs", name: "Voice", region: nil),
            ExtraKey(id: "apikey_groq-k00004", base: "groq", name: "Key 1", region: nil),
            ExtraKey(id: "apikey_openai-k00005", base: "openai", name: "Org", region: nil),
            ExtraKey(id: "apikey_perplexity-k00006", base: "perplexity", name: "Search", region: nil),
            ExtraKey(id: "apikey_deepseek-k00007", base: "deepseek", name: "Lab", region: nil),
        ]
        for key in keys { withKeys.addExtraKey(key) }
        withKeys.setConnected(false, for: "apikey_deepseek-k00007")

        func reading(_ id: String, _ reading: APIReading, currency: String? = nil) -> ProviderSnapshot {
            let window = reading.window(providerName: APICatalog.entry(forProviderID: id)?.name ?? id, currency: currency)
            return ProviderSnapshot(id: id, displayName: id, glyph: .apiKey, fidelity: .official, status: .ok,
                                    windows: [window], headlineID: window.id)
        }
        let glmWindow = LimitWindow(id: "tokens", label: "Tokens", usedFraction: 0.18, detail: "18% used · resets 4:00 PM")
        let snapshots = [
            ProviderSnapshot(id: "glm", displayName: "GLM", glyph: .glm, fidelity: .official, status: .ok,
                             windows: [glmWindow], headlineID: "tokens"),
            reading("apikey_openrouter-k00001", .left(7.5, of: 20, .money("USD"), resetsAt: nil)),
            reading("apikey_moonshot-k00002", .balance(49.58, .money(nil)), currency: "CNY"),
            reading("apikey_elevenlabs-k00003", .used(3200, of: 10000, .characters, resetsAt: nil)),
            reading("apikey_groq-k00004", .keyWorks(.requestsLeft(remaining: 14399, limit: 14400, today: true))),
            ProviderSnapshot(id: "apikey_openai-k00005", displayName: "x", glyph: .openai, fidelity: .official,
                             status: .error(L10n.t("\("OpenAI") refused this key. Reading usage needs \(L10n.t("an admin key")).")),
                             windows: []),
            reading("apikey_perplexity-k00006", .keyWorks(.keptUnchecked)),
        ]

        let panes: [(String, AnyView, CGSize)] = [
            ("api-empty", AnyView(APIKeysPane(preferences: empty, addRequest: .constant(nil),
                                              basePresent: { _ in false })), pane),
            ("api-keys", AnyView(APIKeysPane(preferences: withKeys, addRequest: .constant(nil),
                                             basePresent: { $0 == "glm" }, snapshotsForRender: snapshots)), pane),
            ("api-form", AnyView(APIKeysPane(preferences: withKeys, addRequest: .constant(nil), initialForm: "moonshot",
                                             basePresent: { $0 == "glm" }, snapshotsForRender: snapshots)), pane),
            ("theme-chooser", AnyView(VStack(spacing: 12) {
                ThemeChooser(choice: .constant(.light))
                ThemeChooser(choice: .constant(.dark))
                ThemeChooser(choice: .constant(.system))
            }.padding(16)), CGSize(width: 200, height: 150)),
            ("api-form-xai", AnyView(APIKeyForm(preferences: withKeys, preset: "xai", done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 460)),
            // A key that can change things: how to make it read-only, where
            // it is kept, and the keys found under it.
            ("api-form-anthropic", AnyView(APIKeyForm(preferences: withKeys, preset: "anthropic", done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 520)),
            ("api-form-openai-keys", AnyView(APIKeyForm(preferences: withKeys, preset: "openai",
                                                        subKeysForRender: [APISubKey(id: "key_1", name: "Shop · Backend", hint: "sk-abc...def"),
                                                                           APISubKey(id: "key_2", name: "Shop · Agents", hint: "sk-ghi...jkl")],
                                                        done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 560)),
            ("api-form-fields", AnyView(APIKeyForm(preferences: withKeys, preset: "fireworks", done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 360)),
            // Every provider's mark, as the suggestion list draws it.
            ("api-logos", AnyView(APIProviderSuggestions(query: "", results: APICatalog.entries, highlight: -1,
                                                         selected: nil, hover: { _ in }, choose: { _ in },
                                                         shown: APICatalog.entries.count)
                .padding(20)), CGSize(width: 420, height: CGFloat(APICatalog.entries.count) * 30 + 120)),
            ("api-picker", AnyView(APIKeyForm(preferences: empty, preset: nil, canCancel: false, done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 520)),
            ("api-picker-search", AnyView(APIKeyForm(preferences: empty, preset: nil, queryForRender: "voice", done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 520)),
            ("api-picker-chosen-search", AnyView(APIKeyForm(preferences: empty, preset: "moonshot", queryForRender: "ki", done: { _ in })
                .padding(20)), CGSize(width: SettingsView.width, height: 560)),
        ]
        for dark in [true, false] {
            empty.interfaceMode = dark ? .dark : .light
            withKeys.interfaceMode = dark ? .dark : .light
            for (name, view, size) in panes {
                try snapshot(view.scrollContentBackground(.hidden), size: size, name: name, dark: dark)
            }
        }
        // Accounts keeps the rings; a row whose way in is a pasted key points
        // to the API tab, and every key is folded into the one API keys row.
        let rows = [
            ProviderSummary(id: "glm", name: "GLM", glyph: .glm, account: nil,
                            signIn: .guidance("Set up a GLM key")),
            ProviderSummary(id: "apikey_openrouter-k00001", name: "OpenRouter · Work", glyph: .apiKey,
                            account: ProviderAccount(label: nil, plan: nil, source: "pillr", manageURL: nil),
                            signIn: .guidance(ExtraKey.signInGuidance)),
            ProviderSummary(id: "apikey_groq-k00004", name: "Groq · Key 1", glyph: .apiKey,
                            account: ProviderAccount(label: nil, plan: nil, source: "pillr", manageURL: nil),
                            signIn: .guidance(ExtraKey.signInGuidance)),
        ]
        withKeys.setConnected(true, for: "glm")
        var accounts = SettingsView(preferences: withKeys, providers: { rows }, signOut: { _ in }, signIn: { _ in false },
                                    switchAccount: { _ in false }, retry: { _ in }, resetPosition: {}, quit: {},
                                    updater: Updater())
        accounts.startSection = .accounts
        try snapshot(accounts, size: CGSize(width: SettingsView.width, height: SettingsView.height),
                     name: "api-accounts-pointer", dark: true)

        // The ninth tab has to fit in the languages with the longest words.
        defer { L10n.testLocale = nil }
        for code in ["fr", "ru", "pt-BR"] {
            L10n.testLocale = Locale(identifier: code)
            var window = SettingsView(preferences: withKeys, providers: { [] }, signOut: { _ in }, signIn: { _ in false },
                                      switchAccount: { _ in false }, retry: { _ in }, resetPosition: {}, quit: {},
                                      updater: Updater())
            window.startSection = .api
            try snapshot(window, size: CGSize(width: SettingsView.width, height: SettingsView.height),
                         name: "api-window-\(code)", dark: false)
        }
    }

    func testSearchFindsSettingsByWhatTheyDo() {
        XCTAssertEqual(Set(SettingsIndex.search("sound").map(\.section)), [.notifications])
        XCTAssertTrue(SettingsIndex.search("claude hook").contains { $0.title == "Answer Claude from the notch" })
        XCTAssertTrue(SettingsIndex.search("MONITOR").contains { $0.section == .notch })
        XCTAssertTrue(SettingsIndex.search("codex").contains { $0.section == .lid })
        XCTAssertTrue(SettingsIndex.search("").isEmpty)
        XCTAssertTrue(SettingsIndex.search("openrouter key").contains { $0.section == .api })
        XCTAssertTrue(SettingsIndex.search("custom endpoint").contains { $0.section == .api })
        XCTAssertTrue(SettingsIndex.search("zzzz").isEmpty)
    }
}
