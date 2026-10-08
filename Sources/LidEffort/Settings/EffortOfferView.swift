import LidEffortCore
import SwiftUI

/// One agent's line in "what the lid sets": its mark, its model, and its
/// whole scale with the levels the lid reaches lit — the one it holds now
/// filled. A model with nothing to set says so instead of drawing chips.
struct EffortOfferRow: View {
    let offer: EffortOffer
    /// The lid's level now, to ring the value it sets.
    var level: EffortLevel? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            mark
                .frame(width: 22, height: 22)
                .foregroundStyle(offer.enabled && offer.installed ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(offer.name).font(.system(size: 13, weight: .medium))
                    if let model = offer.prettyModel {
                        Text(model).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let warning = offer.warning {
                    Label(warning, systemImage: offer.installed ? "exclamationmark.triangle.fill" : "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(offer.installed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if offer.installed, !offer.scale.isEmpty {
                    chips
                    if let liveOnly = offer.liveAtTop {
                        footnote(L10n.t("\(liveOnly) is typed into the session in view at the lid's top. The config can't hold it."))
                    }
                    ForEach(offer.liveChoices, id: \.self) { choice in
                        footnote(L10n.t("\(choice) runs multi-agent workflows on every task and uses many more tokens. No lid level reaches it: let go of the effort bar in the ring's tooltip on it, and it is typed into the session in view only."))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var mark: some View {
        if let glyph = ProviderGlyph.forProvider(offer.id) {
            ProviderGlyphView(glyph: glyph, size: 18)
        } else {
            Image(systemName: "sparkles").font(.system(size: 15))
        }
    }

    /// Every level the model has. Reached by the lid: outlined; held now:
    /// filled; the one the lid's level sets: ringed in the accent colour.
    /// A value only picked by hand for the session in view (`ultracode`):
    /// a dashed outline.
    private var chips: some View {
        let reached = Set(offer.perLevel ?? []).union(offer.liveAtTop.map { [$0] } ?? [])
        let choices = Set(offer.liveChoices)
        let aimed = level.flatMap { level in
            level == .max && offer.liveAtTop != nil ? offer.liveAtTop : offer.perLevel?[level.rawValue]
        }
        return HStack(spacing: 4) {
            ForEach(offer.scale, id: \.self) { value in
                let held = value == offer.current
                Text(value)
                    .font(.system(size: 10.5, weight: held ? .semibold : .regular))
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .foregroundStyle(held ? Color.white : (reached.contains(value) ? Color.primary : Color.secondary.opacity(0.6)))
                    .background(Capsule().fill(held ? Color.accentColor : Color.primary.opacity(reached.contains(value) ? 0.08 : 0.03)))
                    .overlay(Capsule().strokeBorder(value == aimed && !held ? Color.accentColor : .clear, lineWidth: 1))
                    .overlay(Capsule().strokeBorder(choices.contains(value) ? Color.secondary.opacity(0.6) : .clear,
                                                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    .help(reached.contains(value) ? L10n.t("The lid reaches this level")
                          : choices.contains(value) ? L10n.t("Only typed into the session in view, from the effort bar in the ring's tooltip")
                          : L10n.t("Only set by hand in the agent itself"))
            }
        }
    }
}
