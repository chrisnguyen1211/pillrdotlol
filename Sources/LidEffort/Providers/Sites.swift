import Foundation

/// The site-specific halves of `WebSessionProvider`.
enum Sites {
    static let perplexity = WebSessionProvider.Site(
        id: "perplexity",
        displayName: "Perplexity",
        glyph: .third,
        origin: URL(string: "https://www.perplexity.ai/")!,
        script: """
        const response = await fetch('/rest/rate-limit/all', {
            credentials: 'include',
            headers: { 'Accept': 'application/json' }
        });
        const text = await response.text();
        // `sources.source_to_limit` is a long tail of connector quotas with
        // nothing to do with model usage; drop it so the rest stays legible.
        let trimmed = text;
        try { const p = JSON.parse(text); delete p.sources; trimmed = JSON.stringify(p); } catch (_) {}
        return JSON.stringify({ status: response.status, body: trimmed });
        """,
        parse: PerplexityUsage.windows(fromJSON:)
    )

    static let deepSeek = WebSessionProvider.Site(
        id: "deepseek",
        displayName: "DeepSeek",
        glyph: .deepseek,
        origin: URL(string: "https://platform.deepseek.com/")!,
        script: #"""
        const readToken = () => {
            const extract = (value) => {
                if (typeof value === 'string' && value.trim()) return value.trim();
                if (!value || typeof value !== 'object') return null;
                for (const key of ['value', 'token', 'access_token', 'accessToken']) {
                    const candidate = extract(value[key]);
                    if (candidate) return candidate;
                }
                return null;
            };
            try {
                const raw = localStorage.getItem('userToken');
                if (!raw) return null;
                return extract(JSON.parse(raw)) || raw.trim() || null;
            } catch (_) {
                const raw = localStorage.getItem('userToken');
                return raw && raw.trim() ? raw.trim() : null;
            }
        };
        const token = readToken();
        const headers = { 'Accept': 'application/json', 'x-client-platform': 'web' };
        if (token) headers.Authorization = token.startsWith('Bearer ') ? token : 'Bearer ' + token;
        const now = new Date();
        const today = new Date(now); today.setHours(0, 0, 0, 0);
        const start = new Date(today); start.setDate(start.getDate() - 29);
        const end = new Date(today); end.setDate(end.getDate() + 1);
        const startSeconds = Math.floor(start.getTime() / 1000);
        const endSeconds = Math.floor(end.getTime() / 1000);
        const timeZoneSeconds = -now.getTimezoneOffset() * 60;
        const query = 'start=' + startSeconds + '&end=' + endSeconds + '&tz=' + timeZoneSeconds;
        const get = async (path) => {
            const response = await fetch(path, { credentials: 'include', headers });
            return { status: response.status, body: await response.text() };
        };
        const [summary, amount, cost] = await Promise.all([
            get('/api/v0/users/get_user_summary'),
            get('/api/v0/usage/by_api_key/amount?' + query),
            get('/api/v0/usage/by_api_key/cost?' + query)
        ]);
        const failed = [summary, amount, cost].find(item => item.status < 200 || item.status >= 300);
        return JSON.stringify({
            status: failed ? failed.status : 200,
            body: JSON.stringify({
                summary: summary.body, amount: amount.body, cost: cost.body,
                start: startSeconds, end: endSeconds, time_zone_seconds: timeZoneSeconds
            })
        });
        """#,
        fidelity: .derived,
        authProbeScript: #"""
        const extract = (value) => {
            if (typeof value === 'string' && value.trim()) return value.trim();
            if (!value || typeof value !== 'object') return null;
            for (const key of ['value', 'token', 'access_token', 'accessToken']) {
                const candidate = extract(value[key]);
                if (candidate) return candidate;
            }
            return null;
        };
        try {
            const raw = localStorage.getItem('userToken');
            if (!raw) return false;
            const token = extract(JSON.parse(raw)) || raw.trim();
            if (!token) return false;
            const response = await fetch('/api/v0/users/get_user_summary', {
                credentials: 'include', headers: { 'Accept': 'application/json', 'Authorization': token.startsWith('Bearer ') ? token : 'Bearer ' + token }
            });
            if (response.status < 200 || response.status >= 300) {
                return JSON.stringify({ authenticated: false });
            }
            const bytes = new TextEncoder().encode(token);
            const digest = await crypto.subtle.digest('SHA-256', bytes);
            const fingerprint = Array.from(new Uint8Array(digest))
                .map(byte => byte.toString(16).padStart(2, '0')).join('');
            return JSON.stringify({ authenticated: true, fingerprint });
        } catch (_) { return JSON.stringify({ authenticated: false }); }
        """#,
        detailParse: DeepSeekUsage.detail(fromJSON:),
        parse: { json in
            let payload = try DeepSeekUsage.payload(fromJSON: json)
            let reading = try DeepSeekUsage.reading(fromJSON: payload.summary)
            var windows = [LimitWindow(
                id: "spend",
                label: L10n.t("Account usage (\(reading.currency))"),
                usedFraction: reading.usedFraction,
                money: UsageMoneyBreakdown(currency: reading.currency,
                                           spent: reading.spent,
                                           remaining: reading.balance)
            )]
            if let availableTokens = reading.availableTokens {
                windows.append(LimitWindow(id: "available-tokens",
                                           label: "Available tokens (estimate)",
                                           detail: "\(LimitWindow.compact(availableTokens)) available"))
            }
            return windows
        }
    )

}
