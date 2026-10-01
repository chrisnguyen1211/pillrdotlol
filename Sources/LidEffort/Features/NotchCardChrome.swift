import SwiftUI

/// The surface every card beside the notch is drawn on: the glass (or the
/// solid fill), the corner, the padding, and the tail welded on towards the
/// notch. One component, so the done card, the approval card and anything
/// after them are the same object with different contents.
struct NotchCardChrome<Content: View>: View {
    let height: CGFloat
    var direction: NotchEdge.TooltipDirection = .trailing
    var tailOffset: CGFloat = 0
    @ViewBuilder let content: Content

    @Environment(\.notchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle

    private var glassy: Bool { surfaceStyle.effective == .glass && !reduceTransparency }
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        // The blurred desktop under the glass, or the glass
                        // has nothing to bend — see `GlassBackdrop`.
                        CardGlass(shape: TooltipSilhouette(direction: direction, tailOffset: tailOffset))
                    }
                }
            }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
            content
                .padding(NotchLayout.cardPadding)
                .frame(width: NotchLayout.cardWidth, height: height, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular))
        .overlay {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                    .strokeBorder(Palette.ringTrack, lineWidth: 1)
            }
        }
    }

    private var tail: some View {
        let size = TooltipTail.size(for: direction)
        return TooltipTail(direction: direction)
            .fill(surfaceFill)
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .up || direction == .down ? tailOffset : 0,
                    y: direction == .leading || direction == .trailing ? tailOffset : 0)
    }

    @ViewBuilder private var stack: some View {
        switch direction {
        case .leading:  HStack(spacing: 0) { card; tail }
        case .trailing: HStack(spacing: 0) { tail; card }
        case .down:     VStack(spacing: 0) { tail; card }
        case .up:       VStack(spacing: 0) { card; tail }
        }
    }
}

/// The header every notch card opens with: the agent's glyph, a title, and
/// one line under it saying which session and where.
struct NotchCardHeader: View {
    let glyph: ProviderGlyph
    let title: String
    let subtitle: String

    static var height: CGFloat {
        max(NotchLayout.glyphSize, NotchLayout.cardTitleLineHeight + NotchLayout.cardBodyLineHeight)
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchLayout.headerGap) {
            ProviderGlyphView(glyph: glyph)
                .foregroundStyle(Palette.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(Typography.cardBody)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: Self.height, alignment: .leading)
    }
}

/// The status line under a card's header: a dot in the colour that says
/// what state it is (green done, amber waiting on you), the words, and an
/// optional trailing note.
struct NotchCardStatus: View {
    let tone: Color
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Design.px(12)) {
            Circle().fill(tone).frame(width: Design.px(16), height: Design.px(16))
            Text(text)
                .font(Typography.cardBody)
                .foregroundStyle(tone)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.px(12))
            if let trailing {
                Text(trailing)
                    .font(Typography.cardBody.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .frame(height: NotchLayout.cardBodyLineHeight)
    }
}
