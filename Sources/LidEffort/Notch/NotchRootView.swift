import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    /// The pointer, for the hover effects inside — see `NotchPointer`.
    var pointer: NotchPointer? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchReduceTransparency) private var reduceTransparency

    var body: some View {
        root.environment(\.notchPointer, pointer)
            // Out of sight while the tour's intro flies its own pill in, so
            // this one appears as that one lands.
            .opacity(model.tourVeiled ? 0 : 1)
            .animation(.easeOut(duration: 0.45), value: model.tourVeiled)
    }

    private var root: some View {
        // Measured rather than assumed: the panel's real size is whatever
        // AppKit settled on, and the notch has to sit flush against *that*
        // edge, not against the size we asked for.
        GeometryReader { proxy in
            let place = NotchPlacement(edge: model.edge, panelSize: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                notch(place)

                // Outside the notch and outside its clip: the orb hangs past
                // the end of the shape, tucked into the corner the far flare
                // makes.
                SettingsOrb(isHovered: model.isHoveringSettings, edge: model.edge,
                                    inline: model.orbsInline,
                                    convex: model.orbHugsCorner,
                                    arcRadius: model.orbArcRadius,
                                    arcOffset: model.orbArcOffset,
                                    spins: model.settingsSpins,
                                    restingCentre: model.pillOrbCentre)
                        // A second route to the same action the panel's own
                        // `mouseDown` override reaches for — see
                        // `NotchViewModel.onOpenSettings`. Both still depend
                        // on the panel's `ignoresMouseEvents`/`hitTest` gate
                        // to receive the click at all, so this alone would
                        // not rescue a click that never reaches the content
                        // view — but once it does, this fires reliably where
                        // the AppKit-level path did not.
                        .contentShape(Circle())
                        .onTapGesture {
                            model.settingsSpins += 1
                            model.onOpenSettings?()
                        }
                        // Before `position`, not after. `position` hands back a
                        // view the size of the whole panel with the orb placed
                        // inside it, so a scale applied after this one scales
                        // *that* layer about the panel's centre — which moves
                        // the orb away from the notch by a share of the panel,
                        // and left the arc floating off the corner it is drawn
                        // to hug. Here it scales the orb about its own centre,
                        // which is what `orbCentre` then places.
                        .scaleEffect(model.sizeScale)
                        .position(orbCentre(place))
                        // Pushed past the bezel with the shape, or it sits
                        // that far off the curve it traces.
                        .offset(x: model.edge.outward.x * Self.bezelBleed,
                                y: model.edge.outward.y * Self.bezelBleed)
                        // Outward, into the black — not inward to nothing.
                        .scaleEffect(model.isExpanded ? 1 : model.orbMergeScale)
                        // Full strength the whole way in. The arc is buried in
                        // the notch before this reaches zero, so the fade is
                        // only there to guarantee nothing is left on screen
                        // once the notch has folded — it is never what the eye
                        // sees the arc leave by.
                        .opacity(model.isExpanded ? 1 : 0)
                        .animation(motion(orbMotion), value: model.isExpanded)

                // The move handle, mirroring the settings orb at the other end
                // of the stack. Same construction, same reasons — see the
                // comments on the orb above; only the placement differs.
                if model.showsMoveHandle {
                    MoveHandle(isHovered: model.isHoveringMove || model.isMoving,
                               isArmed: model.isMoving,
                               edge: model.edge,
                               inline: model.orbsInline,
                               convex: model.orbHugsCorner,
                               arcRadius: model.orbArcRadius,
                               arcOffset: model.moveArcOffset,
                               spins: model.moveSpins,
                               restingCentre: model.pillMoveCentre)
                            .contentShape(Circle())
                            .scaleEffect(model.sizeScale)
                            .position(moveCentre(place))
                            .offset(x: model.edge.outward.x * Self.bezelBleed,
                                    y: model.edge.outward.y * Self.bezelBleed)
                            .scaleEffect(model.isExpanded ? 1 : model.orbMergeScale)
                            .opacity(model.isExpanded ? 1 : 0)
                            .animation(motion(orbMotion), value: model.isExpanded)
                }

                if let resetEvent = model.activeResetAlert,
                   model.isExpanded,
                   model.hoveredIndex == nil {
                    let index = model.resetAlertIndex(for: resetEvent) ?? 0
                    let snapshot = model.snapshots[safe: index] ?? model.snapshots.first ?? Fixtures.snapshots().first!
                    UsageResetCard(
                        event: resetEvent,
                        direction: model.edge.tooltipDirection,
                        tailOffset: tooltipTailOffset(index: index, snapshot: snapshot),
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                model.activeResetAlert = nil
                            }
                        }
                    )
                    .scaleEffect(model.cardScale)
                    .position(resetCardCentre(place, index: index))
                    .transition(.opacity.combined(with: .offset(
                        x: model.edge.outward.x * Design.px(24),
                        y: model.edge.outward.y * Design.px(24)
                    )))
                } else if let effortEvent = model.activeEffortAlert,
                          model.isExpanded,
                          model.hoveredIndex == nil {
                    let index = model.effortAlertIndex() ?? 0
                    let snapshot = model.snapshots[safe: index] ?? model.snapshots.first ?? Fixtures.snapshots().first!
                    EffortChangeCard(
                        event: effortEvent,
                        direction: model.edge.tooltipDirection,
                        tailOffset: tooltipTailOffset(index: index, snapshot: snapshot),
                        livePosition: model.effortPreview,
                        onSet: model.onSetLidLevel
                    )
                    .scaleEffect(model.cardScale)
                    .position(resetCardCentre(place, index: index,
                                              height: EffortChangeCard.cardHeight(for: effortEvent)))
                    .transition(.opacity.combined(with: .offset(
                        x: model.edge.outward.x * Design.px(24),
                        y: model.edge.outward.y * Design.px(24)
                    )))
                } else if let snapshot = model.hoveredSnapshot, let index = model.hoveredIndex,
                   model.isExpanded {
                    TooltipCard(
                        snapshot: snapshot,
                        activity: model.activity(for: snapshot),
                        now: model.now,
                        direction: model.edge.tooltipDirection,
                        sessionCap: model.sessionCap(for: snapshot),
                        resetTimeFormat: model.resetTimeFormat,
                        tailOffset: tooltipTailOffset(index: index, snapshot: snapshot),
                        onFocusSession: model.onFocusSession,
                        effortValue: model.effortValue(for: snapshot),
                        connect: model.connectNeed(for: snapshot),
                        onConnect: { model.onConnect?(snapshot.id) },
                        effortDots: model.effortDots(for: snapshot),
                        onSetEffort: { index in model.onSetEffort?(snapshot.providerID, index) },
                        prompt: model.prompt(for: snapshot),
                        promptDraft: model.prompt(for: snapshot).map { model.draft(for: $0) },
                        promptQueue: model.promptQueue,
                        onPagePrompt: { model.pagePrompt(by: $0) },
                        onAnswerPrompt: { id, answer in model.answer(id, with: answer, from: .tooltip) },
                        onOpenPrompt: { prompt in model.open(prompt, from: .tooltip) },
                        promptWaiting: model.promptWaiting,
                        promptEcho: model.promptEcho?.origin == .tooltip ? model.promptEcho : nil,
                        tourFocus: model.tourHeldIndex == index ? model.tourFocus : nil
                    )
                        // Deliberately *no* `.id` here: the card is one object
                        // that travels and resizes between cells, which reads
                        // far better than one card leaving and another arriving.
                        // What must not interpolate is its contents — see
                        // `TooltipCard`.
                        .scaleEffect(model.cardScale)
                        .position(tooltipCentre(place, index: index, snapshot: snapshot))
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(24),
                            y: model.edge.outward.y * Design.px(24)
                        )))
                }

                // A finished session, said from the pill. Only while folded:
                // open, the ring's own arc already says it, and the line
                // would sit across the cells.
                // A prompt waiting on you, beside the folded pill: answerable
                // without opening the notch. It outranks the done line — the
                // session is blocked, which is the more urgent fact.
                if let prompt = model.visiblePromptCard {
                    PromptCard(prompt: prompt, draft: model.draft(for: prompt),
                               direction: model.edge.tooltipDirection,
                               onAnswer: { model.answer(prompt.id, with: $0) },
                               onOpen: { model.open(prompt) },
                               queue: model.promptQueue,
                               onPage: { model.pagePrompt(by: $0) })
                        // Its own identity per prompt, so the picks made on
                        // one are never the starting state of the next.
                        .id(prompt.id)
                        .scaleEffect(model.cardScale)
                        .position(promptCardCentre(place, prompt: prompt))
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(40),
                            y: model.edge.outward.y * Design.px(40)
                        )).combined(with: .scale(scale: 0.9)))
                } else if let echo = model.promptEcho, echo.origin == .card, !model.isExpanded {
                    // The answer, said for a moment where the card was.
                    PromptEchoPill(echo: echo)
                        .id(echo.id)
                        .scaleEffect(model.cardScale)
                        .position(echoCentre(place))
                } else if let toast = model.activeDoneToast, !model.isExpanded, model.currentPrompt == nil {
                    DoneToastView(toast: toast, direction: model.edge.tooltipDirection)
                        .scaleEffect(model.cardScale)
                        .position(doneToastCentre(place))
                        // Out of the pill and back into it.
                        .transition(.opacity.combined(with: .offset(
                            x: model.edge.outward.x * Design.px(40),
                            y: model.edge.outward.y * Design.px(40)
                        )).combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Swapping cards is a movement like any other here.
            .animation(motion(NotchMotion.glide), value: model.hoveredIndex)
            .animation(motion(NotchMotion.contents), value: model.activeDoneToast)
            .animation(motion(NotchMotion.contents), value: model.prompts)
        }
        .animation(motion(NotchMotion.unfold), value: model.isExpanded)
        .tint(model.accentColor.color)
        .environment(\.notchAccentColor, model.accentColor.color)
        .environment(\.notchSurfaceStyle, model.surfaceStyle)
        .environment(\.pillFrost, model.pillFrost)
        .environment(\.glassSeesBehind, model.glassSeesBehind)
        .environment(\.cardGlassSeesBehind, model.cardGlassSeesBehind)
    }

    /// Opening and closing are not mirror images. Appearing, the arc waits its
    /// turn behind the cells before it; hiding, any delay at all lets the notch
    /// start folding first, and the arc reads as going with the frame rather
    /// than into it.
    private var orbMotion: Animation {
        model.isExpanded
            ? NotchMotion.stagger(index: model.snapshots.count)
            : NotchMotion.merge
    }

    private func notch(_ place: NotchPlacement) -> some View {
        let shape = SideNotchShape(edge: model.edge, joining: model.joinedNotch,
                                   hanging: model.hangsFromBezel,
                                   cornerRadius: model.drawnCornerRadius)
        // Reduce transparency means "no see-through chrome", which for the
        // notch is the solid style — the same precedence the Settings window
        // applies to its own translucent chrome.
        let glassy = model.surfaceStyle.effective == .glass
            && !reduceTransparency

        return ZStack {
            ZStack {
                // The glass *is* the shape. Liquid Glass bends the light at
                // the edge of the shape it is given — that lensing is what
                // makes the system's own volume capsule read as glass — and
                // a sheet of it the size of the panel, clipped to the notch,
                // had its edges cut away: a flat tint with no rim. Given the
                // capsule itself, the rim is the capsule's.
                //
                // `.clear`, not `.regular`: regular glass adapts to what is
                // behind it and over a dark window goes near-black — the
                // pill "sometimes turning black". Clear stays clear, bends
                // the light hard at its rim, and is what the system's own
                // volume capsule is made of. The chrome carries no text, so
                // it can afford it; the cards, which do, stay regular.
                //
                // Not under test: rendered offscreen, glass in a shape comes
                // out as a solid black stand-in, and the render tests tell
                // the glass style from the solid one by the notch's own black
                // not being painted. Nothing on screen is decided here.
                //
                // Over the desktop the glass sees nothing and turns grey;
                // there `ChromeGlass` shows the blurred screen instead.
                if glassy, !Runtime.isUnderTest {
                    if #available(macOS 26.0, *) {
                        ChromeGlass(shape: shape)
                    }
                }
                // Nothing else of ours underneath: a wash of our own would
                // override the Clear/Tinted choice in Appearance settings,
                // which is the whole point of handing this surface to the
                // system. The solid fill is its own branch rather than the
                // same view at zero opacity: an opacity that changes with
                // the style is animated, and a render taken mid-animation
                // showed the glass style painted black.
                if !glassy {
                    shape.fill(Palette.notch)
                }
                // The rim's strokes belong to the solid style: glass draws
                // its own edge. The sheen is for both. Not when joined to
                // the hardware notch: that band holds nothing but black, and
                // a rim there would draw a light edge round a hole in the
                // screen.
                if NotchLayout.pillShape, model.joinedNotch == nil {
                    PillRim(shape: shape,
                            isFolded: !model.isExpanded,
                            reduceMotion: reduceMotion,
                            strokes: !glassy || !model.glassSeesBehind)
                }

                // The band at the hardware's height is the strip beside a hole in
                // the screen. Glass there makes the cutout read as a black
                // rectangle set into a sheet of glass; black there makes the hole
                // and the shape we draw one wide notch again, and the glass begins
                // below it, where the readings begin. A hardware notch only ever
                // joins the top edge, so `.top` is the right alignment; the band is
                // clipped by the `.clipShape(shape)` below, which keeps the bezel
                // fillets at its corners.
                //
                // Deeper than the hardware by the bleed below, and undoing the
                // scale on that one number: the whole shape is pushed `bezelBleed`
                // points past the screen edge after it is scaled, so a band drawn
                // exactly `contentInset` deep ends that far short of the hole and
                // leaves a strip of glass along the bottom of the cutout.
                if model.joinedNotch != nil {
                    Rectangle()
                        .fill(Palette.notch)
                        .frame(height: model.contentInset + Self.bezelBleed / model.sizeScale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }   
            // The glass and the fill both stay mounted so folding keeps
            // animating one shape rather than swapping one view for another
            // mid-flight; the crossfade rides on the unfold animation already
            // on the root. The band above them is opaque in every state and
            // takes no part in it.
            .frame(width: model.notchSize.width, height: model.notchSize.height)
            // Aligned to the corner where the stack starts *and* the bezel is,
            // then pushed clear of any hardware notch. Centring the contents in
            // a shape that had been made deeper is what put the top of every
            // ring inside the hole in the display.
            .overlay(alignment: contentAlignment) {
                cells.padding(bezelSide, model.contentInset)
            }
            // Masked by the notch itself, not by its bounding box. Without this
            // the cells simply sit on top of a shrinking shape and appear to
            // slide out of the end of it; clipped, they are swallowed by the
            // outline as it closes, which is what a notch should do.
            .clipShape(shape)
            // The size choice, applied to the notch and the cells it carries —
            // and to nothing else. Drawn at design-frame size and scaled from
            // there, so `NotchLayout` keeps measuring the one thing it is
            // quoted from.
            // Scaled *from the bezel*, so the outer edge is a fixed point of
            // the transform rather than a number that has to come out right.
            .scaleEffect(model.sizeScale, anchor: bezelAnchor)
            // Neither argument may depend on the scale, and that is the whole
            // point of the anchor above. They used to: `across` was
            // `notchDepth * sizeScale / 2`, which cancels against a
            // centre-anchored scale — but only once both have settled.
            // SwiftUI animates `scaleEffect` and `position` independently, so
            // while a size change is in flight the eased scale and the
            // stepped position disagree and the notch lifts off the bezel,
            // snapping back at the end. Anchored at the edge with a position
            // that never moves, there is nothing left to disagree about: the
            // shape grows inward from a corner that cannot move, animated or
            // not.
            .position(place.point(
                along: (model.edge.isVertical ? place.panelSize.height
                                              : place.panelSize.width) / 2,
                across: model.notchDepth / 2
            ))
            // Pushed a shade past the bezel, and then clipped by the panel.
            //
            // The arithmetic above already lands the shape's outer edge on the
            // screen's, but "exactly" is doing a lot of work: the scale is a
            // fraction, the shape is antialiased, and a display can round its
            // last column its own way. Any of those leaves a hairline of
            // wallpaper between the notch and the bezel — the one thing this
            // shape must never show, since it is meant to read as part of the
            // frame of the screen. Overhanging costs nothing: the panel ends
            // at the bezel and everything past it is simply not drawn.
            .offset(x: model.edge.outward.x * Self.bezelBleed,
                    y: model.edge.outward.y * Self.bezelBleed)
    }

    /// The bezel side as a scaling anchor: the edge the notch is welded to
    /// stays put while everything else moves toward or away from it.
    private var bezelAnchor: UnitPoint {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    /// How far the shape may overhang the screen edge. Small enough that the
    /// notch is not visibly shallower for it, large enough to swallow a
    /// rounding error at any size.
    private static let bezelBleed: CGFloat = 2

    /// The cells fade and lift into place a beat after the shape starts opening,
    /// each trailing the one before it. Folded shut they are not just hidden but
    /// pulled toward the edge, so the whole thing reads as one movement.
    @ViewBuilder
    private var cells: some View {
        let stack = ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
            ProviderCell(
                snapshot: snapshot,
                // Nil while folded: the cells are hidden, not gone, and a
                // spinning arc in a hidden cell still redraws every frame.
                activity: model.isExpanded ? model.activity(for: snapshot) : nil,
                isRefreshing: model.isRefreshing(snapshot),
                weeklyRing: model.weeklyRing,
                effortDots: model.effortDots(for: snapshot),
                showsLabel: model.showsCellLabels
            )
                // Pinned to what the cell claims along the stack, or the drawn
                // rings stop lining up with the centres `ringCenter` hands to
                // the hover bands and the tooltip tails. Across a horizontal
                // edge that is the ring alone — the label sits below it, in the
                // notch's depth, and claims nothing here.
                .frame(width: model.edge.isVertical ? nil : NotchLayout.cellAlong(for: model.edge))
                .opacity(model.isExpanded ? 1 : 0)
                // A short slide toward the edge, no scaling: the clip is
                // already doing the concealing, and scaling on top of it
                // reads as two effects fighting.
                .offset(
                    x: model.isExpanded ? 0 : model.edge.outward.x * Design.px(28),
                    y: model.isExpanded ? 0 : model.edge.outward.y * Design.px(28)
                )
                .animation(motion(NotchMotion.stagger(index: index)), value: model.isExpanded)
                .transition(.opacity.combined(with: .offset(
                    x: model.edge.outward.x * Design.px(28),
                    y: model.edge.outward.y * Design.px(28)
                )).animation(motion(NotchMotion.unfold)))
        }

        Group {
            if model.edge.isVertical {
                VStack(spacing: model.cellSpacing) { stack }
                    .padding(.top, leadIn)
                    // The contents keep the expanded layout while folding, so
                    // the stack does not reflow on its way out; the shape clips it.
                    .frame(width: model.bodyDepth)
            } else {
                HStack(spacing: model.cellSpacing) { stack }
                    .padding(.leading, leadIn)
                    .frame(height: model.bodyDepth)
            }
        }
        .allowsHitTesting(model.isExpanded)
    }

    /// The corner of the shape's own frame where the stack starts and the
    /// bezel is — the origin everything inside it is measured from.
    private var contentAlignment: Alignment {
        switch model.edge {
        case .right:  return .topTrailing
        case .left:   return .topLeading
        case .top:    return .topLeading
        case .bottom: return .bottomLeading
        }
    }

    /// Which side of that frame faces the bezel.
    private var bezelSide: Edge.Set {
        switch model.edge {
        case .right:  return .trailing
        case .left:   return .leading
        case .top:    return .top
        case .bottom: return .bottom
        }
    }

    /// Distance from the start of the shape to the first cell, widening
    /// included so the readings stay in the middle of a bar that was stretched
    /// to cover the hardware notch.
    private var leadIn: CGFloat {
        model.flare + NotchLayout.padStart(for: model.edge) + model.endSpread
    }

    private func motion(_ animation: Animation) -> Animation? {
        NotchMotion.respectingReduceMotion(animation, reduceMotion)
    }


    /// The orb sits on the flare's own centre of curvature, one radius in from
    /// the bezel and level with the far end of the shape.
    /// The orb belongs to the notch, not to the tooltip, so it scales with it —
    /// it is tucked into the corner the shape's own flare makes, and a fixed
    /// orb against a scaled flare would sit off that corner.
    private func orbCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.orbAlong * model.sizeScale,
            across: model.orbInset * model.sizeScale
        )
    }

    private func moveCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.moveAlong * model.sizeScale,
            across: model.orbInset * model.sizeScale
        )
    }

    private func tooltipLength(_ snapshot: ProviderSnapshot) -> CGFloat {
        model.edge.isVertical
            ? NotchLayout.cardHeight(
                windowCount: snapshot.windows.count,
                groupCount: snapshot.windowGroupCount,
                moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
                usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
                sessionCount: snapshot.localModel == nil ? (model.activity(for: snapshot.id)?.sessions.count ?? 0) : 0,
                sessionCap: model.sessionCap(for: snapshot),
                statusMessage: snapshot.statusMessage,
                blockMessage: snapshot.block?.summary(now: model.now),
                hasTokenUsage: snapshot.tokenUsage != nil,
                hasPlan: snapshot.plan != nil,
                hasResetCredits: snapshot.resetCredits != nil,
                localModelName: snapshot.localModel?.name,
                showsLocalPerformance: snapshot.showsLocalPerformance,
                localLedgerRows: snapshot.localLedgerRowCount,
                compactRowCount: snapshot.compactRowCount,
                effortRow: model.hasEffortRow(for: snapshot),
                promptHeight: model.promptHeight(for: snapshot)
            )
            : NotchLayout.cardWidth
    }

    /// In the card's own units, which are scaled by `cardScale` on screen.
    private func tooltipTailOffset(index: Int, snapshot: ProviderSnapshot) -> CGFloat {
        (model.slack + model.ringCenter(index: index) * model.sizeScale
            - model.tooltipAlong(index: index, length: tooltipLength(snapshot) * model.cardScale))
            / model.cardScale
    }

    /// The tooltip is the card plus its tail; `position` centres that pair, so
    /// the tail lands on the hovered cell and the card sits beyond it.
    private func tooltipCentre(
        _ place: NotchPlacement, index: Int, snapshot: ProviderSnapshot
    ) -> CGPoint {
        let card = model.edge.isVertical
            ? NotchLayout.cardWidth
            : NotchLayout.cardHeight(
                windowCount: snapshot.windows.count,
                groupCount: snapshot.windowGroupCount,
                moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
                usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
                sessionCount: snapshot.localModel == nil ? (model.activity(for: snapshot.id)?.sessions.count ?? 0) : 0,
                sessionCap: model.sessionCap(for: snapshot),
                statusMessage: snapshot.statusMessage,
                blockMessage: snapshot.block?.summary(now: model.now),
                hasTokenUsage: snapshot.tokenUsage != nil,
                hasPlan: snapshot.plan != nil,
                hasResetCredits: snapshot.resetCredits != nil,
                localModelName: snapshot.localModel?.name,
                showsLocalPerformance: snapshot.showsLocalPerformance,
                localLedgerRows: snapshot.localLedgerRowCount,
                compactRowCount: snapshot.compactRowCount,
                effortRow: model.hasEffortRow(for: snapshot),
                promptHeight: model.promptHeight(for: snapshot)
            )
        // The ring it points at has moved with the notch, so the tail follows
        // it — but the card beyond the tail is drawn at its own size, and
        // `tooltipInset` already ends where the drawn notch does.
        return place.point(
            along: model.tooltipAlong(index: index, length: tooltipLength(snapshot) * model.cardScale),
            across: model.tooltipInset + (NotchLayout.tailLength + card) * model.cardScale / 2
        )
    }

    private func resetCardCentre(_ place: NotchPlacement, index: Int,
                                 height: CGFloat = UsageResetCard.cardHeight) -> CGPoint {
        let card = model.edge.isVertical ? NotchLayout.cardWidth : height
        let cardAlong = model.edge.isVertical ? height : NotchLayout.cardWidth
        return place.point(
            along: model.tooltipAlong(index: index, length: cardAlong * model.cardScale),
            across: model.tooltipInset + (NotchLayout.tailLength + card) * model.cardScale / 2
        )
    }

    private func promptCardCentre(_ place: NotchPlacement, prompt: PendingPrompt) -> CGPoint {
        let height = PromptCard.cardHeight(for: prompt, index: model.promptIndex(of: prompt))
        let card = model.edge.isVertical ? NotchLayout.cardWidth : height
        return place.point(
            along: model.slack + model.shapeLength * model.sizeScale / 2,
            across: model.restingDepth * model.sizeScale + NotchLayout.tailGap
                + (NotchLayout.tailLength + card) * model.cardScale / 2
        )
    }

    private func echoCentre(_ place: NotchPlacement) -> CGPoint {
        place.point(
            along: model.slack + model.shapeLength * model.sizeScale / 2,
            across: model.restingDepth * model.sizeScale + NotchLayout.tailGap
                + (NotchLayout.tailLength + NotchLayout.cardWidth / 4) * model.cardScale
        )
    }

    /// Beside the folded pill, level with its middle, its tail a tail's gap
    /// off the pill — the same seam the tooltip keeps from the open notch,
    /// measured from the pill rather than the open shape.
    private func doneToastCentre(_ place: NotchPlacement) -> CGPoint {
        let card = model.edge.isVertical ? NotchLayout.cardWidth : DoneToastView.cardHeight
        return place.point(
            along: model.slack + model.shapeLength * model.sizeScale / 2,
            across: model.restingDepth * model.sizeScale + NotchLayout.tailGap
                + (NotchLayout.tailLength + card) * model.cardScale / 2
        )
    }
}

/// The pill's edge.
///
/// Glass over a light window is glass over white: the folded pill vanished
/// whenever the app under it was in light mode. A rim that is dark on the
/// outside and light on the inside reads on either, and while the pill is
/// folded a slow sheen runs its length, so it keeps looking like a thing
/// with a surface rather than a smudge on the bezel.
private struct PillRim<S: Shape>: View {
    let shape: S
    let isFolded: Bool
    let reduceMotion: Bool
    /// Full-strength dark-outside, light-inside strokes: for the solid
    /// style, where there is no glass to draw an edge of its own. Off,
    /// they are still drawn, faintly.
    var strokes = true

    /// When the pill last folded: the sheen runs once from then and stops.
    @State private var foldedAt: Date?
    /// Set once the pass is over. The timeline's `paused` has to come from
    /// state: computed from the clock in `body`, it was only ever evaluated
    /// when the body was rebuilt — never, once the pill sat still — so the
    /// timeline ran at 24 fps for as long as the pill was folded.
    @State private var sheenDone = false

    /// How long the sheen runs after a fold. It used to run for ever while
    /// the pill was folded — which is nearly always — at 24 frames a second,
    /// each one a gradient through a mask over glass over a behind-window
    /// blur, so the compositor re-blurred the screen edge all day long.
    /// That was the lag, and the battery. One pass, then nothing moves.
    private var sheenDuration: TimeInterval { NotchLayout.pillSheenDuration }

    var body: some View {
        ZStack {
            // Only the inner half of a stroke survives the clip the notch
            // applies to itself, so each is drawn at twice its visible width.
            // Always drawn — faint over glass, which has an edge of its own,
            // full over the solid fill. Making them conditional was what
            // rendered the folded glass notch black offscreen: a view whose
            // structure differs from the last render's is transitioned, and
            // the frame caught mid-transition is the previous one.
            shape.stroke(Color.black.opacity(strokes ? 0.45 : 0.18), lineWidth: NotchLayout.hairline * 3)
            shape.stroke(Color.white.opacity(strokes ? 0.6 : 0.3), lineWidth: NotchLayout.hairline * 1.5)

            // Not under test: the transparency checks sample the pill's
            // middle, and where the sheen is at that instant is chance.
            if let foldedAt, isFolded, !reduceMotion, !Runtime.isUnderTest {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: sheenDone)) { context in
                    let elapsed = context.date.timeIntervalSince(foldedAt)
                    let phase = CGFloat(min(1, max(0, elapsed / sheenDuration)))
                    GeometryReader { proxy in
                        let vertical = proxy.size.height >= proxy.size.width
                        let long = max(proxy.size.width, proxy.size.height)
                        let travel = (phase * 1.6 - 0.3) * long
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.3), location: 0.5),
                                    .init(color: .clear, location: 1)],
                            startPoint: vertical ? .top : .leading,
                            endPoint: vertical ? .bottom : .trailing
                        )
                        .frame(width: vertical ? proxy.size.width : long * 0.45,
                               height: vertical ? long * 0.45 : proxy.size.height)
                        .offset(x: vertical ? 0 : travel, y: vertical ? travel : 0)
                        // Gone once it has passed, so the last frame does
                        // not sit on the pill as a stripe.
                        .opacity(phase < 1 ? 1 : 0)
                    }
                    .mask(shape)
                }
            }
        }
        .onAppear { if isFolded { foldedAt = Date() } }
        .onChange(of: isFolded) { _, folded in foldedAt = folded ? Date() : nil }
        .task(id: foldedAt) {
            sheenDone = false
            guard foldedAt != nil else { return }
            try? await Task.sleep(for: .seconds(sheenDuration + 0.1))
            sheenDone = true
        }
    }
}
