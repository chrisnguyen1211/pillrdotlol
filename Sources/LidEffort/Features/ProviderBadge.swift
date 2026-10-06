import SwiftUI

/// The agent's mark on a disc of its own colour — the way its app icon
/// looks, so a ring is recognised by colour before the glyph is read. Agents
/// without a known brand colour keep the plain template glyph.
struct ProviderBadge: View {
    let glyph: ProviderGlyph
    /// A custom endpoint's own image, drawn instead of the glyph.
    var customIconFilename: String? = nil

    /// Diameter of the disc, inside the gauge: clear of the track, larger
    /// than the glyph it carries.
    static let diameter = Design.px(50)

    var body: some View {
        if customIconFilename != nil {
            ProviderGlyphView(glyph: glyph, customIconFilename: customIconFilename)
        } else if let brand = Self.brand(for: glyph) {
            ZStack {
                Circle().fill(brand.fill)
                if let stroke = brand.stroke {
                    Circle().strokeBorder(stroke, lineWidth: Design.px(2.5))
                }
                ProviderGlyphView(glyph: glyph, size: Design.px(30))
                    .foregroundStyle(brand.ink)
            }
            .frame(width: Self.diameter, height: Self.diameter)
        } else {
            ProviderGlyphView(glyph: glyph)
                .foregroundStyle(Palette.textPrimary)
        }
    }

    struct Brand {
        let fill: AnyShapeStyle
        let ink: Color
        let stroke: Color?
    }

    static func brand(for glyph: ProviderGlyph) -> Brand? {
        switch glyph {
        case .claude:
            return Brand(fill: AnyShapeStyle(Color(red: 0.85, green: 0.47, blue: 0.34)), ink: .white, stroke: nil)
        case .openai:
            return Brand(fill: AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.55, green: 0.60, blue: 1.0), Color(red: 0.36, green: 0.42, blue: 0.98)],
                startPoint: .topLeading, endPoint: .bottomTrailing)), ink: .white, stroke: nil)
        case .grok:
            return Brand(fill: AnyShapeStyle(Color.black), ink: .white, stroke: Color.white.opacity(0.35))
        default:
            return nil
        }
    }
}
