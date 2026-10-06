import Foundation

/// Minimal read/patch of one string key in an agent's config file, for both
/// formats LidEffort targets. Patching is textual and single-line on
/// purpose — the rest of the user's file (order, comments, unknown keys) is
/// left byte-for-byte alone, the same policy as `SettingsPatch`.
public enum ConfigDocument {
    public static func readString(key: String, section: String?, format: ConfigFormat, text: String) -> String? {
        switch format {
        case .json: return readJSON(key: key, text: text)
        case .toml: return readTOML(key: key, section: section, text: text)
        case .yaml: return readYAML(key: key, section: section, text: text)
        }
    }

    /// Returns the patched text, or nil when the value can't be placed
    /// safely (unparseable JSON, or a TOML section that doesn't exist —
    /// inventing a section is a guess we refuse to make).
    /// `createSection`: a TOML section the agent documents but the file does
    /// not have yet is added at the end, rather than refusing — only for a
    /// target that says the section is its own (Kimi's `[thinking]`).
    public static func writeString(key: String, section: String?, value: String, format: ConfigFormat, text: String,
                                   createSection: Bool = false) -> String? {
        // One line, one quoted string: a quote, a backslash or a line break
        // in the value would end the string early and write keys of its own.
        guard !value.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline || $0.asciiValue.map { $0 < 0x20 } == true }) else {
            return nil
        }
        switch format {
        case .json: return writeJSON(key: key, value: value, text: text)
        case .toml:
            if let patched = writeTOML(key: key, section: section, value: value, text: text) { return patched }
            guard createSection, let section, section.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
            let body = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
            return body + (body.isEmpty ? "" : "\n") + "[\(section)]\n\(key) = \"\(value)\"\n"
        case .yaml: return writeYAML(key: key, section: section, value: value, text: text)
        }
    }

    // MARK: JSON

    /// The key at the top level — or, when it is not there, one object down
    /// (Droid keeps its defaults in `sessionDefaultSettings` on some builds),
    /// which is also where the single-line patch below would find it.
    private static func readJSON(key: String, text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let value = root[key] as? String { return value }
        for (_, child) in root.sorted(by: { $0.key < $1.key }) {
            if let value = (child as? [String: Any])?[key] as? String { return value }
        }
        return nil
    }

    private static func writeJSON(key: String, value: String, text: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"[^\"]*\""
        let replacement = "\"\(key)\": \"\(value)\""
        let patched: String
        if let range = text.range(of: pattern, options: .regularExpression) {
            patched = text.replacingCharacters(in: range, with: replacement)
        } else {
            guard let inserted = insertJSONKey(key: key, value: value, text: text) else { return nil }
            patched = inserted
        }
        return SettingsPatch.isValidJSONObject(patched) ? patched : nil
    }

    private static func insertJSONKey(key: String, value: String, text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{\n  \"\(key)\": \"\(value)\"\n}\n" }
        guard let close = text.range(of: "}", options: .backwards) else { return nil }
        let head = text[..<close.lowerBound]
        let headTrimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = headTrimmed == "{" || headTrimmed.hasSuffix(",") ? "" : ",\n"
        return head + separator + "  \"\(key)\": \"\(value)\"\n" + text[close.lowerBound...]
    }

    // MARK: TOML (line-based: `[section]` headers and `key = "value"` lines)

    private static func tomlLines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func sectionName(of line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func keyPattern(_ key: String) -> String {
        "^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*\"([^\"]*)\""
    }

    /// Line index of `key = "..."` inside `section` (nil = before any
    /// header), plus where that section's body starts, for insertion.
    private static func locate(key: String, section: String?, lines: [Substring]) -> (keyLine: Int?, sectionStart: Int?) {
        var current: String? = nil
        var sectionStart: Int? = section == nil ? 0 : nil
        var keyLine: Int? = nil
        for (index, line) in lines.enumerated() {
            if let name = sectionName(of: line) {
                current = name
                if name == section { sectionStart = index + 1 }
                continue
            }
            guard current == section, keyLine == nil else { continue }
            if line.range(of: keyPattern(key), options: .regularExpression) != nil { keyLine = index }
        }
        return (keyLine, sectionStart)
    }

    private static func readTOML(key: String, section: String?, text: String) -> String? {
        let lines = tomlLines(text)
        guard let keyLine = locate(key: key, section: section, lines: lines).keyLine else { return nil }
        let line = String(lines[keyLine])
        guard let regex = try? NSRegularExpression(pattern: keyPattern(key)),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[valueRange])
    }

    private static func writeTOML(key: String, section: String?, value: String, text: String) -> String? {
        var lines = tomlLines(text).map(String.init)
        let (keyLine, sectionStart) = locate(key: key, section: section, lines: tomlLines(text))
        let newLine = "\(key) = \"\(value)\""
        if let keyLine {
            lines[keyLine] = newLine
        } else if let sectionStart {
            lines.insert(newLine, at: sectionStart)
        } else {
            return nil
        }
        return lines.joined(separator: "\n")
    }

    // MARK: YAML (line-based: a top-level `section:` and its `key: value`
    // children, one level deep — enough for Hermes's `agent.reasoning_effort`)

    /// Where `section:` starts, the indent of its own keys, and the line
    /// holding `key:` among them. A key nested deeper is not this key.
    private static func locateYAML(key: String, section: String?, lines: [Substring])
        -> (keyLine: Int?, sectionStart: Int?, indent: String) {
        let keyRegex = try? NSRegularExpression(pattern: "^(\\s*)\(NSRegularExpression.escapedPattern(for: key))\\s*:(\\s|$)")
        func isKey(_ line: Substring) -> (indent: String, match: Bool) {
            let text = String(line)
            guard let match = keyRegex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let indent = Range(match.range(at: 1), in: text) else { return ("", false) }
            return (String(text[indent]), true)
        }
        guard let section else {
            let line = lines.firstIndex { isKey($0).match && isKey($0).indent.isEmpty }
            return (line, 0, "")
        }
        guard let header = lines.firstIndex(where: {
            $0.range(of: "^\(NSRegularExpression.escapedPattern(for: section))\\s*:\\s*(#.*)?$", options: .regularExpression) != nil
        }) else { return (nil, nil, "  ") }
        var childIndent: String?
        var index = header + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            let indent = String(line.prefix { $0 == " " })
            if indent.isEmpty { break }                     // the next top-level key
            if childIndent == nil { childIndent = indent }
            if indent == childIndent, isKey(line).match { return (index, header + 1, indent) }
            index += 1
        }
        return (nil, header + 1, childIndent ?? "  ")
    }

    private static func readYAML(key: String, section: String?, text: String) -> String? {
        let lines = tomlLines(text)
        guard let keyLine = locateYAML(key: key, section: section, lines: lines).keyLine else { return nil }
        let line = lines[keyLine]
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: first) else { return nil }
            return String(body[..<end])
        }
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func writeYAML(key: String, section: String?, value: String, text: String) -> String? {
        // Plain scalars only: anything YAML could read as something else stays out.
        guard value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { return nil }
        var lines = tomlLines(text).map(String.init)
        let (keyLine, sectionStart, indent) = locateYAML(key: key, section: section, lines: tomlLines(text))
        let newLine = "\(indent)\(key): \(value)"
        if let keyLine {
            // Keep a comment that trailed the old value.
            let old = lines[keyLine]
            let comment = old.range(of: "\\s+#.*$", options: .regularExpression).map { String(old[$0]) } ?? ""
            lines[keyLine] = newLine + comment
        } else if let sectionStart {
            lines.insert(newLine, at: sectionStart)
        } else {
            return nil
        }
        return lines.joined(separator: "\n")
    }
}
