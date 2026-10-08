import Foundation
import LidEffortCore

/// What the lid can offer one agent, read off this Mac: the model its
/// config runs, every level that model takes, what each of the lid's five
/// levels sets it to, and what is wrong, if anything. The same for every
/// agent — Setup and Settings draw it alike.
struct EffortOffer: Identifiable, Equatable {
    let id: String
    let name: String
    /// The config's model, as an id ("gpt-5.6-terra", "opus[1m]").
    let model: String?
    let enabled: Bool
    /// The agent's config file is on this Mac.
    let installed: Bool
    /// Every level the model takes, least to most. Empty: none at all.
    let scale: [String]
    /// The level its config holds now.
    let current: String?
    /// What each lid level writes, low → max. Nil: nothing is written.
    let perLevel: [String]?
    /// The values only a running session takes, never the config — Claude
    /// Code's `max` and `ultracode` — least to most.
    let liveOnly: [String]
    /// The one of those the lid's top types — Claude Code's `max`.
    let liveAtTop: String?
    var warning: String?

    var prettyModel: String? { model.map(ModelName.pretty) }
    /// Live-only values no lid level reaches — `ultracode` — picked by hand
    /// on the bar in the ring's tooltip, for the session in view.
    var liveChoices: [String] { liveOnly.filter { $0 != liveAtTop } }

    static func all(targets: [EffortTarget] = EffortTargetWriter.loadTargets()) -> [EffortOffer] {
        let read = Dictionary(EffortTargetWriter.currentValues().map { ($0.targetID, $0) }, uniquingKeysWith: { a, _ in a })
        return targets.map { target in
            let path = NSString(string: target.configPath).expandingTildeInPath
            let installed = FileManager.default.fileExists(atPath: path)
                && target.isPresent(exists: FileManager.default.fileExists(atPath:))
            let result = read[target.id]
            let model = result?.model ?? (installed ? readModel(target, path: path) : nil)
            return make(target: target, installed: installed, model: model, current: result?.value,
                        listed: EffortTargetWriter.listedModels(for: target.id))
        }
    }

    /// One agent's offer from what was read — kept apart from the disk so
    /// it can be checked.
    static func make(target: EffortTarget, installed: Bool, model: String?, current: String?,
                     listed: Set<String>?) -> EffortOffer {
        let scale = target.scale(for: model)
        let perLevel = target.bands(for: model).flatMap { $0.count == EffortLevel.allCases.count ? $0 : nil }
        let liveOnly = perLevel == nil ? [] : target.liveOnly(for: model)
        // As `EffortController.command` types it: Claude's top band goes in
        // live as `max` on a model that has it.
        let liveAtTop = target.id == "claude" && liveOnly.contains("max") ? "max" : nil
        var warning: String?
        if !installed {
            warning = L10n.t("Not on this Mac")
        } else if model != nil, perLevel == nil {
            warning = L10n.t("\(ModelName.pretty(model ?? "")) has no effort level, so the lid leaves it alone")
        } else if let model, let listed, !listed.isEmpty, !listed.contains(model) {
            warning = L10n.t("\(model) isn't in \(target.displayName)'s current model list. If it stops working, pick another in \(target.configPath)")
        }
        return EffortOffer(id: target.id, name: target.displayName, model: model, enabled: target.enabled,
                           installed: installed, scale: scale, current: current, perLevel: perLevel,
                           liveOnly: liveOnly, liveAtTop: liveAtTop, warning: warning)
    }

    private static func readModel(_ target: EffortTarget, path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return ConfigDocument.readString(key: target.modelKey, section: target.modelSection, format: target.format, text: text)
    }
}
