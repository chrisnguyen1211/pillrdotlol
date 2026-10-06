import Foundation
import LidEffortCore
import OSLog

/// Applies one lid level to every enabled agent config, each on its own
/// per-model scale. Targets come from `BuiltInTargets`, widened with Codex's
/// live model catalog, then narrowed by the user's overrides file.
enum EffortTargetWriter {
    enum Outcome: Equatable {
        case written(String)
        case unchanged(String)
        case skipped(String)
        case failed(String)
    }

    struct Result: Equatable {
        let targetID: String
        let displayName: String
        let model: String?
        let outcome: Outcome
        /// The full ordered scale the model accepts.
        var scale: [String] = []
        /// The values on that scale only a running session takes.
        var liveOnly: [String] = []

        /// The value now in effect, when there is one.
        var value: String? {
            switch outcome {
            case .written(let value), .unchanged(let value): return value
            case .skipped, .failed: return nil
            }
        }
    }

    static let overridesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lid-effort", isDirectory: true)
        .appendingPathComponent("targets.json", isDirectory: false)

    private static let log = Logger(subsystem: "lol.spyx.app", category: "effort")

    /// Switches one agent on or off in the overrides file, keeping the rest
    /// of it. Read again on the next gesture, so it takes effect then.
    static func setEnabled(_ enabled: Bool, for id: String, at url: URL = overridesURL) {
        let current = try? String(contentsOf: url, encoding: .utf8)
        let json = TargetOverrides.settingEnabled(enabled, for: id, in: current)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.error("could not write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadTargets() -> [EffortTarget] {
        var targets = BuiltInTargets.all
        let codexCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/models_cache.json")
        if let json = try? String(contentsOf: codexCache, encoding: .utf8) {
            let catalog = CodexCatalog.supportedLevels(json: json)
            targets = targets.map { $0.id == "codex" ? CodexCatalog.fill($0, with: catalog) : $0 }
        }
        let grokCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/models_cache.json")
        if let json = try? String(contentsOf: grokCache, encoding: .utf8) {
            let catalog = GrokCatalog.supportedLevels(json: json)
            targets = targets.map { $0.id == "grok" ? GrokCatalog.fill($0, with: catalog) : $0 }
        }
        if let overrides = try? String(contentsOf: overridesURL, encoding: .utf8) {
            targets = TargetOverrides.apply(overrides, to: targets)
        }
        return targets
    }

    /// The models an agent's own catalog lists today — Codex's and Grok's
    /// caches — or nil for an agent that keeps none.
    static func listedModels(for targetID: String) -> Set<String>? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch targetID {
        case "codex":
            guard let json = try? String(contentsOf: home.appendingPathComponent(".codex/models_cache.json"), encoding: .utf8) else { return nil }
            return Set(CodexCatalog.supportedLevels(json: json).keys)
        case "grok":
            guard let json = try? String(contentsOf: home.appendingPathComponent(".grok/models_cache.json"), encoding: .utf8) else { return nil }
            return Set(GrokCatalog.supportedLevels(json: json).keys)
        default:
            return nil
        }
    }

    static func apply(level: EffortLevel, dryRun: Bool = false) -> [Result] {
        loadTargets().map { apply(level: level, to: $0, dryRun: dryRun) }
    }

    /// What each enabled config says right now, without writing — so the
    /// rings can show a value before the lid has moved at all.
    /// The lid's level for one agent only — the one being worked with —
    /// and what every other config says, unwritten, so the rings still show
    /// all of them.
    static func apply(level: EffortLevel, only targetID: String, dryRun: Bool = false) -> [Result] {
        let current = currentValues()
        return loadTargets().map { target in
            target.id == targetID
                ? apply(level: level, to: target, dryRun: dryRun)
                : current.first { $0.targetID == target.id }
                    ?? Result(targetID: target.id, displayName: target.displayName, model: nil, outcome: .skipped("not read"))
        }
    }

    static func currentValues() -> [Result] {
        loadTargets().map { target in
            guard target.enabled else {
                return Result(targetID: target.id, displayName: target.displayName, model: nil, outcome: .skipped("disabled"))
            }
            guard target.isPresent(exists: FileManager.default.fileExists(atPath:)) else {
                return Result(targetID: target.id, displayName: target.displayName, model: nil, outcome: .skipped("not on this Mac"))
            }
            let url = URL(fileURLWithPath: NSString(string: target.configPath).expandingTildeInPath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return Result(targetID: target.id, displayName: target.displayName, model: nil, outcome: .skipped("no config"))
            }
            let model = ConfigDocument.readString(key: target.modelKey, section: target.modelSection, format: target.format, text: text)
            guard let value = ConfigDocument.readString(key: target.effortKey, section: target.effortSection, format: target.format, text: text) else {
                return Result(targetID: target.id, displayName: target.displayName, model: model, outcome: .skipped("no value set"))
            }
            return Result(targetID: target.id, displayName: target.displayName, model: model, outcome: .unchanged(value),
                          scale: target.scale(for: model), liveOnly: target.liveOnly(for: model))
        }
    }

    static func apply(level: EffortLevel, to target: EffortTarget, dryRun: Bool) -> Result {
        func result(_ model: String?, _ outcome: Outcome) -> Result {
            Result(targetID: target.id, displayName: target.displayName, model: model, outcome: outcome,
                   scale: target.scale(for: model), liveOnly: target.liveOnly(for: model))
        }
        guard target.enabled else { return result(nil, .skipped("disabled")) }
        // Its config may be another tool's doing; the agent itself must be here.
        guard target.isPresent(exists: FileManager.default.fileExists(atPath:)) else {
            return result(nil, .skipped("not on this Mac"))
        }
        let url = URL(fileURLWithPath: NSString(string: target.configPath).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return result(nil, .skipped("no config at \(target.configPath)"))
        }
        let model = ConfigDocument.readString(key: target.modelKey, section: target.modelSection, format: target.format, text: text)
        guard let value = target.value(for: level, model: model) else {
            return result(model, .skipped("no band mapping for \(model ?? "unknown model")"))
        }
        // Only a running session takes it (`ultracode`, Claude's `max`):
        // in a config it would hold every new session there, or be refused.
        guard !target.liveOnlyValues.contains(value) else {
            return result(model, .skipped("\(value) is live only"))
        }
        let current = ConfigDocument.readString(key: target.effortKey, section: target.effortSection, format: target.format, text: text)
        if current == value { return result(model, .unchanged(value)) }
        guard let patched = ConfigDocument.writeString(key: target.effortKey, section: target.effortSection, value: value,
                                                       format: target.format, text: text, createSection: target.createsSection) else {
            return result(model, .failed("couldn't place \(target.effortKey) in \(target.configPath)"))
        }
        if dryRun { return result(model, .written(value)) }
        do {
            try replaceContents(of: url, with: patched)
            log.notice("\(target.id, privacy: .public) (\(model ?? "?", privacy: .public)): \(target.effortKey, privacy: .public) -> \(value, privacy: .public)")
            return result(model, .written(value))
        } catch {
            log.error("\(target.id, privacy: .public): write failed: \(error.localizedDescription, privacy: .public)")
            return result(model, .failed(error.localizedDescription))
        }
    }

    /// Atomic replace: write a temp file next to the target, then swap it in,
    /// so a crash mid-write can never leave a truncated config behind.
    static func replaceContents(of url: URL, with text: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".spyx-effort.tmp-\(UUID().uuidString)")
        try text.write(to: tempURL, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    /// The level the world is currently at, read back from Claude's settings
    /// — the seed for step mode, which has no absolute reference of its own.
    static func claudeConfiguredLevel() -> EffortLevel? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = ConfigDocument.readString(key: "effortLevel", section: nil, format: .json, text: text) else { return nil }
        return EffortLevel.allCases.first { $0.description == value }
    }
}
