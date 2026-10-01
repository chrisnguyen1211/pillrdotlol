import Foundation

/// Notices when Gemini CLI is working.
///
/// Its chat recordings hold no pid — nothing in the JSONL names the process —
/// so `ProcessLiveness` has nothing to verify and recency is the only signal
/// there is. It is a good one: the CLI appends a `$set lastUpdated` patch on
/// every message, so a file written moments ago is a turn in progress. Cursor
/// and Antigravity stand on the same substitute.
enum GeminiCLIActivity {
    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var newest: (session: URL, project: URL, modified: Date)?
        for project in projects {
            let chats = project.appendingPathComponent("chats")
            guard let files = try? manager.contentsOfDirectory(
                at: chats, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate else { continue }
                if newest == nil || modified > newest!.modified {
                    newest = (file, project, modified)
                }
            }
        }

        // An older session is a finished turn, and showing it as work in
        // progress would be a guess dressed as a fact.
        guard let newest, now.timeIntervalSince(newest.modified) <= staleAfter else { return [] }
        return [AgentSession(
            id: "gemini-api.\(newest.session.deletingPathExtension().lastPathComponent)",
            name: "Gemini CLI",
            detail: L10n.t("Working in \(projectName(of: newest.project))"),
            state: .busy,
            waitingFor: nil,
            since: newest.modified
        )]
    }

    /// The directory is named after a hash of the working directory, which says
    /// nothing to whoever reads the tooltip; the CLI writes the path that hash
    /// stands for beside it, and the last component of that path is the folder
    /// the user knows the project by.
    private static func projectName(of project: URL) -> String {
        let marker = project.appendingPathComponent(".project_root")
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        }
        return project.lastPathComponent
    }
}
