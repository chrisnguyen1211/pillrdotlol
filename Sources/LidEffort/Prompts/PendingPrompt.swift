import Foundation

/// A Claude Code session stopped on a permission prompt or a question,
/// handed over by the `PermissionRequest` hook so it can be answered from
/// the notch.
///
/// Built from the hook's stdin JSON; answered with the stdout JSON the hook
/// hands back. Both halves are pure so the round trip can be tested without
/// a session: see `PromptResponse`.
struct PendingPrompt: Identifiable, Equatable {
    struct Option: Equatable, Hashable {
        let label: String
        let description: String?
    }

    struct Question: Equatable {
        let question: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool
    }

    let id = UUID()
    let sessionID: String?
    let cwd: String?
    let toolName: String
    /// The tool's input exactly as the hook received it — handed back,
    /// answers added, when a question is answered.
    let toolInput: [String: AnyHashable]
    /// `permission_suggestions`, when Claude offered a "don't ask again".
    let suggestions: [AnyHashable]
    /// Non-empty for AskUserQuestion.
    let questions: [Question]
    let receivedAt: Date
    /// Filled in by the app from the session registry.
    var pid: pid_t?
    var sessionName: String?
    /// The session's conversation, as Claude Code writes it — where the
    /// context shown with the prompt is read from.
    let transcriptPath: String?
    /// What the session was about when it asked — see `PromptContext`.
    var context: PromptContext?

    var isQuestion: Bool { !questions.isEmpty }
    var canRemember: Bool { !suggestions.isEmpty }

    static func == (lhs: PendingPrompt, rhs: PendingPrompt) -> Bool {
        lhs.id == rhs.id && lhs.pid == rhs.pid && lhs.sessionName == rhs.sessionName
    }

    init?(hookInput data: Data, now: Date = Date()) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = json["tool_name"] as? String else { return nil }
        toolName = tool
        sessionID = json["session_id"] as? String
        cwd = json["cwd"] as? String
        transcriptPath = json["transcript_path"] as? String
        toolInput = (json["tool_input"] as? [String: Any]).flatMap(Self.hashable) ?? [:]
        suggestions = (json["permission_suggestions"] as? [Any])?.compactMap(Self.hashableValue) ?? []
        receivedAt = now
        if tool == "AskUserQuestion", let raw = (json["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]] {
            questions = raw.compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                    guard let label = o["label"] as? String else { return nil }
                    return Option(label: label, description: o["description"] as? String)
                }
                return Question(question: text, header: q["header"] as? String,
                                options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
            }
        } else {
            questions = []
        }
    }

    /// One line saying what is being asked for: the command, the file, the
    /// address — not the tool's name, which says nothing on its own.
    /// Why Claude wants this, in its own words, where the tool carries them:
    /// Bash's `description`, "Show working tree status" and the like.
    var purpose: String? {
        guard let text = (toolInput["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The summary as it is shown: characters that draw nothing or reorder
    /// the text around them — zero-width spaces, bidi overrides, control
    /// codes — written out as `⟨U+202E⟩`, so what is read is what runs.
    var displaySummary: String { Self.visible(summary) }

    static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if isHidden(scalar) {
                out += String(format: "⟨U+%04X⟩", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false                       // line break, tab
        case 0x00...0x1F, 0x7F...0x9F: return true          // control codes
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064,
             0x2066...0x2069, 0xFEFF, 0x00AD, 0x2028, 0x2029, 0x061C: return true
        default: return false
        }
    }

    var summary: String {
        func relative(_ path: String) -> String {
            guard let cwd, path.hasPrefix(cwd + "/") else { return path }
            return String(path.dropFirst(cwd.count + 1))
        }
        switch toolName {
        case "Bash":
            return (toolInput["command"] as? String) ?? "Bash"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Read":
            let path = (toolInput["file_path"] as? String) ?? (toolInput["notebook_path"] as? String) ?? ""
            return "\(toolName) \(relative(path))"
        case "WebFetch":
            return "Fetch \((toolInput["url"] as? String) ?? "")"
        case "WebSearch":
            return "Search “\((toolInput["query"] as? String) ?? "")”"
        case "ExitPlanMode":
            return L10n.t("The plan is ready. Start on it?")
        default:
            if let text = toolInput.values.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                return "\(toolName): \(text)"
            }
            return toolName
        }
    }

    // MARK: - JSON to hashable, so the prompt can be compared and sent back

    private static func hashable(_ object: [String: Any]) -> [String: AnyHashable] {
        object.compactMapValues(hashableValue)
    }

    private static func hashableValue(_ value: Any) -> AnyHashable? {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v
        case let v as [String: Any]: return hashable(v) as AnyHashable
        case let v as [Any]: return v.compactMap(hashableValue) as AnyHashable
        case is NSNull: return nil
        default: return nil
        }
    }
}

/// How a prompt was answered.
enum PromptAnswer: Equatable {
    case allow
    /// Allow, and take Claude's own "don't ask again" suggestion.
    case allowAlways
    case deny
    /// Question text → chosen labels.
    case answers([String: [String]])
    /// Not answered here: Claude shows its own dialog.
    case passThrough
}

/// The hook's stdout for an answer. Empty for a pass-through: a hook that
/// returns no decision leaves Claude to ask as it normally would.
enum PromptResponse {
    static func json(for answer: PromptAnswer, prompt: PendingPrompt) -> Data {
        let decision: [String: Any]
        switch answer {
        case .passThrough:
            return Data()
        case .allow:
            decision = ["behavior": "allow"]
        case .allowAlways:
            decision = ["behavior": "allow", "updatedPermissions": prompt.suggestions]
        case .deny:
            decision = ["behavior": "deny", "message": "Declined from the pillr notch."]
        case .answers(let chosen):
            var input: [String: Any] = prompt.toolInput
            // Multi-select answers are comma-joined, the form the
            // permission component itself writes.
            input["answers"] = chosen.mapValues { $0.joined(separator: ", ") }
            decision = ["behavior": "allow", "updatedInput": input]
        }
        let output: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": decision,
        ]]
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
    }
}
