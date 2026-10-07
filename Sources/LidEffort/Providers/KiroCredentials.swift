import Foundation

/// Presence of a kiro-cli session — the binary, or the token it files in
/// sqlite — enough for the settings row to say whose readings these will be.
///
/// spyx never signs in. `kiro-cli login` writes the session and refreshes
/// it; this only looks for it. The sqlite file is opened read-only, and a
/// missing token is not a prompt to mint another — the CLI owns that.
///
/// Nil is "not installed", not "signed out". A Mac without kiro-cli has
/// nothing to log into; mapping that to `needsAuth` would put a login prompt
/// on a machine that never had the tool.
enum KiroCredentials {
    static func account(
        binary: URL? = KiroCLI.locateBinary(),
        database: URL = KiroLimits.stateDatabaseURL()
    ) -> ProviderAccount? {
        let hasBinary = binary != nil
        let hasToken = KiroLimits.loadAccessToken(from: database) != nil
        guard hasBinary || hasToken else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: "Kiro CLI",
            manageURL: URL(string: "https://app.kiro.dev/account/usage")
        )
    }
}
