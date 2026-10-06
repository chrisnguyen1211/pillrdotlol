import Foundation

/// One page of the setup assistant. No page belongs to one agent: every
/// agent is on the same list, gets the same hooks, the same lid.
enum SetupStep: String, CaseIterable, Identifiable {
    case welcome
    /// Out of the disk image or Downloads and into Applications.
    case move
    /// Every agent's account, switched on or off, side by side.
    case agents
    /// Each agent's turn-finished hook — and approvals, where an agent has them.
    case hooks
    /// Apple Events to the terminals sessions run in.
    case terminals
    /// Accessibility, for agents' desktop apps, which have no terminal.
    case desktopApps
    case ready

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return L10n.t("Welcome to spyx")
        case .move: return L10n.t("Move to Applications")
        case .agents: return L10n.t("Your agents")
        case .hooks: return L10n.t("Done & approvals")
        case .terminals: return L10n.t("Your terminals")
        case .desktopApps: return L10n.t("Desktop apps")
        case .ready: return IntroGate.seen ? L10n.t("You're all set") : L10n.t("Almost done")
        }
    }

    /// The short name in the step list.
    var shortTitle: String {
        switch self {
        case .welcome: return L10n.t("Welcome")
        case .move: return L10n.t("Install")
        case .agents: return L10n.t("Agents")
        case .hooks: return L10n.t("Done & approvals")
        case .terminals: return L10n.t("Terminals")
        case .desktopApps: return L10n.t("Desktop apps")
        case .ready: return L10n.t("Finish")
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "laptopcomputer"
        case .move: return "square.and.arrow.down"
        case .agents: return "person.2.fill"
        case .hooks: return "bell.badge.fill"
        case .terminals: return "apple.terminal.fill"
        case .desktopApps: return "accessibility"
        case .ready: return "checkmark"
        }
    }

    /// Whether leaving it undone leaves something broken rather than
    /// something missing. Only moving is: every later grant is kept against
    /// the path the app runs from.
    ///
    /// Notifications are not a step. The notch is where prompts and limits
    /// show; a system banner is an extra, off unless chosen in Settings, and
    /// macOS asks for it the first time one is actually sent.
    var isOptional: Bool { self != .move && self != .welcome && self != .ready }
}

/// Which pages this Mac needs, in order.
struct SetupPlan: Equatable {
    let steps: [SetupStep]

    init(needsMove: Bool, desktopAppInstalled: Bool) {
        steps = SetupStep.allCases.filter { step in
            switch step {
            case .move: return needsMove
            case .desktopApps: return desktopAppInstalled
            default: return true
            }
        }
    }

    func index(of step: SetupStep) -> Int { steps.firstIndex(of: step) ?? 0 }

    func next(after step: SetupStep) -> SetupStep? {
        let i = index(of: step) + 1
        return i < steps.count ? steps[i] : nil
    }

    func previous(before step: SetupStep) -> SetupStep? {
        let i = index(of: step) - 1
        return i >= 0 ? steps[i] : nil
    }

    /// "Step 3 of 7", counting from the first page after Welcome.
    func position(of step: SetupStep) -> (current: Int, total: Int) {
        (index(of: step) + 1, steps.count)
    }
}

/// When the assistant opens on its own.
enum SetupGate {
    static let seenKey = "setup.seen"

    /// Once per Mac — a fresh install, or the first launch of the version
    /// that brought it — and whenever it is asked for. Closing it counts as
    /// seen: it stays one click away in Settings and the menu bar.
    static func shouldShow(seen: Bool, forced: Bool) -> Bool { forced || !seen }

    static var forcedByArguments: Bool {
        ProcessInfo.processInfo.arguments.contains("--setup")
    }
}

/// Whether the intro tour has been seen on this Mac — so a first launch
/// plays it before setup, and setup's Finish does not play it twice.
enum IntroGate {
    static let key = "intro.seen"
    /// Someone who went through setup before the intro came first was
    /// shown round after it: seen too.
    static var seen: Bool {
        UserDefaults.standard.bool(forKey: key) || UserDefaults.standard.bool(forKey: SetupGate.seenKey)
    }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
}
