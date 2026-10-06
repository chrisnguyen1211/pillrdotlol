import Foundation

public enum ConfigFormat: String, Codable, Equatable {
    case json, toml, yaml
}

/// One coding agent whose default reasoning effort LidEffort can drive.
///
/// Every agent exposes a different scale, and most differ by model too
/// (Claude persists 4 levels, Codex up to 6, Grok 3 or 4), so instead of one global
/// vocabulary each target carries `bands`: for a model id (or `*`), exactly
/// five values — the effort that model gets when the lid sits in each of the
/// five lid bands, low → max.
public struct EffortTarget: Equatable {
    public let id: String
    public let displayName: String
    public let configPath: String
    public let format: ConfigFormat
    /// Key holding the effort value, and the TOML section it lives in
    /// (nil = top level / JSON top-level object).
    public let effortKey: String
    public let effortSection: String?
    /// Key naming the currently configured model, and its section.
    public let modelKey: String
    public let modelSection: String?
    public var enabled: Bool
    public var bands: [String: [String]]
    /// The full ordered scale a model accepts (model id or `*`), for showing
    /// *where* the current value sits — the bands above only say which of
    /// those values each lid level lands on.
    public var scales: [String: [String]]
    /// Where the agent itself shows it is on this Mac — its binary, its
    /// sessions — when its config file alone does not say so: another tool
    /// may have made that file. Empty: the config file is enough.
    public var presencePaths: [String] = []
    /// The effort's section may be added when the file lacks it.
    public var createsSection = false
    /// Values a running session takes when typed in, but its config can
    /// never hold — Claude Code's `max` and `ultracode`. On a model's scale
    /// so they can be shown and picked; never written, whatever the bands say.
    public var liveOnlyValues: [String] = []

    public static let wildcard = "*"

    public init(
        id: String, displayName: String, configPath: String, format: ConfigFormat,
        effortKey: String, effortSection: String? = nil,
        modelKey: String, modelSection: String? = nil,
        enabled: Bool = true, bands: [String: [String]], scales: [String: [String]] = [:],
        presencePaths: [String] = [], createsSection: Bool = false,
        liveOnlyValues: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.configPath = configPath
        self.format = format
        self.effortKey = effortKey
        self.effortSection = effortSection
        self.modelKey = modelKey
        self.modelSection = modelSection
        self.enabled = enabled
        self.bands = bands
        self.scales = scales
        self.presencePaths = presencePaths
        self.createsSection = createsSection
        self.liveOnlyValues = liveOnlyValues
    }

    /// The entry a model is filed under: its own id, else the longest
    /// family id it starts with — `claude-opus-4-6` for a dated
    /// `claude-opus-4-6-20260115`, `haiku` for `haiku[1m]`. Nil when it
    /// is under neither, and the wildcard speaks for it.
    public func entry(for model: String?) -> String? {
        guard let model else { return nil }
        if bands[model] != nil || scales[model] != nil { return model }
        let lowered = model.lowercased()
        let keys = Set(bands.keys).union(scales.keys).subtracting([EffortTarget.wildcard])
        if keys.contains(lowered) { return lowered }
        return keys.filter { key in
            guard lowered.hasPrefix(key), lowered.count > key.count else { return false }
            let next = lowered[lowered.index(lowered.startIndex, offsetBy: key.count)]
            return "-[@:".contains(next)
        }.max { $0.count < $1.count }
    }

    /// The ordered scale for `model`: its entry's, else the wildcard's, else
    /// the distinct values its bands reach. Empty for a model that takes no
    /// effort level at all.
    public func scale(for model: String?) -> [String] {
        if let entry = entry(for: model), let exact = scales[entry] { return exact }
        if entry(for: model) == nil, let any = scales[EffortTarget.wildcard] { return any }
        var seen: [String] = []
        for value in bands(for: model) ?? [] where !seen.contains(value) { seen.append(value) }
        return seen
    }

    /// Bands used for `model`: its entry's, else the wildcard's. Nil for a
    /// model filed with an empty scale — one with no effort to set.
    public func bands(for model: String?) -> [String]? {
        guard let entry = entry(for: model) else { return bands[EffortTarget.wildcard] }
        if let exact = bands[entry] { return exact }
        guard let scale = scales[entry], !scale.isEmpty else { return nil }
        return BandMapping.byName(from: scale) ?? BandMapping.proportional(from: scale)
    }

    /// Whether the agent is on this Mac, by `presencePaths` (any of them).
    public func isPresent(exists: (String) -> Bool) -> Bool {
        presencePaths.isEmpty || presencePaths.contains { exists(NSString(string: $0).expandingTildeInPath) }
    }

    /// The values on `model`'s scale that only a running session takes,
    /// least to most: on the scale, among `liveOnlyValues`, and reached by
    /// none of its bands. Empty for every agent but Claude Code.
    public func liveOnly(for model: String?) -> [String] {
        let banded = bands(for: model) ?? []
        return scale(for: model).filter { liveOnlyValues.contains($0) && !banded.contains($0) }
    }

    /// Whether `model` takes an effort level at all.
    public func takesEffort(model: String?) -> Bool { bands(for: model) != nil }

    /// The value this target should be set to for a lid level and model,
    /// or nil when no usable 5-entry mapping exists.
    public func value(for level: EffortLevel, model: String?) -> String? {
        guard let bands = bands(for: model), bands.count == EffortLevel.allCases.count else { return nil }
        return bands[level.rawValue]
    }

    /// The lid level that lands nearest `value` on this model's scale — for a
    /// knob dragged to a value by hand, where the lid's five bands are the
    /// only vocabulary every agent shares. An exact hit wins; otherwise the
    /// band closest on the scale, the lower level on a tie. Nil when the
    /// value is not on the scale or the model has no usable bands.
    public func level(reaching value: String, model: String?) -> EffortLevel? {
        let scale = scale(for: model)
        guard let wanted = scale.firstIndex(of: value),
              let bands = bands(for: model), bands.count == EffortLevel.allCases.count else { return nil }
        // Above every band — `max`, which only a live session takes — is the
        // lid's top level, not the nearest band below it.
        let reached = EffortLevel.allCases.compactMap { scale.firstIndex(of: bands[$0.rawValue]) }
        if let highest = reached.max(), wanted > highest { return .max }
        var best: (level: EffortLevel, distance: Int)?
        for level in EffortLevel.allCases {
            guard let index = scale.firstIndex(of: bands[level.rawValue]) else { continue }
            let distance = abs(index - wanted)
            if best == nil || distance < best!.distance { best = (level, distance) }
        }
        return best?.level
    }
}

public enum BandMapping {
    /// For a scale that speaks the lid's own words (low … max): each band
    /// is that level when the model has it, else the highest level it has
    /// below that, else its lowest. So "high" on the lid is high wherever
    /// high exists, instead of wherever high lands after stretching.
    public static func byName(from supported: [String]) -> [String]? {
        guard !supported.isEmpty else { return nil }
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        func rank(_ name: String) -> Int { order.firstIndex(of: name) ?? -1 }
        return EffortLevel.allCases.map { level in
            let wanted = rank(level.description)
            return supported.filter { rank($0) <= wanted }.max { rank($0) < rank($1) } ?? supported[0]
        }
    }

    /// Spreads a model's ordered effort scale across the five lid bands,
    /// proportionally. Used for models we have no hand-tuned entry for.
    public static func proportional(from supported: [String]) -> [String]? {
        guard !supported.isEmpty else { return nil }
        let last = Double(supported.count - 1)
        let bandCount = Double(EffortLevel.allCases.count - 1)
        return (0..<EffortLevel.allCases.count).map { band in
            let index = (Double(band) / bandCount * last).rounded(.toNearestOrAwayFromZero)
            return supported[Int(index)]
        }
    }
}

public enum BuiltInTargets {
    /// Claude Code persists four levels (`effortLevel`: low…xhigh); `max`
    /// it takes only live, as `/effort max` in a session. Past max sits
    /// `ultracode` — xhigh plus multi-agent workflows on every task, and
    /// many more tokens — which Claude Code also takes only live, as
    /// `/effort ultracode`, and only on a model that has xhigh. It is on
    /// the scale for the bar and the chips, never in a band: no lid level
    /// reaches it and no config is ever written with it (an `ultracode` key
    /// in settings.json would put every new session into it). And not every
    /// model has every level — as Claude Code 2.1 decides it: no effort at
    /// all before Opus 4.5 and on Haiku 4.5; Opus 4.5 stops at high; Opus
    /// and Sonnet 4.6 skip xhigh but have max; everything newer has all five.
    /// A level a model lacks lands on the nearest one below it.
    public static let claude = EffortTarget(
        id: "claude", displayName: "Claude Code",
        configPath: "~/.claude/settings.json", format: .json,
        effortKey: "effortLevel", modelKey: "model",
        bands: [
            "claude-opus-4-5": ["low", "medium", "high", "high", "high"],
            "claude-opus-4-6": ["low", "medium", "high", "high", "high"],
            "claude-sonnet-4-6": ["low", "medium", "high", "high", "high"],
            EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "xhigh"],
        ],
        scales: [
            "claude-3": [], "claude-opus-4-0": [], "claude-opus-4-1": [],
            "claude-opus-4-20250514": [], "claude-sonnet-4-0": [], "claude-sonnet-4-20250514": [],
            "claude-sonnet-4-5": [], "claude-haiku-4-5": [], "haiku": [],
            "claude-opus-4-5": ["low", "medium", "high"],
            "claude-opus-4-6": ["low", "medium", "high", "max"],
            "claude-sonnet-4-6": ["low", "medium", "high", "max"],
            EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "max", "ultracode"],
        ],
        liveOnlyValues: ["max", "ultracode"]
    )

    /// Hand-tuned for the models in Codex's catalog at time of writing;
    /// `CodexCatalog` fills in any model missing here from
    /// ~/.codex/models_cache.json at runtime.
    public static let codex = EffortTarget(
        id: "codex", displayName: "Codex",
        configPath: "~/.codex/config.toml", format: .toml,
        effortKey: "model_reasoning_effort", modelKey: "model",
        bands: [
            "gpt-5.6-sol": ["low", "medium", "high", "xhigh", "ultra"],
            "gpt-5.6-sol-wm": ["low", "medium", "high", "xhigh", "ultra"],
            "gpt-5.6-terra": ["low", "medium", "high", "xhigh", "ultra"],
            "gpt-5.6-luna": ["low", "medium", "high", "xhigh", "max"],
            "gpt-5.5": ["low", "medium", "high", "xhigh", "xhigh"],
            "gpt-5.4": ["low", "medium", "high", "xhigh", "xhigh"],
            "gpt-5.4-mini": ["low", "medium", "high", "xhigh", "xhigh"],
            EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "xhigh"],
        ],
        scales: [
            "gpt-5.6-sol": ["low", "medium", "high", "xhigh", "max", "ultra"],
            "gpt-5.6-sol-wm": ["low", "medium", "high", "xhigh", "max", "ultra"],
            "gpt-5.6-terra": ["low", "medium", "high", "xhigh", "max", "ultra"],
            "gpt-5.6-luna": ["low", "medium", "high", "xhigh", "max"],
            EffortTarget.wildcard: ["low", "medium", "high", "xhigh"],
        ]
    )

    /// Grok stores the default under `[models] default_reasoning_effort`.
    /// Its own catalog (`GrokCatalog`) is the truth per model; without it,
    /// what Grok 1.0 ships: low…xhigh, and grok-4.5 stopping at high.
    public static let grok = EffortTarget(
        id: "grok", displayName: "Grok",
        configPath: "~/.grok/config.toml", format: .toml,
        effortKey: "default_reasoning_effort", effortSection: "models",
        modelKey: "default", modelSection: "models",
        bands: [
            "grok-4.5": ["low", "medium", "high", "high", "high"],
            EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "xhigh"],
        ],
        scales: [
            "grok-4.5": ["low", "medium", "high"],
            EffortTarget.wildcard: ["low", "medium", "high", "xhigh"],
        ]
    )

    /// Hermes Agent keeps `agent.reasoning_effort` in its YAML config, and
    /// takes none/minimal/low/medium/high/xhigh whatever model it runs.
    public static let hermes = EffortTarget(
        id: "hermes", displayName: "Hermes",
        configPath: "~/.hermes/config.yaml", format: .yaml,
        effortKey: "reasoning_effort", effortSection: "agent",
        modelKey: "default", modelSection: "model",
        bands: [EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "xhigh"]],
        scales: [EffortTarget.wildcard: ["none", "minimal", "low", "medium", "high", "xhigh"]]
    )

    /// Factory Droid: `reasoningEffort` in `~/.factory/settings.json`, its
    /// levels per model as Factory's model guide lists them — Opus and
    /// Sonnet 4.6 and later off…max, the 4.5 models off…high, GPT-5.6 none
    /// to xhigh. A model it does not list gets off…high, which every one has.
    public static let droid = EffortTarget(
        id: "droid", displayName: "Droid",
        configPath: "~/.factory/settings.json", format: .json,
        effortKey: "reasoningEffort", modelKey: "model",
        bands: [EffortTarget.wildcard: ["low", "medium", "high", "high", "high"]],
        scales: [
            "claude-opus-4-6": ["off", "low", "medium", "high", "max"],
            "claude-opus-4-7": ["off", "low", "medium", "high", "max"],
            "claude-opus-4-8": ["off", "low", "medium", "high", "max"],
            "claude-sonnet-4-6": ["off", "low", "medium", "high", "max"],
            "claude-opus-4-5": ["off", "low", "medium", "high"],
            "claude-sonnet-4-5": ["off", "low", "medium", "high"],
            "claude-haiku-4-5": ["off", "low", "medium", "high"],
            "gpt-5.6": ["none", "low", "medium", "high", "xhigh"],
            EffortTarget.wildcard: ["off", "low", "medium", "high"],
        ],
        presencePaths: ["~/.factory/sessions", "~/.local/bin/droid", "/opt/homebrew/bin/droid", "/usr/local/bin/droid"]
    )

    /// GitHub Copilot CLI: `effortLevel` in `~/.copilot/settings.json`, one
    /// level for every model — low, medium, high, xhigh.
    public static let copilot = EffortTarget(
        id: "copilot", displayName: "Copilot CLI",
        configPath: "~/.copilot/settings.json", format: .json,
        effortKey: "effortLevel", modelKey: "model",
        bands: [EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "xhigh"]],
        scales: [EffortTarget.wildcard: ["low", "medium", "high", "xhigh"]],
        presencePaths: ["~/.copilot/session-state", "~/.local/bin/copilot", "/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"]
    )

    /// Kimi Code: `[thinking] effort` in `~/.kimi-code/config.toml`, with
    /// `default_model` at the top. Each model allows its own subset of
    /// low…max (`support_efforts`); one it lacks is clamped by Kimi itself.
    public static let kimi = EffortTarget(
        id: "kimi", displayName: "Kimi Code",
        configPath: "~/.kimi-code/config.toml", format: .toml,
        effortKey: "effort", effortSection: "thinking", modelKey: "default_model",
        bands: [EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "max"]],
        scales: [EffortTarget.wildcard: ["low", "medium", "high", "xhigh", "max"]],
        presencePaths: ["~/.kimi-code/bin/kimi", "~/.kimi-code/sessions"],
        createsSection: true
    )

    public static let all: [EffortTarget] = [claude, codex, grok, hermes, droid, copilot, kimi]
}

/// User overrides from ~/.lid-effort/targets.json:
///
///     {
///       "codex": { "enabled": false },
///       "grok":  { "bands": { "grok-4.6": ["minimal","low","medium","high","max"] } }
///     }
///
/// Only `enabled` and per-model `bands` can be overridden; paths and keys
/// are fixed per agent. A band list that isn't exactly five strings, or
/// that names a value only a live session takes, is ignored rather than
/// half-applied.
public enum TargetOverrides {
    /// The overrides file with one agent switched on or off, everything
    /// else in it — bands, other agents, keys this version does not know —
    /// kept as it was. Switching an agent back on removes the `enabled` key
    /// rather than writing `true`, so the file only ever says what differs.
    public static func settingEnabled(_ enabled: Bool, for id: String, in json: String?) -> String {
        var root: [String: Any] = [:]
        if let data = json?.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var entry = root[id] as? [String: Any] ?? [:]
        if enabled { entry["enabled"] = nil } else { entry["enabled"] = false }
        root[id] = entry.isEmpty ? nil : entry
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func apply(_ json: String, to targets: [EffortTarget]) -> [EffortTarget] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return targets }
        return targets.map { target in
            guard let override = root[target.id] as? [String: Any] else { return target }
            var updated = target
            if let enabled = override["enabled"] as? Bool { updated.enabled = enabled }
            if let bands = override["bands"] as? [String: Any] {
                for (model, value) in bands {
                    // A value only a live session takes (`ultracode`) is never
                    // written, so a band that names one is not a band.
                    if let list = value as? [String], list.count == EffortLevel.allCases.count,
                       list.allSatisfy(EffortValue.isPlain),
                       !list.contains(where: target.liveOnlyValues.contains) {
                        updated.bands[model] = list
                    }
                }
            }
            return updated
        }
    }
}

/// Codex ships a per-model catalog at ~/.codex/models_cache.json with each
/// model's `supported_reasoning_levels`, so new models get a sensible
/// mapping without a LidEffort update.
/// An effort value as an agent names it: `high`, `xhigh`, `minimal`. The
/// catalogs these come from are files other programs write, and a value
/// goes on into a config file and onto a command line — so anything else
/// (a quote, a newline, a space) is not a level, and is dropped.
public enum EffortValue {
    public static func isPlain(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }
}

public enum CodexCatalog {
    public static func supportedLevels(json: String) -> [String: [String]] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [:] }
        var result: [String: [String]] = [:]
        for model in models {
            guard let slug = model["slug"] as? String,
                  let levels = model["supported_reasoning_levels"] as? [Any] else { continue }
            let names = levels.compactMap { entry -> String? in
                if let string = entry as? String { return string }
                return (entry as? [String: Any])?["effort"] as? String
            }.filter(EffortValue.isPlain)
            if !names.isEmpty { result[slug] = names }
        }
        return result
    }

    /// The catalog is the truth for each model's scale, and supplies
    /// proportional bands for models the target doesn't hand-tune. Hand-tuned
    /// bands are never overridden.
    public static func fill(_ target: EffortTarget, with catalog: [String: [String]]) -> EffortTarget {
        var updated = target
        for (slug, levels) in catalog {
            updated.scales[slug] = levels
            if updated.bands[slug] == nil, let bands = BandMapping.proportional(from: levels) {
                updated.bands[slug] = bands
            }
        }
        return updated
    }
}

/// Grok keeps its model catalog at ~/.grok/models_cache.json, each model
/// with the `reasoning_efforts` it accepts — and they differ: grok-4.5 stops
/// at high, grok-4.7 goes to xhigh. Read, it replaces the one fixed scale
/// that wrote `max` into a config whose model has no such level.
public enum GrokCatalog {
    /// Least to most, so each model's scale reads in order whatever order
    /// the catalog lists it in.
    static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    public static func supportedLevels(json: String) -> [String: [String]] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        // Keyed by model, each entry's details under `info` — as Grok 1.0
        // writes it; a plain list of models is read too.
        var entries: [(key: String?, model: [String: Any])] = []
        if let keyed = root["models"] as? [String: Any] {
            for (key, value) in keyed {
                guard let value = value as? [String: Any] else { continue }
                entries.append((key, (value["info"] as? [String: Any]) ?? value))
            }
        } else if let list = root["models"] as? [[String: Any]] {
            entries = list.map { (nil, ($0["info"] as? [String: Any]) ?? $0) }
        }
        var result: [String: [String]] = [:]
        for (key, model) in entries {
            guard let id = (model["model"] as? String) ?? (model["id"] as? String) ?? key,
                  model["supports_reasoning_effort"] as? Bool != false,
                  let efforts = model["reasoning_efforts"] as? [Any] else { continue }
            let names = efforts.compactMap { entry -> String? in
                if let string = entry as? String { return string }
                let entry = entry as? [String: Any]
                return (entry?["value"] as? String) ?? (entry?["id"] as? String)
            }.filter(EffortValue.isPlain)
            let sorted = names.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }
            if !sorted.isEmpty { result[id] = sorted }
        }
        return result
    }

    /// The catalog is the truth for each model's scale and bands; a band
    /// someone set in targets.json still wins, applied after this.
    public static func fill(_ target: EffortTarget, with catalog: [String: [String]]) -> EffortTarget {
        var updated = target
        for (model, levels) in catalog {
            updated.scales[model] = levels
            if let bands = BandMapping.byName(from: levels) { updated.bands[model] = bands }
        }
        return updated
    }
}
