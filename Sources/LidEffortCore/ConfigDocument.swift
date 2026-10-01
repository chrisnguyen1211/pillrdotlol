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
        }
    }

    /// Returns the patched text, or nil when the value can't be placed
    /// safely (unparseable JSON, or a TOML section that doesn't exist —
    /// inventing a section is a guess we refuse to make).
    public static func writeString(key: String, section: String?, value: String, format: ConfigFormat, text: String) -> String? {
        switch format {
        case .json: return writeJSON(key: key, value: value, text: text)
        case .toml: return writeTOML(key: key, section: section, value: value, text: text)
        }
    }

    // MARK: JSON

    private static func readJSON(key: String, text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root[key] as? String
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
}
