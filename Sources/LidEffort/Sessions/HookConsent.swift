import Foundation

/// When spyx may add its hooks to the agents' configs: once the person has
/// seen what they are — the setup page that explains them, or a switch in
/// Settings turned on — and only from a copy of the app that stays put. A
/// hook pointing into a disk image or a translocated copy breaks the moment
/// that copy is gone, and with it Codex's own notify program, which spyx
/// passes calls on to.
enum HookConsent {
    static let key = "hooks.consented"
    static let changed = Notification.Name("lol.spyx.hookConsentChanged")

    static func given(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }

    static func grant(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Someone who set spyx up before hooks waited for consent already had
    /// them: kept, not asked again. Read once, at launch.
    static func migrate(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: key) == nil, defaults.bool(forKey: SetupGate.seenKey) {
            defaults.set(true, forKey: key)
        }
    }

    /// Applications, where the path outlives this launch. A build folder is
    /// allowed only when asked for, for working on spyx itself.
    static func locationAllows(_ location: AppLocation = .current,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard) -> Bool {
        if location == .applications { return true }
        if location == .elsewhere, environment["SPYX_HOOKS_ANYWHERE"] != nil || defaults.bool(forKey: "hooks.anyLocation") {
            return true
        }
        return false
    }

    static func mayInstall(_ defaults: UserDefaults = .standard) -> Bool {
        given(defaults) && locationAllows(defaults: defaults)
    }
}
