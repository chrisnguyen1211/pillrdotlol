import Foundation

/// A model id as people say it: "claude-opus-5-5" → "Opus 5.5",
/// "gpt-5.6-sol" → "GPT-5.6 Sol", "grok-4.7" → "Grok 4.7", "fable" → "Fable".
enum ModelName {
    static func pretty(_ id: String) -> String {
        var raw = id.trimmingCharacters(in: .whitespaces)
        // "opus[1m]": the long-context build, said after the name.
        var suffix = ""
        if let bracket = raw.firstIndex(of: "[") {
            let tag = raw[raw.index(after: bracket)...].trimmingCharacters(in: CharacterSet(charactersIn: "]")).uppercased()
            if !tag.isEmpty { suffix = " · " + tag }
            raw = String(raw[..<bracket])
        }
        // "minimax/MiniMax-M2.7": the provider routing it is not its name.
        if let slash = raw.lastIndex(of: "/") { raw = String(raw[raw.index(after: slash)...]) }
        return name(raw) + suffix
    }

    private static func name(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("claude-") {
            // family, then the version parts; a date suffix is dropped.
            let parts = lower.dropFirst("claude-".count).split(separator: "-").map(String.init)
                .filter { !($0.count == 8 && Int($0) != nil) }
            guard let family = parts.first(where: { Int($0) == nil }) else { return raw }
            let version = parts.filter { Int($0) != nil }.joined(separator: ".")
            return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
        }
        if lower.hasPrefix("gpt-") {
            let parts = raw.dropFirst("gpt-".count).split(separator: "-").map(String.init)
            guard let number = parts.first else { return "GPT" }
            let rest = parts.dropFirst().map { $0.capitalized }
            return (["GPT-" + number] + rest).joined(separator: " ")
        }
        if lower.hasPrefix("grok-") {
            return raw.split(separator: "-").map { $0.first?.isNumber == true ? String($0) : $0.capitalized }.joined(separator: " ")
        }
        if lower.range(of: #"^o\d"#, options: .regularExpression) != nil { return raw }
        // A name with its own capitals ("MiniMax-M2.7") keeps them.
        return raw.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
