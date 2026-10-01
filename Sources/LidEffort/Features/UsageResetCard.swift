import SwiftUI

/// The notification modal card displayed beside the notch when a provider's limit resets.
struct UsageResetCard: View {
    let event: UsageResetEvent
    let direction: NotchEdge.TooltipDirection
    var tailOffset: CGFloat = 0
    var onDismiss: (() -> Void)? = nil

    @Environment(\.notchAccentColor) private var accentColor
    @Environment(\.notchReduceTransparency) private var reduceTransparency
    @Environment(\.notchSurfaceStyle) private var surfaceStyle

    static let cardHeight: CGFloat = Design.px(210)

    private var glassy: Bool { surfaceStyle.effective == .glass && !reduceTransparency }
    private var surfaceFill: Color { glassy ? .clear : Palette.card }

    var body: some View {
        stack
            .background {
                if glassy {
                    if #available(macOS 26.0, *) {
                        // The blurred desktop under the glass, or the glass has
                        // nothing to bend — see `GlassBackdrop`.
                        CardGlass(shape: TooltipSilhouette(direction: direction, tailOffset: tailOffset))
                    }
                }
            }
    }

    /// A reset is the one piece of good news this card carries, and it is
    /// said like one; the limit-reached cards keep to the facts.
    private var titleText: String {
        switch event.kind {
        case .reset:
            return ResetCheer.line(for: event).title
        case .sessionLimitReached:
            return L10n.t("\(event.providerName) Limit Reached")
        case .weeklyLimitReached:
            return L10n.t("\(event.providerName) Weekly Limit")
        }
    }

    private var subtitleText: String {
        switch event.kind {
        case .reset:
            return ResetCheer.line(for: event).subtitle
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("\(event.windowLabel) limit is spent")
        }
    }

    private var statusColor: Color {
        switch event.kind {
        case .reset:
            return Palette.ample
        case .sessionLimitReached, .weeklyLimitReached:
            return Palette.critical
        }
    }

    private var statusText: String {
        switch event.kind {
        case .reset:
            return L10n.t("Quota is available (0% used)")
        case .sessionLimitReached:
            return L10n.t("Session limit reached (100% used)")
        case .weeklyLimitReached:
            return L10n.t("Weekly limit reached (100% used)")
        }
    }

    private var resetTimePrefix: String {
        switch event.kind {
        case .reset:
            return L10n.t("Next reset")
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("Resets at")
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: Self.cardHeight)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: NotchLayout.headerGap) {
                    ProviderGlyphView(glyph: event.glyph)
                        .foregroundStyle(Palette.textPrimary)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            // One line, shrunk a little before it is cut:
                            // the card's height is fixed, and a cheer with a
                            // long provider name in it must not push the
                            // status line off the bottom.
                            Text(titleText)
                                .font(Typography.cardTitle)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .layoutPriority(1)

                            Spacer(minLength: Design.px(12))

                            if let onDismiss {
                                Button(action: onDismiss) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Palette.textSecondary)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text(subtitleText)
                            .font(Typography.cardBody)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: Design.px(12)) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: Design.px(16), height: Design.px(16))

                    Text(statusText)
                        .font(Typography.cardBody)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.top, NotchLayout.headerToBlock)

                if let resetsAt = event.resetsAt {
                    Text("\(resetTimePrefix) \(resetsAt.formatted(date: .omitted, time: .shortened))")
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .padding(.top, Design.px(8))
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        }
        .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .top)
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
        case .leading:
            HStack(spacing: 0) { card; tail }
        case .trailing:
            HStack(spacing: 0) { tail; card }
        case .down:
            VStack(spacing: 0) { tail; card }
        case .up:
            VStack(spacing: 0) { card; tail }
        }
    }
}
