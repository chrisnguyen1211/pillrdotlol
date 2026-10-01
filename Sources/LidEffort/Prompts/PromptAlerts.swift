import Foundation
import UserNotifications

/// How a prompt makes itself known beyond its card: a sound — one for a
/// permission, another for a question — again every few minutes while it
/// waits if asked for, and optionally a macOS notification.
enum PromptAlerts {
    /// The sound for this prompt, or nil when prompts are silent.
    @MainActor
    static func sound(for prompt: PendingPrompt, preferences: Preferences) -> String? {
        guard preferences.promptSound else { return nil }
        return prompt.isQuestion ? preferences.questionSoundName : preferences.approvalSoundName
    }

    /// The notification's words: who is asking, and what.
    static func notificationText(for prompt: PendingPrompt) -> (title: String, body: String) {
        let who = prompt.subtitle.isEmpty ? L10n.t("Claude Code") : prompt.subtitle
        if let question = prompt.questions.first {
            return (L10n.t("Claude asks · \(who)"), question.question)
        }
        return (L10n.t("Needs your OK · \(who)"), "\(prompt.statusText): \(prompt.summary)")
    }

    @MainActor
    static func announce(_ prompt: PendingPrompt, preferences: Preferences) {
        if let sound = sound(for: prompt, preferences: preferences) {
            SessionChime.play(sound)
        }
        if preferences.promptSystemNotification {
            post(prompt)
        }
    }

    private static func post(_ prompt: PendingPrompt) {
        let text = notificationText(for: prompt)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            if let ask = prompt.context?.ask { content.subtitle = "“\(ask)”" }
            content.body = text.body
            content.threadIdentifier = "prompts"
            center.add(UNNotificationRequest(identifier: "prompt.\(prompt.id.uuidString)", content: content, trigger: nil))
        }
    }

    /// Takes a prompt's notification down once it is answered or gone.
    static func withdraw(_ id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["prompt.\(id.uuidString)"])
    }
}

/// When to sound again for prompts nobody has answered.
struct PromptReminder {
    /// Minutes between reminders; 0 never reminds.
    var minutes: Int
    private(set) var lastSounded: Date?

    init(minutes: Int, lastSounded: Date? = nil) {
        self.minutes = minutes
        self.lastSounded = lastSounded
    }

    /// Whether to sound now. Nothing waiting resets it, so the first prompt
    /// after a quiet spell is not "reminded" of straight away.
    mutating func due(waiting: Bool, now: Date) -> Bool {
        guard waiting else { lastSounded = nil; return false }
        guard minutes > 0, let last = lastSounded else { return false }
        guard now.timeIntervalSince(last) >= TimeInterval(minutes * 60) else { return false }
        lastSounded = now
        return true
    }

    /// A prompt just sounded on arriving: the next reminder counts from here.
    mutating func sounded(at now: Date) { lastSounded = now }
}
