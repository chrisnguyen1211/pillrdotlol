import AppKit
import WebKit
import os

/// Holds the only state a switch flow needs from the old session. The raw
/// browser token never leaves JavaScript and its digest is kept in memory only.
struct WebSessionAuthenticationGate: Equatable {
    private(set) var baselineFingerprint: String?
    private(set) var sawLogout = false
    private var unauthenticatedSamples = 0

    init(baselineFingerprint: String?) {
        self.baselineFingerprint = baselineFingerprint
    }

    /// A switch commits only after a real logout/login transition. This keeps
    /// an already-authenticated old page from being mistaken for the new
    /// account and avoids false positives from one transient probe failure.
    mutating func observe(authenticated: Bool, fingerprint: String?) -> Bool {
        guard authenticated else {
            unauthenticatedSamples += 1
            if unauthenticatedSamples >= 2 { sawLogout = true }
            return false
        }

        unauthenticatedSamples = 0
        guard sawLogout else {
            if baselineFingerprint == nil { baselineFingerprint = fingerprint }
            return false
        }

        // Providers with no fingerprint can still use the explicit
        // logout/login transition. DeepSeek supplies one, so the same-account
        // re-login does not look like an account switch unless its session
        // identity changed.
        guard baselineFingerprint == nil || fingerprint == nil || fingerprint != baselineFingerprint
        else { return false }
        return true
    }
}

/// Reads a provider's usage from the endpoint its own web app uses, by running
/// the request *inside a browser the user signs into themselves*.
///
/// **Why a WebView rather than a cookie.** Some of these sites sit behind bot
/// management — an unauthenticated probe of Perplexity's endpoint comes back
/// `403 cf-mitigated: challenge`. A session cookie does not help, because the
/// `cf_clearance` beside it is bound to the TLS and HTTP fingerprint of the
/// browser that earned it. Making `URLSession` pass would mean impersonating
/// Chrome, which is defeating bot detection rather than reading your own usage.
/// Lifting cookies out of Chrome's encrypted store is its own problem again.
///
/// So the request is made by a browser: a WKWebView with the app's own
/// persistent store. Nothing is taken from Chrome or Safari, no fingerprint is
/// faked, and a challenge is only ever answered by the person sitting there.
@MainActor
final class WebSessionProvider: NSObject, UsageProvider {
    /// Everything site-specific, so the browser plumbing is written once.
    struct Site {
        let id: String
        let displayName: String
        let glyph: ProviderGlyph
        let origin: URL
        let fidelity: Fidelity
        let authProbeScript: String?
        /// Runs in the page as an async function body. Must return a JSON string
        /// `{ "status": Int, "body": String }`.
        let script: String
        /// Turns the response body into windows, or throws if it cannot.
        let parse: (String) throws -> [LimitWindow]
        let detailParse: ((String) throws -> ProviderUsageDetail?)?

        init(id: String, displayName: String, glyph: ProviderGlyph, origin: URL,
             script: String, fidelity: Fidelity = .official,
             authProbeScript: String? = nil,
             detailParse: ((String) throws -> ProviderUsageDetail?)? = nil,
             parse: @escaping (String) throws -> [LimitWindow]) {
            self.id = id
            self.displayName = displayName
            self.glyph = glyph
            self.origin = origin
            self.script = script
            self.fidelity = fidelity
            self.authProbeScript = authProbeScript
            self.detailParse = detailParse
            self.parse = parse
        }
    }

    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph: ProviderGlyph
    /// A browser-session provider is the one kind that really can sign you in:
    /// the session lives in its own WebView, so it can open one and clear one.
    nonisolated var signInRoute: SignInRoute { .modal(name: displayName) }

    /// A successful browser probe is the account identity this provider can
    /// honestly expose. DeepSeek does not include an email or plan in the
    /// usage payload we read, but the persisted session is enough to keep the
    /// settings row in its signed-in state after the sheet is reopened.
    nonisolated func account() -> ProviderAccount? {
        guard UserDefaults.standard.bool(forKey: "\(id).signedIn") else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: displayName,
            manageURL: site.origin.appendingPathComponent("usage")
        )
    }

    private let site: Site
    private var webView: WKWebView?
    private var signInWindow: NSWindow?
    private var signInProbeTask: Task<Void, Never>?
    private var isLoaded = false
    private var lastAuthFingerprint: String?
    private var switchGate: WebSessionAuthenticationGate?

    var onAuthenticated: (() -> Void)?

    init(site: Site) {
        self.site = site
        self.id = site.id
        self.displayName = site.displayName
        self.glyph = site.glyph
        super.init()
    }

    /// Set once a sign-in has been opened. Until then the provider makes no
    /// request at all: quietly loading someone's account page in a hidden
    /// WebView every minute, unasked, would be both wasteful and reasonably
    /// indistinguishable from automation.
    private var hasSignedIn: Bool {
        get { UserDefaults.standard.bool(forKey: "\(site.id).signedIn") }
        set { UserDefaults.standard.set(newValue, forKey: "\(site.id).signedIn") }
    }

    // MARK: - The browser

    nonisolated static func matchesOrigin(_ url: URL?, expected origin: URL) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let expectedScheme = origin.scheme?.lowercased(),
              let expectedHost = origin.host?.lowercased()
        else { return false }
        return scheme == expectedScheme
            && host == expectedHost
            && effectivePort(for: url) == effectivePort(for: origin)
    }

    private nonisolated static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()   // persists across launches
        // Records the API calls the page makes, so an endpoint can be found by
        // watching the site rather than by guessing at path names. Injected at
        // document start, because the interesting calls happen during load.
        configuration.userContentController.addUserScript(WKUserScript(
            source: #"""
            window.__notchCalls = [];
            (function () {
                const fetchImpl = window.fetch;
                window.fetch = function (...args) {
                    try {
                        const url = args[0] && args[0].url ? args[0].url : args[0];
                        window.__notchCalls.push(String(url));
                    } catch (e) {}
                    return fetchImpl.apply(this, args);
                };
                const openImpl = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function (method, url) {
                    try { window.__notchCalls.push(String(url)); } catch (e) {}
                    return openImpl.apply(this, arguments);
                };
            })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800),
                                configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    private func ensureLoaded() async throws {
        let webView = makeWebViewIfNeeded()
        if isLoaded, Self.matchesOrigin(webView.url, expected: site.origin) { return }
        webView.load(URLRequest(url: site.origin))
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if Self.matchesOrigin(webView.url, expected: site.origin), !webView.isLoading {
                isLoaded = true
                return
            }
        }
        Log.usage.error("\(self.site.id, privacy: .public) page never reached a same-origin state")
        throw UsageProviderError.badResponse(status: 0)
    }

    // MARK: - Fetching

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard hasSignedIn else { throw UsageProviderError.needsAuth }
        try await ensureLoaded()
        guard let webView else { throw UsageProviderError.needsAuth }

        // `callAsyncJavaScript`, not `evaluateJavaScript`. The latter returns
        // whatever the last expression evaluates to and never awaits it, so an
        // async body hands back an unresolved Promise — an unsupported type,
        // which surfaces as an opaque failure instead of the response.
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                site.script, arguments: [:], in: nil, contentWorld: .page
            )
        } catch {
            Log.usage.error("\(self.site.id, privacy: .public) fetch script failed: \(error.localizedDescription, privacy: .public)")
            throw UsageProviderError.badResponse(status: 0)
        }

        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = envelope["status"] as? Int,
              let body = envelope["body"] as? String
        else {
            Log.usage.error("\(self.site.id, privacy: .public) response unreadable: \(String(describing: result), privacy: .public)")
            throw UsageProviderError.badResponse(status: 0)
        }

        if status == 401 || status == 403 {
            // Not signed in, or a challenge wants a human. Same remedy either way.
            hasSignedIn = false
            throw UsageProviderError.needsAuth
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        // Recorded verbatim so a parser can be written against the real thing.
        if site.id == "deepseek" {
            Log.usage.notice("\(self.site.id, privacy: .public) usage response received")
        } else {
            Log.usage.notice("\(self.site.id, privacy: .public) usage -> \(body.prefix(1200), privacy: .public)")
        }
        if let probes = envelope["probes"] as? String {
            Log.usage.notice("\(self.site.id, privacy: .public) probes -> \(probes.prefix(2600), privacy: .public)")
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: site.fidelity,
            status: .ok,
            windows: try site.parse(body),
            usageDetail: try site.detailParse?(body)
        )
    }

    /// Loads a page and reports the API calls it made. A discovery tool, not
    /// part of a refresh.
    func recordCalls(on url: URL, settleFor seconds: Double = 8) async -> [String] {
        let webView = makeWebViewIfNeeded()
        webView.load(URLRequest(url: url))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        isLoaded = false   // the page moved; the next refresh reloads its own
        let result = try? await webView.callAsyncJavaScript(
            "return JSON.stringify(window.__notchCalls || []);",
            arguments: [:], in: nil, contentWorld: .page
        )
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let calls = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        // No "/api/" filter: a tRPC or GraphQL endpoint would not match it, and
        // missing the one call that matters is the whole failure mode here.
        let interesting = calls.filter { url in
            !url.hasSuffix(".js") && !url.hasSuffix(".css") && !url.hasSuffix(".woff2")
                && !url.contains("/_next/static/") && !url.contains("data:")
        }
        return Array(Set(interesting)).sorted()
    }

    // MARK: - Signing in

    /// Shows the WebView so the user can sign in — and, if a challenge appears,
    /// answer it themselves. The app never answers one on their behalf.
    /// The one real logout in the app: this session belongs to spyx, so
    /// spyx can end it.
    ///
    /// Scoped to the site's own host rather than emptying the store — the
    /// default store is shared, so clearing all of it would sign the user out of
    /// every other web provider at the same time.
    func signOut() async {
        signInProbeTask?.cancel()
        signInProbeTask = nil
        switchGate = nil
        lastAuthFingerprint = nil
        hasSignedIn = false
        isLoaded = false

        guard let host = site.origin.host else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter {
            $0.displayName == host || host.hasSuffix(".\($0.displayName)")
        }
        await store.removeData(ofTypes: types, for: records)

        // Drop the WebView too: it holds the loaded page in memory, and a
        // cleared cookie jar behind a still-authenticated page would keep
        // answering until something happened to reload it.
        webView = nil
    }

    func presentSignIn() {
        presentSignIn(switching: false)
    }

    func presentAccountSwitch() {
        presentSignIn(switching: true)
    }

    private func presentSignIn(switching: Bool) {
        switchGate = switching
            ? WebSessionAuthenticationGate(baselineFingerprint: lastAuthFingerprint)
            : nil
        let webView = makeWebViewIfNeeded()
        if let signInWindow {
            signInWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            watchForAuthentication()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to \(displayName)"
        window.contentView = webView
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        signInWindow = window
        webView.load(URLRequest(url: site.origin))
        signInSheetDidOpen()
    }

    /// What opening the sheet means for the session.
    ///
    /// A site that can confirm a sign-in — DeepSeek's probe — is not signed in
    /// until it does, so the page is watched until it reports a session. A site
    /// with no probe has nothing to wait for, and waiting anyway left it at
    /// "needs sign-in" for good: the only path that sets `hasSignedIn` runs from
    /// that probe. Those keep the optimistic sign-in they always had, and the
    /// next refresh drops back to `needsAuth` if it did not take.
    func signInSheetDidOpen() {
        guard site.authProbeScript != nil else {
            isLoaded = true
            hasSignedIn = true
            return
        }
        isLoaded = false
        watchForAuthentication()
    }

    private func watchForAuthentication() {
        guard signInWindow != nil, let probe = site.authProbeScript, let webView else { return }
        signInProbeTask?.cancel()
        signInProbeTask = Task { [weak self, weak webView] in
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, let webView else { return }
                guard Self.matchesOrigin(webView.url, expected: site.origin) else { continue }
                let result = try? await webView.callAsyncJavaScript(
                    probe, arguments: [:], in: nil, contentWorld: .page
                )
                guard let state = Self.authenticationState(from: result) else { continue }
                if var gate = self.switchGate {
                    if gate.observe(authenticated: state.authenticated, fingerprint: state.fingerprint) {
                        self.switchGate = nil
                        self.lastAuthFingerprint = state.fingerprint
                        self.authenticationDidComplete()
                    } else {
                        self.switchGate = gate
                    }
                } else if state.authenticated {
                    self.lastAuthFingerprint = state.fingerprint
                    self.authenticationDidComplete()
                }
            }
        }
    }

    private struct AuthenticationState {
        let authenticated: Bool
        let fingerprint: String?
    }

    private static func authenticationState(from result: Any?) -> AuthenticationState? {
        if let authenticated = result as? Bool {
            return AuthenticationState(authenticated: authenticated, fingerprint: nil)
        }
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authenticated = object["authenticated"] as? Bool
        else { return nil }
        return AuthenticationState(authenticated: authenticated,
                                   fingerprint: object["fingerprint"] as? String)
    }

    private func authenticationDidComplete() {
        hasSignedIn = true
        switchGate = nil
        signInProbeTask?.cancel()
        signInProbeTask = nil
        signInWindow?.close()
        signInWindow = nil
        isLoaded = false
        onAuthenticated?()
    }
}

extension WebSessionProvider: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        watchForAuthentication()
    }
}

extension WebSessionProvider: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === signInWindow else { return }
        signInWindow = nil
        signInProbeTask?.cancel()
        signInProbeTask = nil
        // Closing a switch window is a cancellation, not a successful account
        // change. Leave the committed session and usage untouched.
        switchGate = nil
    }
}
