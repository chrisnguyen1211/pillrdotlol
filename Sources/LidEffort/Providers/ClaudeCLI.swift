import Foundation

/// Where the standalone Claude Code command lives, if it is installed.
///
/// Deliberately *not* the copy inside the Claude desktop app, under
/// `~/Library/Application Support/Claude/claude-code/<version>/`. Checked on a
/// real machine: that copy keeps its OAuth token in the desktop app's own
/// store (`config.json`, `oauth:tokenCacheV2`) and never writes the login
/// keychain — which is the item pillr reads. Renewing with it would look
/// like it worked and change nothing here, so the search refuses to return it.
enum ClaudeCLI {
    /// The usual install locations, in the order a shell would find them.
    static let candidates = [
        "/opt/homebrew/bin/claude",      // Homebrew on Apple silicon
        "/usr/local/bin/claude",         // Homebrew on Intel, and the installer
        "~/.local/bin/claude",           // the standalone installer's default
        "/usr/bin/claude"
    ]

    /// Anything under here belongs to the desktop app and is not usable for
    /// this. Matched on the resolved path, so a symlink into it is caught too.
    static let desktopOwned = "/Library/Application Support/Claude/"

    /// Where a Node version manager puts an `npm install -g` — a directory
    /// named for the Node version, which no entry in `candidates` can spell.
    ///
    /// npm remains the common way to install Claude Code, and under `nvm` the
    /// binary lands in `~/.nvm/versions/node/<version>/bin`. Without this,
    /// `standalone` returns nil on those machines, and the renewal that keeps
    /// a ring from ageing out never runs at all — silently, since finding no
    /// command is not an error.
    ///
    /// Newest version first: upgrading Node leaves every older tree in place
    /// with whatever was installed against it at the time, and only the
    /// current one is certainly the install being run. `.numeric` rather than
    /// a semver parse, because the names are `v20.20.2` and `v22.22.3` and the
    /// only thing asked of the order is that 22 sorts above 20 — which a plain
    /// string comparison gets backwards.
    static func nodeVersionCandidates(home: String = NSHomeDirectory(),
                                      fileManager: FileManager = .default) -> [String] {
        let versions = (home as NSString).appendingPathComponent(".nvm/versions/node")
        guard let names = try? fileManager.contentsOfDirectory(atPath: versions) else { return [] }
        return names
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { (versions as NSString).appendingPathComponent("\($0)/bin/claude") }
    }

    /// The fixed locations a global npm install lands in, outside the paths
    /// Claude Code's own installers use.
    static func nodeToolCandidates(home: String = NSHomeDirectory()) -> [String] {
        [".volta/bin/claude",      // Volta's shim directory
         "Library/pnpm/claude",    // pnpm's global bin on macOS
         ".npm-global/bin/claude"] // npm with a user-level prefix
            .map { (home as NSString).appendingPathComponent($0) }
    }

    /// `candidates` first, so a copy Claude Code's own installer maintains is
    /// preferred over one npm happens to have left in a Node tree.
    static func standalone(candidates: [String] = candidates,
                           home: String = NSHomeDirectory(),
                           fileManager: FileManager = .default) -> URL? {
        let all = candidates
            + nodeToolCandidates(home: home)
            + nodeVersionCandidates(home: home, fileManager: fileManager)
        for path in all {
            let expanded = (path as NSString).expandingTildeInPath
            guard fileManager.isExecutableFile(atPath: expanded) else { continue }
            // `resolvingSymlinksInPath` because the Homebrew entry is a symlink
            // into the Caskroom, and the desktop app's copy could equally be
            // linked somewhere on PATH.
            let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
            guard !isDesktopOwned(resolved) else { continue }
            return resolved
        }
        return nil
    }

    static func isDesktopOwned(_ url: URL) -> Bool {
        url.path.contains(desktopOwned)
    }
}
