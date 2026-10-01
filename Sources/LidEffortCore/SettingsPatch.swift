import Foundation

/// Rewrites the top-level `effortLevel` string field of a Claude Code
/// settings.json document as a minimal text patch, rather than decoding and
/// re-encoding the JSON. That keeps every other key, its order, and the
/// user's own formatting untouched — only the one line this tool owns moves.
public enum SettingsPatch {
    public static func applyEffortLevel(_ level: EffortLevel, to text: String) -> String {
        let pattern = #""effortLevel"\s*:\s*"[^"]*""#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return text.replacingCharacters(in: range, with: "\"effortLevel\": \"\(level)\"")
        }
        return insert(level, into: text)
    }

    private static func insert(_ level: EffortLevel, into text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "{\n  \"effortLevel\": \"\(level)\"\n}\n"
        }
        guard let closeRange = text.range(of: "}", options: .backwards) else {
            // Not a JSON object we recognize; leave it alone rather than guess.
            return text
        }
        let head = text[text.startIndex..<closeRange.lowerBound]
        let headTrimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmptyObject = headTrimmed == "{"
        let needsComma = !isEmptyObject && !headTrimmed.hasSuffix(",")
        let separator = needsComma ? ",\n" : ""
        let insertion = "\(separator)  \"effortLevel\": \"\(level)\"\n"
        return head + insertion + text[closeRange]
    }

    /// True if `text` parses as a JSON object. Used to refuse writes that
    /// would corrupt an existing file, or that this patch itself produced
    /// invalid output for.
    public static func isValidJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any]
    }
}
