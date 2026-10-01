import Foundation
import Security

/// A person's permission for one keychain read to show the password dialogue.
///
/// Granted by "Allow access…" and by nothing else. Spent by the read it is
/// taken for, whatever that read's outcome — a Deny that left it standing would
/// hand the next poll a dialogue to show. And it lapses: the click is followed
/// by a refresh at once, but where that refresh never reached the keychain the
/// permission would otherwise sit there until some later poll spent it, and the
/// dialogue would appear on a timer after all.
final class PromptPermission: @unchecked Sendable {
    static let window: TimeInterval = 60

    private let now: () -> Date
    private var owedUntil: Date?
    private let lock = NSLock()

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func grant() {
        lock.lock()
        owedUntil = now().addingTimeInterval(Self.window)
        lock.unlock()
    }

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = owedUntil else { return false }
        owedUntil = nil
        return now() < until
    }
}

/// Reading a borrowed keychain secret without ever raising the dialogue from a
/// background refresh.
///
/// Claude Code and Antigravity both file their items through `/usr/bin/security`.
/// An item created that way admits only Apple's own tools in its *partition
/// list*, which nothing in the GUI writes — so "Always Allow", which writes the
/// access list, buys exactly one read, and a poll raised the dialogue again.
enum KeychainSecret {
    /// Serialises the process-wide interaction switch. It is one switch for the
    /// whole app, so every reader that flips it must take this same lock: two
    /// readers interleaving their save and restore could otherwise leave
    /// interaction off for good, and "Allow access…" would never show its
    /// dialogue again.
    private static let interactionLock = NSLock()

    /// Runs `query` and returns its status and data.
    ///
    /// When not `interactive`, interaction is switched off for the read —
    /// `SecKeychainSetUserInteractionAllowed`, which legacy items honour, as well
    /// as `kSecUseAuthenticationUIFail`, which they ignore — and a refusal is
    /// retried through `/usr/bin/security` for `rescue`, the one reader such an
    /// item always admits.
    ///
    /// Readers that do not go through here (Cursor's, today) do not take the
    /// lock, so one of their reads landing inside the window is refused once
    /// without a prompt. Their caches retry after a backoff: a delayed prompt,
    /// never a lost one.
    static func read(query: [CFString: Any], interactive: Bool,
                     rescue: (service: String, account: String)?) -> (status: OSStatus, data: Data?) {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        var wasAllowed: DarwinBoolean = true
        if !interactive {
            SecKeychainGetUserInteractionAllowed(&wasAllowed)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) } }

        var query = query
        if !interactive { query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        // Not on an interactive read: someone who just answered the dialogue
        // gets exactly the answer they gave.
        if !interactive, ClaudeCredentials.wasRefused(status), let rescue,
           let rescued = viaSecurityTool(service: rescue.service, account: rescue.account) {
            Log.usage.notice("\(rescue.service, privacy: .public) read via the security tool after a refusal")
            return (errSecSuccess, rescued)
        }
        return (status, item as? Data)
    }

    /// Read an item by name through `/usr/bin/security`. It is Apple-signed and
    /// is how these items were written, so it is on their access list and inside
    /// their partition list. The secret comes straight back into this process;
    /// nothing is written, and it is never logged.
    private static func viaSecurityTool(service: String, account: String) -> Data? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = FileHandle.nullDevice
        do {
            try tool.run()
        } catch {
            Log.usage.error("could not run the security tool: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Drain before waiting: a full pipe nobody reads is a deadlock.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { return nil }
        var trimmed = data
        while trimmed.last == 0x0A || trimmed.last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
}
