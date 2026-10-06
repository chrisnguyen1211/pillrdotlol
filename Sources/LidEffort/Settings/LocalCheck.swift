import SwiftUI

/// What Check connection found for a local runtime — said in the row, with
/// the time, so a click always visibly does something.
struct LocalCheckResult: Equatable {
    let ok: Bool
    let text: String
    let at: Date

    /// From one probe of the runtime at `address`.
    static func from(status: ProviderStatus, snapshot: ProviderSnapshot?, name: String, address: String,
                     now: Date = Date()) -> LocalCheckResult {
        switch status {
        case .ok, .stale:
            let found = snapshot?.localRuntime?.summary ?? ""
            let text = found.isEmpty
                ? L10n.t("Connected to \(name) at \(address).")
                : L10n.t("Connected to \(name) at \(address) · \(found)")
            return LocalCheckResult(ok: true, text: text, at: now)
        case .error(let why):
            return LocalCheckResult(ok: false, text: L10n.t("Couldn't reach \(name) at \(address) — \(why). Is it running?"), at: now)
        case .needsAuth, .accessDenied:
            return LocalCheckResult(ok: false, text: L10n.t("\(name) answered but asked for a token. Add it below."), at: now)
        case .unsupported(let why):
            return LocalCheckResult(ok: false, text: why, at: now)
        case .signedOutByOwner:
            return LocalCheckResult(ok: false, text: L10n.t("Couldn't reach \(name) at \(address). Is it running?"), at: now)
        }
    }
}

/// The result line: a green or orange mark, what was found, and when.
struct LocalCheckLine: View {
    let result: LocalCheckResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? Color.green : Color.orange)
            Text(result.text)
                .foregroundStyle(result.ok ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(result.at.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
        }
    }
}
