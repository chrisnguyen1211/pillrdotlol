import AppKit
import Foundation

/// How to get an agent onto this Mac, for the setup's Agents page: an agent
/// that is not installed has nothing to connect to, so the row says so and
/// shows the way — the vendor's own install page, and for a command-line
/// agent the command its docs give, to copy into Terminal.
///
/// Only the vendor's own instructions, never a guess: a command here is run
/// by the person, by hand, in their own Terminal.
struct AgentInstall: Equatable {
    enum Kind: Equatable { case app, cli }

    let kind: Kind
    /// The vendor's install page.
    let page: URL
    /// The command the vendor's docs give, for a command-line agent.
    var command: String? = nil
    /// What tells it is here: an app's bundle id, a binary on the usual
    /// paths, a folder it keeps in the home directory.
    var bundleIDs: [String] = []
    var binaries: [String] = []
    var folders: [String] = []

    /// Whether this Mac has it, by any of the signs above — attributes only,
    /// nothing is run.
    func isInstalled(home: String = NSHomeDirectory(), fileManager: FileManager = .default,
                     appExists: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) -> Bool {
        if bundleIDs.contains(where: appExists) { return true }
        if folders.contains(where: { fileManager.fileExists(atPath: home + "/" + $0) }) { return true }
        let paths = Self.binaryPaths(home: home)
        return binaries.contains { name in paths.contains { fileManager.isExecutableFile(atPath: $0 + "/" + name) } }
    }

    /// Where command-line agents usually land, whichever installer put them there.
    static func binaryPaths(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
         home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", home + "/.cargo/bin",
         home + "/.claude/local", home + "/.opencode/bin", home + "/.volta/bin"]
    }

    /// The guide for a provider id, or nil where there is nothing to install —
    /// an account read from the web, an API key.
    static func guide(for providerID: String) -> AgentInstall? {
        let base = EffortState.targetID(forProviderID: providerID)
        return catalog[providerID] ?? catalog[base]
    }

    private static func url(_ s: String) -> URL { URL(string: s)! }

    /// From each vendor's own docs or repository, October 2026. The command
    /// is the vendor's first-listed macOS install; an app's page is where it
    /// is downloaded.
    static let catalog: [String: AgentInstall] = [
        "claude": AgentInstall(kind: .cli, page: url("https://code.claude.com/docs/en/setup"),
                               command: "curl -fsSL https://claude.ai/install.sh | bash",
                               bundleIDs: ["com.anthropic.claudefordesktop"], binaries: ["claude"],
                               folders: [".claude", ".local/share/claude"]),
        // The desktop app is called ChatGPT now; its bundle id is still Codex's.
        "codex": AgentInstall(kind: .cli, page: url("https://github.com/openai/codex"),
                              command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                              bundleIDs: ["com.openai.codex"], binaries: ["codex"], folders: [".codex"]),
        // xAI's own Grok Build — `grok login`, ~/.grok/auth.json.
        "grok": AgentInstall(kind: .cli, page: url("https://x.ai/cli"),
                             command: "curl -fsSL https://x.ai/cli/install.sh | bash",
                             binaries: ["grok"], folders: [".grok"]),
        "cursor": AgentInstall(kind: .app, page: url("https://cursor.com/download"),
                               bundleIDs: ["com.todesktop.230313mzl4w4u92"], binaries: ["agent", "cursor-agent"],
                               folders: [".cursor"]),
        // The "gemini" ring is Antigravity's; Gemini CLI is retired for
        // personal accounts and Antigravity is where Google points.
        "gemini": AgentInstall(kind: .app, page: url("https://antigravity.google/download"),
                               bundleIDs: ["com.google.antigravity"], binaries: ["agy"],
                               folders: [".gemini/antigravity-cli"]),
        "opencode": AgentInstall(kind: .cli, page: url("https://opencode.ai/docs/"),
                                 command: "curl -fsSL https://opencode.ai/install | bash",
                                 binaries: ["opencode"], folders: [".local/share/opencode", ".config/opencode"]),
        "kimi": AgentInstall(kind: .cli, page: url("https://moonshotai.github.io/kimi-code/en/"),
                             command: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash",
                             binaries: ["kimi"], folders: [".kimi-code"]),
        "amp": AgentInstall(kind: .cli, page: url("https://ampcode.com/docs/cli"),
                            command: "curl -fsSL https://ampcode.com/install.sh | bash",
                            binaries: ["amp"], folders: [".config/amp", ".local/share/amp"]),
        "kilo": AgentInstall(kind: .cli, page: url("https://kilo.ai/docs/cli"),
                             command: "npm install -g @kilocode/cli",
                             binaries: ["kilo"], folders: [".local/share/kilo", ".config/kilo"]),
        "kiro": AgentInstall(kind: .app, page: url("https://kiro.dev/downloads/"),
                             bundleIDs: ["dev.kiro.desktop"], binaries: ["kiro-cli"], folders: [".kiro"]),
        "commandcode": AgentInstall(kind: .cli, page: url("https://commandcode.ai/docs/quickstart"),
                                    command: "npm i -g command-code@latest",
                                    binaries: ["command-code"], folders: [".commandcode"]),
        // Copilot's usage is read through the GitHub CLI's login.
        "copilot": AgentInstall(kind: .cli, page: url("https://cli.github.com/"),
                                command: "brew install gh",
                                binaries: ["gh"], folders: [".config/gh"]),
        "devin": AgentInstall(kind: .cli, page: url("https://docs.devin.ai/cli"),
                              command: "curl -fsSL https://cli.devin.ai/install.sh | bash",
                              binaries: ["devin"],
                              folders: [".local/share/devin", ".config/devin", "Library/Application Support/Devin"]),
        "ollama-local": AgentInstall(kind: .app, page: url("https://ollama.com/download/mac"),
                                     bundleIDs: ["com.electron.ollama"], binaries: ["ollama"], folders: [".ollama"]),
        "lmstudio": AgentInstall(kind: .app, page: url("https://lmstudio.ai/download"),
                                 bundleIDs: ["ai.elementlabs.lmstudio"], binaries: ["lms"], folders: [".lmstudio"]),
    ]
}
