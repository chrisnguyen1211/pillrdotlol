import Foundation

/// One page of the setup assistant.
enum SetupStep: String, CaseIterable, Identifiable {
    case welcome
    /// Out of the disk image or Downloads and into Applications.
    case move
    /// The prompt hook, and macOS's leave to read Claude's login.
    case claude
    /// Apple Events to the terminals sessions run in.
    case terminals
    /// Accessibility, for typing /effort into Claude Desktop.
    case claudeDesktop
    /// Every other agent's account.
    case agents
    case ready

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return L10n.t("Welcome to spyx")
        case .move: return L10n.t("Move to Applications")
        case .claude: return L10n.t("Claude Code")
        case .terminals: return L10n.t("Your terminals")
        case .claudeDesktop: return L10n.t("Claude Desktop")
        case .agents: return L10n.t("Your agents")
        case .ready: return L10n.t("You're all set")
        }
    }

    /// The short name in the step list.
    var shortTitle: String {
        switch self {
        case .welcome: return L10n.t("Welcome")
        case .move: return L10n.t("Install")
        case .claude: return L10n.t("Claude Code")
        case .terminals: return L10n.t("Terminals")
        case .claudeDesktop: return L10n.t("Claude Desktop")
        case .agents: return L10n.t("Agents")
        case .ready: return L10n.t("Try it")
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "laptopcomputer"
        case .move: return "square.and.arrow.down"
        case .claude: return "bubble.left.and.text.bubble.right.fill"
        case .terminals: return "apple.terminal.fill"
        case .claudeDesktop: return "accessibility"
        case .agents: return "person.2.fill"
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

    init(needsMove: Bool, claudeDesktopInstalled: Bool) {
        steps = SetupStep.allCases.filter { step in
            switch step {
            case .move: return needsMove
            case .claudeDesktop: return claudeDesktopInstalled
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
