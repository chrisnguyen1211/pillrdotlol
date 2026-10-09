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
    /// Taller for badges, so the badge has room to land.
    static let badgeCardHeight: CGFloat = Design.px(490)

    static func cardHeight(for event: UsageResetEvent) -> CGFloat {
        (event.note?.badges.isEmpty ?? true) ? cardHeight : badgeCardHeight
    }

    private var height: CGFloat { Self.cardHeight(for: event) }

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
        case .recap:
            return event.note?.title ?? event.recap?.title ?? ""
        }
    }

    private var subtitleText: String {
        switch event.kind {
        case .reset:
            return ResetCheer.line(for: event).subtitle
        case .sessionLimitReached, .weeklyLimitReached:
            return L10n.t("\(ResetCheer.limitPhrase(event.windowLabel)) is spent")
        case .recap:
            return event.note?.subtitle ?? event.recap?.subtitle ?? ""
        }
    }

    private var statusColor: Color {
        switch event.kind {
        case .reset:
            return Palette.ample
        case .sessionLimitReached, .weeklyLimitReached:
            return Palette.critical
        case .recap:
            return event.note.map { $0.good ? Palette.ample : Palette.watch } ?? Palette.ample
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
        case .recap:
            return event.note?.status ?? event.recap?.status ?? ""
        }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NotchLayout.cardCorner, style: .circular)
                .fill(surfaceFill)
                .frame(width: NotchLayout.cardWidth, height: height)

            if let badges = event.note?.badges, !badges.isEmpty {
                badgeContent(badges)
            } else {
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
                    // "Resets Thu 3:00 PM" — a weekly limit four days out
                    // says which day, not only the hour.
                    Text(ResetCopy.text(for: resetsAt))
                        .font(Typography.cardBody)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .padding(.top, Design.px(8))
                }
            }
            .padding(NotchLayout.cardPadding)
            .frame(width: NotchLayout.cardWidth, height: Self.cardHeight, alignment: .topLeading)
            }
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

    /// Badges just earned, as the Fitness awards arrive: the badge large in
    /// the middle, flipping in with its burst, and under it what it is and
    /// what it was for.
    private func badgeContent(_ badges: [Achievements.Badge]) -> some View {
        let height = Self.cardHeight(for: event)
        return VStack(spacing: Design.px(6)) {
            BadgeBurst(badges: badges, size: Design.px(210))
                .frame(height: Design.px(300))
            Text(statusText.uppercased())
                .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(Palette.ample)
                .lineLimit(1)
            Text(titleText)
                .font(Typography.cardTitle.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitleText)
                .font(Typography.cardBody)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchLayout.cardPadding)
        .padding(.top, Design.px(10))
        .frame(width: NotchLayout.cardWidth, height: height, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .padding(Design.px(26))
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
