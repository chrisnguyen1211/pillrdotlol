import AppKit
import LidEffortCore
import SwiftUI
import Combine

@MainActor
final class NotchWindowController {
    let model = NotchViewModel()

    init() {
        model.onTooltipEchoEnded = { [weak self] in self?.tooltipEchoEnded() }
    }
    var displayPreference: DisplayPreference = .followActiveWindow

    /// The panel's content view, so a test can check what SwiftUI is and is not
    /// allowed to reach.
    var panelContentViewForTesting: NSView? { panel?.contentView }

    /// What AppKit settled on, for tests that need to see the panel move and
    /// fade rather than take our word for it.
    var panelFrameForTesting: CGRect? { panel?.frame }
    var panelAlphaForTesting: CGFloat { panel?.alphaValue ?? 0 }
    var doneToastRectForTesting: CGRect { doneToastRect }
    func tooltipRectForTesting(index: Int) -> CGRect? { tooltipRect(index: index) }
    func promptCardRectForTesting(_ prompt: PendingPrompt) -> CGRect { promptCardRect(prompt) }
    /// A panel-local point on ring `index`, where the pointer would rest to hover it.
    func cellPointForTesting(index: Int) -> CGPoint {
        let centre = model.slack + model.ringCenter(index: index) * model.sizeScale
        let spot = placement.rect(along: centre - 1, across: model.notchDrawnDepth / 2 - 1, length: 2, depth: 2)
        return CGPoint(x: spot.midX, y: spot.midY)
    }

    /// Hooked up by the app delegate; drives the menu's "Refresh now".
    var onRefresh: (() -> Void)?
    /// One "Sign in to …" item per provider that needs a browser session.
    var signInItems: [(title: String, action: () -> Void)] = []
    /// Driven by the notch's own chrome.
    var onToggleKeepOpen: (() -> Void)?
    /// Refetch a single provider, asked for by clicking its ring.
    var onRefreshProvider: ((String) async -> Void)?
    /// Open the settings window, asked for by clicking the handle.
    var onOpenSettings: (() -> Void)?
    /// What a ring's own right-click menu can do — see `AgentMenuActions`.
    var agentMenuActions = AgentMenuActions()
    /// An ⌥-drag on the pill settled at a new `model.alongOffset`. The
    /// controller only holds the live value; persisting it per edge is
    /// Preferences' job, the same division `apply(edge:)` already keeps.
    var onReposition: ((CGFloat) -> Void)?
    /// A move settled on a new edge. The fleet owns writing that to
    /// preferences, for the same reason it owns `onReposition`.
    var onMoveToEdge: ((NotchEdge) -> Void)?

    private var panel: NotchPanel?
    private var hostingView: NotchHostingView<NotchRootView>?

    /// The display this notch belongs to. Nil follows the menu-bar screen,
    /// which is what a single-controller setup did before the fleet existed —
    /// so leaving it unset changes nothing.
    var assignedScreen: NSScreen?

    /// Someone is using the notch right now — a card under the pointer, or a
    /// reply hanging from it — so it is not to be moved to another display.
    var isInUse: Bool {
        model.hoveredIndex != nil || ReplyPanelController.shared.isOpen
    }
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitors: [Any] = []
    private var clearHoverWork: DispatchWorkItem?
    private var clockTimer: Timer?
    private var cursorTimer: Timer?

    /// Hover in is quick; hover out waits, because the pointer has to cross the
    /// gap between the notch and the card without the card vanishing under it.
    private let hoverGrace: TimeInterval = 0.25
    /// Longer than the hover grace: folding shut is a bigger movement than
    /// dismissing a tooltip, and doing it the instant the pointer strays feels
    /// twitchy rather than responsive.
    private let foldGrace: TimeInterval = 0.45
    private var foldWork: DispatchWorkItem?
    /// Folds the notch again after a peek, when nothing else is holding it open.
    private var peekWork: DispatchWorkItem?
    /// The session a peek is currently offering, and how long the offer lasts.
    ///
    /// A click on the open notch normally pins it or refetches a ring; while
    /// this is set and unexpired it jumps to the session instead. The expiry is
    /// what keeps the two apart — without it, the *next* click on the notch,
    /// minutes later and about something else, would still be raising a
    /// terminal window.
    private var pendingFocus: (pid: pid_t, until: Date)?
    /// When the current peek's five seconds are up.
    ///
    /// The hover fold has to be told to leave it alone until then. Without
    /// this the cursor poll — which runs every 0.3s and asks "is the pointer on
    /// the notch?", to which the answer during a peek is almost always no —
    /// scheduled a fold immediately, and the notch opened and shut inside a
    /// second. A peek is not the pointer arriving, so the pointer leaving is
    /// not what should end it.
    private var peekUntil: Date?
    /// The standing visibility choice, so a peek never overrides Hidden.
    private var visibility: NotchVisibility = .onHover
    /// Whether a full-screen app is in front, as last looked up. Asked on
    /// the slow poll and on Space changes, never per mouse move: the lookup
    /// walks the window list, and on every move it took a quarter of the
    /// main thread.
    private var fullScreenNow = false
    /// Whether we have pushed the pointing hand onto the cursor stack.
    private var isPointing = false

    /// Determines whether a full-screen application window is active on this notch's display.
    /// Default implementation queries WindowServer and NSWorkspace; overridable for testing.
    lazy var isFullScreenActive: () -> Bool = { [weak self] in
        FullScreenDetector.isFullScreenAppFrontmost(on: self?.currentScreen())
    }

    /// When a full-screen app is active on the current space, auto-folds the notch.
    /// When returning to a desktop space with `isAlwaysOn`, restores the unfolded state.
    func handleActiveSpaceOrAppChange() {
        let fullScreen = isFullScreenActive()
        fullScreenNow = fullScreen
        // A prompt can wait out a full-screen app as a sound, if asked to:
        // no card comes up under a pointer that is busy in a game.
        let hold = fullScreen && !model.promptCardOverFullScreen
        if model.promptCardHeldForFullScreen != hold {
            model.promptCardHeldForFullScreen = hold
            updateInteractiveRects()
        }
        if fullScreen {
            if let panel {
                let local = localCursor(in: panel.frame)
                let overTooltip = model.hoveredIndex
                    .flatMap(tooltipRect(index:))
                    .map { model.isExpanded && $0.contains(local) } ?? false
                if liveRect.contains(local) || overTooltip {
                    return
                }
            }
            foldForFullScreen()
        } else if model.isAlwaysOn && !model.isExpanded {
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = true
            }
            updateInteractiveRects()
        }
    }

    /// Folds the notch now, peek or not — to make way for the reply field,
    /// which takes the tooltip's place beside the pill.
    func foldForReply() {
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        foldWork?.cancel()
        foldWork = nil
        model.isPinned = false
        guard model.isExpanded else { return }
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = false
            model.hoveredIndex = nil
        }
        setPointing(false)
        updateInteractiveRects()
    }

    /// Immediately folds the notch and clears pending hover timers when a full-screen app takes focus.
    func foldForFullScreen() {
        if let peekUntil, peekUntil > Date() { return }
        if model.holdsForPrompt { return }
        foldWork?.cancel()
        foldWork = nil
        model.isPinned = false
        guard model.isExpanded else { return }
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = false
            model.hoveredIndex = nil
        }
        setPointing(false)
        updateInteractiveRects()
    }

    func show() {
        relocate()
        startWatchingCursor()
        startClock()

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.relocate() }
        }
        .store(in: &cancellables)

        // A session row that can be opened asks for the pointing hand from
        // inside SwiftUI, a moment after the pointer arrives.
        pointer.$hands
            .removeDuplicates()
            .sink { [weak self] hands in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setPointing(self.basePointing || !hands.isEmpty)
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.activeSpaceDidChangeNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.handleActiveSpaceOrAppChange() }
        }
        .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.handleActiveSpaceOrAppChange() }
        }
        .store(in: &cancellables)

        model.$hoveredIndex
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        model.$activeResetAlert
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateInteractiveRects() }
            }
            .store(in: &cancellables)

        // A model can gain speed rows without changing the cell count. Read
        // after Published's willSet so sizing sees the new card contents too.
        model.$snapshots
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relocate() }
            .store(in: &cancellables)

        // No `receive(on:)`: the appearance has to be on the window before the
        // next draw, or the frame's hexes and the glass would be resolved
        // against the appearance the panel is about to stop having.
        Publishers.CombineLatest(model.$surfaceStyle.removeDuplicates(), model.$interfaceMode.removeDuplicates())
            .sink { [weak self] style, mode in
                MainActor.assumeIsolated { self?.applyPanelAppearance(style, mode: mode) }
            }
            .store(in: &cancellables)

        // Reduce transparency resolves the glass style to the solid one, so
        // turning it on or off in System Settings changes what the panel's
        // appearance has to be. Nothing else republishes that: the style the
        // model holds has not changed.
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyPanelAppearance(self.model.surfaceStyle, mode: self.model.interfaceMode)
            }
        }
        .store(in: &cancellables)
    }

    private func applyPanelAppearance(_ style: NotchSurfaceStyle, mode: InterfaceMode?) {
        panel?.appearance = style.panelAppearance(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            mode: mode
        )
    }

    func stop() {
        setPointing(false)
        peekUntil = nil
        peekWork?.cancel()
        foldWork?.cancel()
        cursorTimer?.invalidate()
        cursorTimer = nil
        clockTimer?.invalidate()
        mouseMonitors.forEach(NSEvent.removeMonitor)
        mouseMonitors.removeAll()
        cancellables.removeAll()
    }

    // MARK: - Placement

    /// The screen this notch lives on: its assigned display while that display
    /// is still connected, the menu-bar screen otherwise — so unplugging the
    /// display never strands the panel on a screen that no longer exists.
    /// Assigned first — the fleet has already picked this display for this
    /// controller, which is the whole point of there being more than one
    /// controller. `displayPreference` only comes into play once nothing has
    /// been assigned, which is the single-controller case `.mainDisplay`
    /// scope leaves it in.
    func currentScreen() -> NSScreen? {
        if let assigned = assignedScreen,
           NSScreen.screens.contains(where: { $0 === assigned }) {
            return assigned
        }
        return NotchGeometry.preferredScreen(from: NSScreen.screens, preference: displayPreference)
    }

    func relocate(cellCount: Int? = nil) {
        guard let screen = currentScreen() else { return }
        model.adopt(screen: screen)
        let size = model.panelSize(cellCount: cellCount ?? model.snapshots.count)
        let frame = NotchGeometry.panelFrame(
            for: screen, panelSize: size, edge: model.edge,
            alongOffset: model.alongOffset, slack: model.slack,
            trailingExtent: model.trailingExtent
        )

        if let panel {
            panel.setFrame(frame, display: true)
        } else {
            let panel = NotchPanel(contentRect: frame)
            panel.appearance = model.surfaceStyle.panelAppearance(
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                mode: model.interfaceMode
            )
            let hosting = NotchHostingView(rootView: NotchRootView(model: model, pointer: pointer))
            panel.contextMenuProvider = { [weak self] point in self?.contextMenu(at: point) }
            panel.onClick = { [weak self] point in self?.handleClick(at: point) }
            panel.acceptsKeyboard = !model.prompts.isEmpty
            watchKeyboard(panel)
            panel.onDrag = { [weak self] dx, dy in self?.dragged(dx: dx, dy: dy) }
            panel.onDragEnd = { [weak self] in
                guard let self else { return }
                self.onReposition?(self.model.alongOffset)
            }

            // The hosting view goes *inside* a plain container rather than
            // being the content view itself.
            //
            // As the content view, SwiftUI gets a say in the window's frame: it
            // reports the content's ideal size, and this view's root is a
            // `GeometryReader`, whose ideal size is 10x10. On the side edges
            // that never surfaced. Turned horizontal, AppKit started walking
            // the window down toward it — 522pt of height to 266, to 10, to
            // zero — until nothing was drawn at all and the constraint pass
            // gave up and threw, taking the app with it.
            //
            // A container removes the channel instead of arguing with it. The
            // panel's size comes from `NotchGeometry` and from nowhere else,
            // which is what every hit region in this file already assumes.
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            if !Runtime.isUnderTest { panel.orderFrontRegardless() }
            self.panel = panel
            self.hostingView = hosting
        }
        // Use the actual panel origin: near a corner its transparent padding
        // can extend offscreen, while the tooltip itself must stay visible.
        if let panel {
            let visible = panel.frame.intersection(screen.frame)
            let range: ClosedRange<CGFloat> = model.edge.isVertical
                ? (panel.frame.maxY - visible.maxY)...(panel.frame.maxY - visible.minY)
                : (visible.minX - panel.frame.minX)...(visible.maxX - panel.frame.minX)
            if model.visibleAlongRange != range { model.visibleAlongRange = range }
        }

        // The frame AppKit actually gave us, which is what the flush right-hand
        // edge depends on.
        if let panel {
            Log.usage.debug("panel \(NSStringFromRect(panel.frame), privacy: .public) on screen \(NSStringFromRect(screen.frame), privacy: .public)")
        }
        updateInteractiveRects()
    }

    /// Feeds a raw pointer delta from an ⌥-drag into `model.alongOffset` and
    /// re-places the panel at once, so the pill tracks the cursor rather than
    /// catching up once the button lifts.
    ///
    /// Both deltas are used as `NSEvent` reports them, unflipped: `deltaY`
    /// positive is the pointer moving *down* the screen, `deltaX` positive is
    /// it moving *right*. `NotchGeometry` is written to match — it subtracts
    /// the offset from a vertical edge's y (which AppKit grows *up*, so
    /// subtracting more moves the pill down) and adds it to a horizontal
    /// edge's x — so no sign flip belongs here; adding one would make the
    /// pill run away from the cursor instead of following it.
    private func dragged(dx: CGFloat, dy: CGFloat) {
        model.alongOffset += model.edge.isVertical ? dy : dx
        relocate()
        // Past the end of the edge the pill stops but the pointer goes on:
        // kept to where the pill actually stands, so dragging back moves it
        // at once instead of first unwinding the distance it did not travel.
        if let panel, let screen = currentScreen() {
            let settled = Self.alongOffset(of: panel.frame, on: screen.frame, edge: model.edge)
            if abs(settled - model.alongOffset) > 0.5 { model.alongOffset = settled }
        }
    }

    /// The offset a panel frame stands at — the inverse of
    /// `NotchGeometry.panelFrame`'s placement along the edge.
    static func alongOffset(of frame: CGRect, on screen: CGRect, edge: NotchEdge) -> CGFloat {
        switch edge {
        case .left, .right: return screen.midY - frame.height / 2 - frame.minY
        case .top, .bottom: return frame.minX - (screen.midX - frame.width / 2)
        }
    }

    // MARK: - Hit regions

    /// The panel's real size, which AppKit may have rounded up from the one we
    /// asked for — and which the flush edge depends on.
    private var placement: NotchPlacement {
        NotchPlacement(edge: model.edge, panelSize: panel?.frame.size ?? model.panelSize)
    }

    /// The notch itself, in panel coordinates with a top-left origin.
    private var notchRect: CGRect {
        placement.rect(
            along: model.slack,
            across: 0,
            length: model.shapeLength * model.sizeScale,
            depth: model.notchDepth * model.sizeScale
        )
    }

    /// What wakes the folded notch. Larger than the pill it surrounds, and
    /// exactly the hardware notch when it is joined to one — see
    /// `NotchViewModel.wakeLength` for both halves of that.
    private var pillRect: CGRect {
        placement.rect(
            along: model.slack + (model.shapeLength * model.sizeScale - model.wakeLength) / 2,
            across: 0,
            length: model.wakeLength,
            depth: model.wakeDepth
        )
    }

    /// The handle's bounding box, for deciding whether the panel takes events
    /// at all. Whether a point is actually *on* the handle is a finer question
    /// than a box can answer — see `isOverHandle`.
    private var handleRect: CGRect {
        let side = NotchLayout.orbHotZone
        let boxes = (model.orbHandlePoints + model.moveHandlePoints).map { point -> CGRect in
            let centre = placement.point(along: model.slack + point.x * model.sizeScale,
                                         across: point.y * model.sizeScale)
            return CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                          width: side, height: side)
        }
        return boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
    }

    /// Whether the pointer is on the handle itself rather than merely inside
    /// the box that contains it.
    private func isOverHandle(_ local: CGPoint) -> Bool {
        // Back into the notch's own measurements, which is what `isOnOrbHandle`
        // is written in — the orb scales with the notch, so its hit test has to
        // be asked in the same space the shape was drawn in.
        model.isOnOrbHandle(
            along: (placement.along(of: local) - model.slack) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    /// Whether the pointer is on the move handle, asked in the same notch-own
    /// measurements `isOverHandle` uses.
    private func isOverMoveHandle(_ local: CGPoint) -> Bool {
        model.isOnMoveHandle(
            along: (placement.along(of: local) - model.slack) / model.sizeScale,
            across: placement.across(of: local) / model.sizeScale
        )
    }

    /// The only region that takes the mouse. Everything else in the panel is a
    /// hole — which matters far more folded than open, since the point of
    /// folding away is to stop being in the way.
    private var liveRect: CGRect {
        guard model.isExpanded else { return pillRect }
        // The orb hangs below the shape, so the live region is both together.
        return notchRect.union(handleRect)
    }

    /// The card, its tail, and the gap between the tail and the notch — so
    /// sliding the pointer off the notch and onto the card never leaves it.
    private func tooltipRect(index: Int) -> CGRect? {
        guard model.snapshots.indices.contains(index) else { return nil }
        let snapshot = model.snapshots[index]
        let cardHeight = NotchLayout.cardHeight(
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
            promptHeight: model.promptHeight(for: snapshot),
            costRows: model.costRows(for: snapshot),
            keyGroupBody: model.keyGroupBody(for: snapshot)
        )
        // Across the stack the region is the card, its tail, and the gap the
        // pointer has to cross. Along it, the card's own extent.
        let scale = model.cardScale
        let cardAcross = (model.edge.isVertical ? NotchLayout.cardWidth : cardHeight) * scale
        let cardAlong = (model.edge.isVertical ? cardHeight : NotchLayout.cardWidth) * scale
        let centre = model.tooltipAlong(index: index, length: cardAlong)
        return placement.rect(
            along: centre - cardAlong / 2,
            // The card is drawn at its own scale, not the notch's, and it
            // begins where the drawn notch ends.
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength * scale + cardAcross
        )
    }

    private func resetCardRect(event: UsageResetEvent) -> CGRect? {
        alertCardRect(index: model.resetAlertIndex(for: event) ?? 0, height: UsageResetCard.cardHeight(for: event))
    }

    /// Where the reset and effort cards sit: the same place, by ring `index`.
    private func alertCardRect(index: Int, height: CGFloat) -> CGRect {
        let scale = model.cardScale
        let cardAcross = (model.edge.isVertical ? NotchLayout.cardWidth : height) * scale
        let cardAlong = (model.edge.isVertical ? height : NotchLayout.cardWidth) * scale
        let centre = model.tooltipAlong(index: index, length: cardAlong)
        return placement.rect(
            along: centre - cardAlong / 2,
            across: model.notchDrawnDepth,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength * scale + cardAcross
        )
    }

    private func updateInteractiveRects() {
        var rects = [liveRect]
        if let prompt = model.visiblePromptCard {
            rects.append(promptCardRect(prompt))
        } else if !model.isExpanded, model.activeDoneToast != nil, model.currentPrompt == nil {
            rects.append(doneToastRect)
            if let toast = model.activeDoneToast, DoneToastView.canReply(toast) { rects.append(doneToastReplyRect) }
        }
        // The effort card is the gesture's answer and goes over a reset
        // card; the reset card is only clickable while it is the one shown.
        if model.isExpanded, model.activeEffortAlert == nil, let event = model.activeResetAlert,
           let card = resetCardRect(event: event) {
            rects.append(card)
        }
        if model.isExpanded, let index = model.hoveredIndex, let card = tooltipRect(index: index) {
            rects.append(card)
        }
        hostingView?.interactiveRects = rects
        if let panel {
            panel.ignoresMouseEvents = !rects.contains { $0.contains(localCursor(in: panel.frame)) }
        }
    }

    // MARK: - Cursor tracking

    /// A global monitor catches the outside-to-inside crossing while the panel
    /// is still ignoring events; a local one catches the way back out.
    ///
    /// A slow poll backs both of them up, because a cursor that never moves
    /// produces no events at all — so a notch that appears, resizes or is
    /// re-anchored underneath a parked pointer would otherwise sit there with
    /// stale hover state until the user jogged the mouse.
    private func startWatchingCursor() {
        let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleActiveSpaceOrAppChange()
                self?.cursorMoved()
                self?.updateGlassSightline()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        cursorTimer = poll

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    /// Glass over the desktop renders grey; this tells the chrome when it is
    /// over the desktop — see `GlassSightline`. On the slow poll, like the
    /// full-screen check: nothing announces another app's window moving in
    /// under the pill or out from under it. Only while there is glass to ask
    /// about, so the solid style pays nothing.
    private func updateGlassSightline() {
        // The wallpaper's tone is for glass only: a solid card keeps the
        // Mac's appearance.
        if model.cardTone != nil, model.surfaceStyle.effective != .glass
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            model.cardTone = nil
        }
        guard let panel, !Runtime.isUnderTest, panel.isVisible,
              model.surfaceStyle.effective == .glass,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        else { return }
        // `notchRect` is top-left in the panel; the window list is top-left
        // on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? panel.frame.maxY
        let rect = notchRect.offsetBy(dx: panel.frame.minX, dy: primaryHeight - panel.frame.maxY)
        let sees = GlassSightline.glassSees(rect, below: panel.windowNumber)
        if model.glassSeesBehind != sees {
            Log.usage.debug("pill glass \(sees ? "sees a window" : "over the desktop", privacy: .public)")
            model.glassSeesBehind = sees
        }
        // The card that is up, if one is; with none, the last answer stands
        // until the next one appears and is looked at.
        if let card = visibleCardRect {
            let global = card.offsetBy(dx: panel.frame.minX, dy: primaryHeight - panel.frame.maxY)
            let cardSees = GlassSightline.glassSees(global, below: panel.windowNumber)
            if model.cardGlassSeesBehind != cardSees {
                Log.usage.debug("card glass \(cardSees ? "sees a window" : "over the desktop", privacy: .public)")
                model.cardGlassSeesBehind = cardSees
            }
            // Over the desktop, the card wears the pill's glass in the
            // wallpaper's own tone.
            let tone = cardSees ? nil : WallpaperTone.tone(under: global, frost: Double(model.pillFrost))
            if model.cardTone != tone { model.cardTone = tone }
        }
    }

    /// The card on screen, in panel coordinates — the same precedence the
    /// root view draws them in.
    private var visibleCardRect: CGRect? {
        if let prompt = model.visiblePromptCard { return promptCardRect(prompt) }
        if !model.isExpanded, model.activeDoneToast != nil, model.currentPrompt == nil { return doneToastRect }
        guard model.isExpanded else { return nil }
        if model.hoveredIndex == nil {
            if let event = model.activeEffortAlert {
                return alertCardRect(index: model.effortAlertIndex() ?? 0, height: EffortChangeCard.cardHeight(for: event))
            }
            if let event = model.activeResetAlert { return resetCardRect(event: event) }
        }
        if let index = model.hoveredIndex { return tooltipRect(index: index) }
        return nil
    }

    private func localCursor(in frame: CGRect) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    private func cursorMoved() {
        guard let panel else { return }
        // Every mouse move on the whole screen lands here. Folded, with
        // nothing hovered and the pointer nowhere near the panel, there is
        // nothing to update — and working it out cost a layout pass a move.
        if !model.isExpanded, model.hoveredIndex == nil, pointer.location == nil, !isPointing,
           !panel.frame.contains(NSEvent.mouseLocation) {
            return
        }
        pointerMoved(to: localCursor(in: panel.frame))
    }

    func pointerMovedForTesting(toLocal local: CGPoint) { pointerMoved(to: local) }

    /// The pointer, handed to the hover effects the panel draws.
    let pointer = NotchPointer()
    /// Whether the controller's own targets — rings, handles — want the
    /// pointing hand; views inside add theirs through `pointer.hands`.
    private var basePointing = false

    private func pointerMoved(to local: CGPoint) {
        defer {
            // After the rects are settled for this position, so an opening
            // notch counts as drawn under the pointer on this very move.
            pointer.move(to: (hostingView?.interactiveRects ?? []).contains { $0.contains(local) } ? local : nil)
        }
        let overTooltip = model.hoveredIndex
            .flatMap(tooltipRect(index:))
            .map { model.isExpanded && $0.contains(local) } ?? false
        setExpanded(liveRect.contains(local) || overTooltip || model.holdsForPrompt,
                    ignoreAlwaysOn: fullScreenNow)

        var target: Int?
        if model.isExpanded, notchRect.contains(local) {
            target = cellIndex(along: placement.along(of: local))
        } else if model.isExpanded, let current = model.hoveredIndex,
                  let card = tooltipRect(index: current),
                  card.contains(local) {
            target = current
        }

        let overHandle = model.isExpanded && isOverHandle(local)
        if model.isHoveringSettings != overHandle {
            model.isHoveringSettings = overHandle
        }
        let overMove = model.isExpanded && isOverMoveHandle(local)
        if model.isHoveringMove != overMove {
            model.isHoveringMove = overMove
        }
        basePointing = Self.wantsPointingHand(isExpanded: model.isExpanded, cellIndex: target)
            || overHandle || overMove
        setPointing(basePointing || !pointer.hands.isEmpty)
        // With a question waiting, the pointer wandering off is not the end
        // of it: the tooltip goes back to the prompt rather than away. Another
        // ring still shows its own card while the pointer is on it.
        if target == nil, model.holdsForPrompt {
            target = model.heldTooltipIndex
        }

        if let target {
            clearHoverWork?.cancel()
            clearHoverWork = nil
            if model.hoveredIndex != target {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    model.hoveredIndex = target
                }
            }
        } else if model.hoveredIndex != nil, clearHoverWork == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearHoverWork = nil
                    withAnimation(.easeOut(duration: 0.18)) { self.model.hoveredIndex = nil }
                }
            }
            clearHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverGrace, execute: work)
        }

        updateInteractiveRects()
    }

    /// Opens on contact, folds shut after a pause — unless it has been pinned
    /// open, in which case the pointer is not what decides.
    private func setExpanded(_ wanted: Bool, ignoreAlwaysOn: Bool = false) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            return
        }

        // A peek holds the notch open for its own duration; only after that
        // does the pointer get a say again.
        if let peekUntil, peekUntil > Date() { return }
        let holdsOpen = ignoreAlwaysOn ? model.isPinned : model.staysOpen
        guard model.isExpanded, !holdsOpen, !model.holdsForPrompt, foldWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldWork = nil
                let stillHoldsOpen = ignoreAlwaysOn ? self.model.isPinned : self.model.staysOpen
                guard !stillHoldsOpen, !self.model.holdsForPrompt else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + foldGrace, execute: work)
    }

    /// The rings are buttons, so they should say so.
    static func wantsPointingHand(isExpanded: Bool, cellIndex: Int?) -> Bool {
        isExpanded && cellIndex != nil
    }

    /// Pushed and popped rather than `set`, so leaving restores whatever cursor
    /// the app underneath had chosen. Setting `.arrow` on the way out would
    /// stamp an arrow over someone else's text caret.
    private func setPointing(_ wanted: Bool) {
        guard wanted != isPointing else { return }
        isPointing = wanted
        if wanted {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    /// A click on a ring refetches that provider; a click anywhere else on the
    /// open notch pins it. The ring is the more specific target, so it wins.
    func handleClick(at locationInWindow: CGPoint) {
        guard let panel else {
            setExpanded(true)
            return
        }
        // Use the event position even if the pointer has moved since the click.
        let local = CGPoint(x: locationInWindow.x, y: panel.frame.height - locationInWindow.y)

        // Cards that hold controls take their own clicks, before anything
        // else gets a say: an answer to a question must never be read as
        // "open the session" or "pin the notch". The tooltip check used to
        // come after the pending-focus one, and with a session waiting the
        // first option clicked in the tooltip folded the notch and jumped
        // to the terminal.
        if let prompt = model.visiblePromptCard, promptCardRect(prompt).contains(local) {
            return
        }
        if model.isExpanded, let index = model.hoveredIndex,
           let card = tooltipRect(index: index), card.contains(local) {
            return
        }
        // A click on the done card opens the session it is about — the card
        // says "Click to open", and that is the whole of what it means. A
        // click elsewhere while it is up merely dismisses it; the pill's
        // own pending-focus answer below still stands for that.
        if let toast = model.activeDoneToast {
            // The round Reply button beside the card: write to the session.
            if !model.isExpanded, DoneToastView.canReply(toast), doneToastReplyRect.contains(local),
               let reply = model.onSessionAction {
                clearDoneToast()
                pendingFocus = nil
                reply(.reply(toast.session))
                return
            }
            let onCard = !model.isExpanded && doneToastRect.contains(local)
            Log.usage.notice("click with done card up: on card \(onCard, privacy: .public), pid \(toast.pid ?? -1, privacy: .public), at \(NSStringFromPoint(local), privacy: .public) in \(NSStringFromRect(self.doneToastRect), privacy: .public)")
            clearDoneToast()
            // Elsewhere, a click only puts the card away: opening the notch
            // must never turn into a jump to some terminal.
            if !onCard { pendingFocus = nil }
            if onCard {
                pendingFocus = nil
                // ⌥-click on the card: write to it instead of going to it.
                if NSEvent.modifierFlags.contains(.option), let reply = model.onSessionAction {
                    reply(.reply(toast.session))
                } else if let pid = toast.pid {
                    focusSession(pid)
                } else if let app = toast.app {
                    Self.bringForward(bundleID: app)
                }
                return
            }
        }

        // The handle sits inside the notch, so it has to be tested before the
        // cells — otherwise the cell band nearest the foot of the stack swallows
        // it and clicking the gear refetches a provider instead.
        // The move handle is tested before the settings orb and the cells for
        // the same reason the orb is: it sits over the stack, and whichever
        // band is nearest would otherwise swallow the press.
        if model.isExpanded, isOverMoveHandle(local) {
            // One click, one side on: no carrying. The move itself is the
            // notch running round the bezel — see `apply(edge:)`.
            model.moveSpins += 1
            onMoveToEdge?(model.edge.nextSide)
            return
        }
        if model.isExpanded, isOverHandle(local) {
            // The same turn the SwiftUI tap gives it, so the gear responds
            // however the click reached it — this path and the tap gesture
            // are two routes to one action.
            model.settingsSpins += 1
            onOpenSettings?()
            return
        }
        // A peek is a question — "this one just finished, do you want it?" —
        // and the click that follows is the answer. It outranks pinning and
        // refetching for as long as the offer stands, and for no longer.
        //
        // Tested before the folded case below, not after: the grace period
        // outlives the peek by a couple of seconds precisely so that a hand
        // that arrived late still lands on the session, and answering it by
        // merely re-opening the notch would waste that click.
        if takePendingFocus() {
            peekWork?.cancel()
            peekWork = nil
            peekUntil = nil
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
            setPointing(false)
            updateInteractiveRects()
            return
        }
        // Clicks on the tooltip card belong to whatever is drawn there — the
        // session rows take their own taps — and must not fall through to the
        // cell refetch or the pin toggle underneath.
        if model.isExpanded, let index = model.hoveredIndex,
           let card = tooltipRect(index: index), card.contains(local) {
            return
        }
        guard model.isExpanded else {
            // Opens it, the same as the pointer arriving would — it must not
            // also pin it. The pill's hot zone is deliberately generous, since
            // it is a small target on a screen edge, so a click aimed at
            // something else nearby can land here without the notch ever
            // having been seen open. Pinning is what a click on a notch that
            // is *already* open does; folding it back in later is exactly
            // the ordinary hover behaviour, which a plain `setExpanded` leaves
            // intact.
            setExpanded(true)
            return
        }
        if notchRect.contains(local),
           let index = cellIndex(along: placement.along(of: local)),
           model.snapshots.indices.contains(index) {
            if let onRefreshProvider {
                let snapshot = model.snapshots[index]
                Task { await model.refresh(snapshot, using: onRefreshProvider) }
            }
            return
        }
        togglePinned()
    }

    /// Move the notch to another screen edge.
    ///
    /// It goes out where it was, crosses while there is nothing to see, and
    /// then **opens** where it now is — the same unfold hovering uses, so a
    /// move ends the way reaching for it does rather than with a bar appearing
    /// at full size.
    ///
    /// Changing the placement moves the panel, turns the shape on its side and
    /// relays the whole stack, all in one frame. Done in view that is a jump no
    /// animation can smooth over, and animating a panel across a corner looks
    /// like a bug rather than a choice — hence the crossing rather than a
    /// slide.
    /// A new size choice: set it, then rebuild the panel around it.
    ///
    /// Set-then-relocate rather than a subscription on `model.$sizeScale`,
    /// because `@Published` fires in `willSet` — a sink here would recompute
    /// the panel from the size that is being replaced. `apply(edge:)` is the
    /// same shape for the same reason.
    /// Recomputes the click-through region at once. The handle's hit points
    /// vanish with it, but the window only learns which of its pixels take the
    /// mouse when those regions are rebuilt; without this the spot where the
    /// handle was would keep catching clicks until something else moved.
    func apply(showsMoveHandle: Bool) {
        guard model.showsMoveHandle != showsMoveHandle else { return }
        model.showsMoveHandle = showsMoveHandle
        updateInteractiveRects()
    }

    func apply(alongOffset: CGFloat) {
        guard model.alongOffset != alongOffset else { return }
        model.alongOffset = alongOffset
        relocate()
    }

    /// The cards' size, apart from the pill's. The panel has to grow or
    /// shrink with them, so it is re-laid out — coalesced, as a drag is.
    func apply(cardScale: CGFloat) {
        guard model.cardScale != cardScale else { return }
        model.cardScale = cardScale
        coalesceRelocate()
        updateInteractiveRects()
    }

    func apply(scale: CGFloat) {
        guard model.sizeScale != scale else { return }

        // A drag arrives as a stream of tiny deltas; a preset, or a switch
        // between the two controls, arrives as one large one.
        let isDrag = abs(scale - model.sizeScale) < Self.steppedScaleDelta

        // The drawn shape follows every tick — that part is a redraw and it is
        // cheap. Re-laying the *window* out is not: `relocate` recomputes the
        // panel size through `maxCardHeight` and the `sessionCap` search, then
        // asks the compositor to resize a full-height window. Sixty of those a
        // second is what makes a drag feel like it is pulling something heavy.
        model.sizeScale = scale
        if isDrag {
            coalesceRelocate()
        } else {
            pendingRelocate?.cancel()
            pendingRelocate = nil
            relocate()
            updateInteractiveRects()
        }
    }

    /// Above this, a size change was *chosen* rather than dragged. The
    /// smallest gap between two presets is 0.2 and a drag tick is a fraction
    /// of a percent, so there is a wide margin either way.
    private static let steppedScaleDelta: CGFloat = 0.05

    /// The window is re-laid out at most this often while a drag is in
    /// flight. The panel is larger than the notch by the whole tooltip slack,
    /// so it can be a tenth of a second out of date without anything showing.
    private static let relocateInterval: TimeInterval = 0.1

    /// Resize the window on a budget, and always once the drag has stopped.
    private func coalesceRelocate() {
        let now = Date()
        if now.timeIntervalSince(lastRelocate) >= Self.relocateInterval {
            lastRelocate = now
            relocate()
            return
        }
        // Too soon. Replace any pending catch-up with one scheduled from now,
        // so a drag that stops mid-interval still ends up correctly sized.
        pendingRelocate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastRelocate = Date()
            self.relocate()
            self.updateInteractiveRects()
        }
        pendingRelocate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.relocateInterval,
                                      execute: work)
    }

    // MARK: - Moving

    private var lastRelocate = Date.distantPast
    private var pendingRelocate: DispatchWorkItem?
    private var edgeFlow: EdgeFlowOverlay?
    /// The whole journey round the bezel. Long enough to be followed, short
    /// enough that a second click is not waiting on the first.
    private static let edgeFlowDuration: TimeInterval = 0.8

    func apply(edge: NotchEdge) {
        guard model.edge != edge else { return }
        guard let panel else {   // before there is anything on screen to fade
            model.edge = edge
            relocate()
            return
        }

        let wasOpen = model.isExpanded
        model.hoveredIndex = nil
        setPointing(false)

        // Clicking through the picker starts a move before the last one has
        // landed, and a stale completion would drop the notch on an edge the
        // user has already moved on from.
        edgeChange += 1
        let change = edgeChange

        // The crossing is the notch itself running along the bezel and round
        // the corner, a drop of its own material: it leaves where it was and
        // arrives where it now is, and the eye can follow it there. The
        // panel is hidden for the length of it; the drop is what is on
        // screen. Reduce Motion, and the tests, get the plain crossfade.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !Runtime.isUnderTest, !reduceMotion, let screen = currentScreen() {
            let from = model.edge
            let start = pillCentreOnScreen(of: screen, panel: panel)
            // The drop is always the pill's own size — not the hardware
            // notch's, which the top edge rests as. Leaving from the top it
            // ran as a slab the width of the notch; it is the pill that
            // travels, whatever it was joined to.
            let depth = NotchLayout.pillWidth * model.sizeScale
            let length = NotchLayout.pillHeight * model.sizeScale
            panel.alphaValue = 0
            land(on: edge)
            let end = pillCentreOnScreen(of: screen, panel: panel)
            let points = EdgeFlowRoute.points(from: from, at: start, to: edge, at: end,
                                              size: screen.frame.size, depth: depth)
            let glassy = model.surfaceStyle.effective == .glass
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            let flow = EdgeFlowOverlay()
            edgeFlow = flow
            flow.run(on: screen, points: points, depth: depth,
                     pillFraction: min(1, length / max(1, EdgeFlowRoute.length(of: points))),
                     duration: Self.edgeFlowDuration, glassy: glassy) { [weak self] in
                guard let self, change == self.edgeChange, let panel = self.panel else { return }
                // The drop has gathered itself into the pill's shape over
                // the pill's place and is fading; the pill fades in under
                // it over the same time, and the two are never both absent.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = EdgeFlowView.handoff
                    panel.animator().alphaValue = 1
                } completionHandler: {
                    MainActor.assumeIsolated {
                        guard change == self.edgeChange else { return }
                        self.edgeFlow = nil
                    }
                }
                self.arrive(open: wasOpen, change: change)
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.edgeCrossfade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, change == self.edgeChange else { return }
                self.land(on: edge)
                panel.alphaValue = 1
                self.arrive(open: wasOpen, change: change)
            }
        }
    }

    /// Land folded, and at full strength: the opening *is* the animation,
    /// and fading in underneath it would be two at once.
    private func land(on edge: NotchEdge) {
        model.edge = edge
        model.isExpanded = false
        relocate()
        updateInteractiveRects()
    }

    /// A beat, then open — and stay open a moment, so the notch is seen
    /// where it landed before it folds to its pill. A peek rather than a
    /// plain open: the pointer is not there to keep it open or let it go,
    /// so it schedules its own fold, and stays if the hand arrives.
    ///
    /// The beat is not decoration: setting it shut and open again inside
    /// one turn lets SwiftUI coalesce the pair, and the notch arrives at
    /// full size having animated nothing.
    private func arrive(open: Bool, change: Int) {
        // Only a notch that was open — the one whose handle was clicked.
        // A folded notch moved from Settings arrives folded, uninvited.
        guard open else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalBeat) {
            MainActor.assumeIsolated {
                guard change == self.edgeChange else { return }
                self.peek(for: Self.arrivalHold, focusing: nil)
            }
        }
    }

    /// How long the notch shows itself on the new side before folding.
    private static let arrivalHold: TimeInterval = 1.0

    /// The folded pill's centre in the screen's own top-left-origin space,
    /// which is what the flow's route is drawn in.
    private func pillCentreOnScreen(of screen: NSScreen, panel: NSPanel) -> CGPoint {
        let local = placement.point(along: model.slack + model.shapeLength * model.sizeScale / 2,
                                    across: model.restingDepth * model.sizeScale / 2)
        let screenX = panel.frame.minX + local.x
        let screenY = panel.frame.maxY - local.y
        return CGPoint(x: screenX - screen.frame.minX, y: screen.frame.maxY - screenY)
    }

    func apply(displayPreference: DisplayPreference) {
        guard self.displayPreference != displayPreference else { return }
        self.displayPreference = displayPreference
        relocate()
    }

    /// Half the crossing, each way. Short: it is a settings change, not a
    /// flourish, and the notch should be back before you have looked up.
    private static let edgeCrossfade: TimeInterval = 0.16
    /// The pause between landing and opening.
    private static let arrivalBeat: TimeInterval = 0.05
    private var edgeChange = 0

    func apply(_ visibility: NotchVisibility) {
        self.visibility = visibility
        // A standing choice outranks a peek that happens to be in flight.
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        switch visibility {
        case .alwaysShow:
            if !Runtime.isUnderTest { panel?.orderFrontRegardless() }
            model.isAlwaysOn = true
            // Any pin made by hand is subsumed by the setting; leaving it set
            // would outlive a later switch back to hover.
            model.isPinned = false
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        case .onHover:
            if !Runtime.isUnderTest { panel?.orderFrontRegardless() }
            model.isAlwaysOn = false
            model.isPinned = false
            // Fold now rather than waiting for the pointer to leave: it may
            // already be somewhere else, in which case nothing would arrive to
            // close it and "on hover" would look exactly like "always show".
            withAnimation(NotchMotion.unfold) {
                model.isExpanded = false
                model.hoveredIndex = nil
            }
        case .hidden:
            model.isAlwaysOn = false
            model.isPinned = false
            model.isExpanded = false
            model.hoveredIndex = nil
            // Ordered out rather than made transparent. An invisible panel that
            // still takes the screen edge would keep swallowing the pointer.
            panel?.orderOut(nil)
        }
        setPointing(false)
        updateInteractiveRects()
    }

    // MARK: - Peeking

    /// Open the notch by itself for a moment, because something happened.
    ///
    /// Distinct from `setExpanded(true)`, which is the pointer arriving: this
    /// has no pointer to leave again, so it schedules its own close. The close
    /// checks the same two conditions the hover fold does — pinned open, or the
    /// pointer now resting on it — because a peek that arrives while you are
    /// already reading the notch must not yank it shut underneath you.
    ///
    /// `pid` is the agent's process, used only if the peek is clicked; nil
    /// leaves the click doing what it ordinarily does.
    /// Opens the notch on one ring's tooltip and keeps it there, for the
    /// tour's first step; nil lets it go.
    func holdTooltip(index: Int?, focus: TooltipTourFocus? = nil) {
        let wasHeld = model.tourHeldIndex != nil
        model.tourHeldIndex = index
        model.tourFocus = index == nil ? nil : focus
        guard let index else {
            // The peek that opened it runs for as long as the step might;
            // letting go ends it too, or the notch stayed open for minutes.
            if wasHeld { endPeek() }
            return
        }
        peek(for: 600, focusing: nil)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.hoveredIndex = index }
        updateInteractiveRects()
    }

    /// Ends a peek now rather than when it runs out, folding the notch unless
    /// the pointer is on it — for the tour, whose next step shows a card that
    /// only appears beside the folded pill.
    func endPeek() {
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        guard let panel, model.isExpanded, !model.staysOpen, !model.holdsForPrompt,
              !liveRect.contains(localCursor(in: panel.frame)) else { return }
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = false
            model.hoveredIndex = nil
        }
        updateInteractiveRects()
    }

    func peek(for duration: TimeInterval, focusing pid: pid_t?) {
        // Hidden is a standing choice that the notch is not to be on screen.
        // Something finishing is not grounds to overrule it — the chime still
        // sounds, which is the part that works with nothing visible.
        guard visibility != .hidden, let panel else {
            Log.usage.debug("peek skipped: notch hidden")
            return
        }
        Log.usage.debug("peek for \(duration, privacy: .public)s, pid \(pid ?? -1, privacy: .public)")

        if let pid {
            pendingFocus = (pid: pid, until: Date().addingTimeInterval(duration + Self.focusGrace))
        }
        peekUntil = Date().addingTimeInterval(duration)

        if !Runtime.isUnderTest { panel.orderFrontRegardless() }
        foldWork?.cancel()
        foldWork = nil
        peekWork?.cancel()
        withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        updateInteractiveRects()

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.peekWork = nil
                self.peekUntil = nil
                guard !self.model.staysOpen, !self.model.holdsForPrompt else { return }
                // Left open if the peek did its job and the pointer is already
                // there; the ordinary hover fold takes it from here.
                guard !self.liveRect.contains(self.localCursor(in: panel.frame)) else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                }
                self.setPointing(false)
                self.updateInteractiveRects()
                Log.usage.debug("peek folded")
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// The card raised for a lid that is still moving, so a settled change
    /// can be told from it: the change replaces it; a rest that changed
    /// nothing lets it go after a beat.
    private var liveEffortAlertID: UUID?

    /// The lid moving, live: hold the notch open on the effort card and let
    /// its bar follow. Nil when it has rested — the card stays a moment in
    /// case the rest changed nothing, and is replaced at once if it did.
    func showEffortPreview(_ position: Double?, level: EffortLevel, note: String? = nil, noteIsLive: Bool = false,
                           agent: String? = nil, aim: EffortAim? = nil) {
        guard visibility != .hidden, panel != nil else { return }
        if let position {
            model.effortPreview = position
            if model.activeEffortAlert == nil || model.activeEffortAlert?.id != liveEffortAlertID {
                // Before ⌘ is let go: what it will change, and how to apply it.
                let how = L10n.t("Let go of ⌘ to apply")
                let live = EffortChangeEvent(level: level, values: [], at: Date(),
                                             note: note.map { "\(how) · \($0)" } ?? how, noteIsLive: noteIsLive,
                                             agent: agent, aim: aim)
                liveEffortAlertID = live.id
                withAnimation(NotchMotion.contents) { model.activeEffortAlert = live }
            }
            // Re-armed on every reading, so the notch stays open exactly as
            // long as the lid is moving and a beat after.
            peek(for: 1.2, focusing: nil)
            return
        }

        model.effortPreview = nil
        guard let id = liveEffortAlertID else { return }
        liveEffortAlertID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.activeEffortAlert?.id == id else { return }
                withAnimation(.easeOut(duration: 0.18)) { self.model.activeEffortAlert = nil }
                self.updateInteractiveRects()
            }
        }
    }

    /// Open the notch for a moment and show what the lid just did.
    func showEffortAlert(_ event: EffortChangeEvent, duration: TimeInterval = 2.5) {
        guard visibility != .hidden, panel != nil else { return }
        model.activeEffortAlert = event
        peek(for: duration, focusing: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.activeEffortAlert == event {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.model.activeEffortAlert = nil
                    }
                    self.updateInteractiveRects()
                }
            }
        }
    }

    // MARK: - Prompts

    /// The folded prompt card's box: beside the pill, like the done card.
    /// The parts of the notch the intro tour points its doodles at.
    enum TourAnchor { case notch, prompt, toast, tooltip }

    /// Where one of them is on screen, in screen coordinates — nil before the
    /// panel exists, or for a prompt card when no prompt is up.
    func screenRect(of anchor: TourAnchor) -> CGRect? {
        guard let panel else { return nil }
        let local: CGRect
        switch anchor {
        case .notch:
            if model.isExpanded {
                local = notchRect
            } else {
                let length = model.restingLength * model.sizeScale
                local = placement.rect(along: model.slack + (model.shapeLength * model.sizeScale - length) / 2,
                                       across: 0, length: length,
                                       depth: model.restingDepth * model.sizeScale)
            }
        // Where the card will be, whether or not it is up yet: the tour lays
        // its note out round it before it appears, not on top of it.
        case .prompt:
            guard let prompt = model.visiblePromptCard ?? model.currentPrompt else { return nil }
            local = promptCardRect(prompt)
        case .toast:
            local = doneToastRect
        // The open notch and the tooltip it is showing, together.
        case .tooltip:
            guard let index = model.hoveredIndex ?? model.tourHeldIndex, let card = tooltipRect(index: index) else { return nil }
            local = notchRect.union(card)
        }
        return CGRect(x: panel.frame.minX + local.minX, y: panel.frame.maxY - local.maxY,
                      width: local.width, height: local.height)
    }

    /// The screen the panel is on.
    var screen: NSScreen? { panel?.screen }

    private func promptCardRect(_ prompt: PendingPrompt) -> CGRect {
        let height = PromptCard.cardHeight(for: prompt, index: model.promptIndex(of: prompt))
        let scale = model.cardScale
        let cardAcross = (model.edge.isVertical ? NotchLayout.cardWidth : height) * scale
        let cardAlong = (model.edge.isVertical ? height : NotchLayout.cardWidth) * scale
        return placement.rect(
            along: model.slack + model.shapeLength * model.sizeScale / 2 - cardAlong / 2,
            across: model.restingDepth * model.sizeScale,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength * scale + cardAcross
        )
    }

    /// A prompt arrived or went: bring the panel forward so its card can be
    /// reached, and recompute what takes the mouse.
    /// The tooltip's "Answers sent" has run its time: the tooltip goes in
    /// the same animation, unless the pointer is on it or on a ring — then
    /// it simply goes back to following the pointer.
    func tooltipEchoEnded() {
        guard let panel else { return }
        let local = localCursor(in: panel.frame)
        let overTooltip = model.hoveredIndex.flatMap(tooltipRect(index:))?.contains(local) ?? false
        if overTooltip || (model.isExpanded && notchRect.contains(local)) {
            pointerMoved(to: local)
            return
        }
        // Another question still waiting keeps its own tooltip up.
        if model.holdsForPrompt {
            model.hoveredIndex = model.heldTooltipIndex
            return
        }
        clearHoverWork?.cancel()
        clearHoverWork = nil
        model.hoveredIndex = nil
        let holdsOpen = fullScreenNow ? model.isPinned : model.staysOpen
        if !holdsOpen, !liveRect.contains(local), !(peekUntil.map { $0 > Date() } ?? false) {
            foldWork?.cancel()
            foldWork = nil
            model.isExpanded = false
            setPointing(false)
        }
        updateInteractiveRects()
    }

    func promptsChanged() {
        if !Runtime.isUnderTest, !model.prompts.isEmpty { panel?.orderFrontRegardless() }
        panel?.acceptsKeyboard = !model.prompts.isEmpty
        // Typing into a prompt's own answer made the panel key; with the
        // prompt gone, the keyboard goes back to the app it was taken from
        // rather than into a panel that has nothing left to type into.
        if model.prompts.isEmpty, let panel, panel.isKeyWindow {
            keyboardOwner?.activate()
        }
        if model.prompts.isEmpty { keyboardOwner = nil }
        updateInteractiveRects()
    }

    /// The app that had the keyboard before a prompt's field took it.
    private var keyboardOwner: NSRunningApplication?

    /// Remembers where the keyboard came from, the moment the panel takes it.
    private func watchKeyboard(_ panel: NotchPanel) {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self?.keyboardOwner = front
                }
            }
        }
    }

    // MARK: - The done line

    private var doneToastWork: DispatchWorkItem?

    /// The card's box in panel coordinates: beside the folded pill, level
    /// with its middle — the card, its tail, and the gap to the pill, so a
    /// pointer crossing from the pill never leaves it.
    private var doneToastRect: CGRect {
        let scale = model.cardScale
        let cardAcross = (model.edge.isVertical ? NotchLayout.cardWidth : DoneToastView.cardHeight) * scale
        let cardAlong = (model.edge.isVertical ? DoneToastView.cardHeight : NotchLayout.cardWidth) * scale
        return placement.rect(
            along: model.slack + model.shapeLength * model.sizeScale / 2 - cardAlong / 2,
            across: model.restingDepth * model.sizeScale,
            length: cardAlong,
            depth: NotchLayout.tailGap + NotchLayout.tailLength * scale + cardAcross
        )
    }

    /// The round Reply button beside the done card, in panel coordinates —
    /// the same centre the root view draws it at, a little larger than drawn.
    private var doneToastReplyRect: CGRect {
        let scale = model.cardScale
        let centre = DoneToastView.replyBubbleCentre(edge: model.edge, scale: scale,
                                                     restingDepth: model.restingDepth * model.sizeScale,
                                                     alongCentre: model.slack + model.shapeLength * model.sizeScale / 2)
        let size = DoneToastView.replyBubble * scale
        return placement.rect(along: centre.along - size / 2, across: centre.across - size / 2,
                              length: size, depth: size).insetBy(dx: -6, dy: -6)
    }

    /// Say a session finished, from the pill, without opening the notch.
    ///
    /// A click on the line — or on the pill, while the offer stands — raises
    /// that session, the same answer a peek used to take; the offer outlives
    /// the line by the usual grace for a hand that set off late.
    func showDoneToast(_ event: SessionCompletionWatcher.Event, duration: TimeInterval, changes: String? = nil) {
        guard visibility != .hidden, let panel else {
            Log.usage.notice("done line skipped: notch hidden (\(String(describing: self.visibility), privacy: .public), panel \(self.panel == nil ? "none" : "up", privacy: .public))")
            return
        }
        // The session's own agent, whether or not it has a ring here — a
        // Grok card wearing Claude's mark said nothing about which finished.
        let glyph = model.snapshots.first { $0.providerID == event.providerID }?.glyph
            ?? ProviderGlyph.forProvider(event.providerID) ?? .third
        // A few hundred kilobytes of the transcript's end: quick, and the
        // card has to name the session from its first frame.
        var toast = DoneToast(event: event, glyph: glyph, context: DoneToast.context(for: event.session))
        toast.changes = changes
        Log.usage.notice("done card for \(event.session.name, privacy: .private) pid \(toast.pid ?? -1, privacy: .public), rect \(NSStringFromRect(self.doneToastRect), privacy: .public), panel \(NSStringFromRect(panel.frame), privacy: .public)")
        // A session waiting on you is not news that goes stale in five
        // seconds: that card stays until the session stops waiting (see
        // `resolveWaiting`) or is clicked. A finished one is said and goes.
        let lasts = !toast.isBlocked
        // Only a finished card offers "any click opens it", for the moment
        // it is up. A waiting card stays for minutes; an offer that long
        // would turn every click on the notch into a jump to the terminal.
        if lasts, let pid = toast.pid {
            pendingFocus = (pid: pid, until: Date().addingTimeInterval(duration + Self.focusGrace))
        }
        if !Runtime.isUnderTest { panel.orderFrontRegardless() }

        doneToastWork?.cancel()
        // A session waiting on you, pushed aside by one that merely finished,
        // comes back once that card has gone — it is still waiting.
        if lasts, let current = model.activeDoneToast, current.isBlocked { parkedWaiting = current }
        if !lasts { parkedWaiting = nil }
        withAnimation(NotchMotion.contents) { model.activeDoneToast = toast }
        updateInteractiveRects()
        // What it changed, once git has said — off the main thread, filled
        // into the card if it is still the one up.
        if lasts, let pid = toast.pid {
            Task.detached(priority: .utility) { [weak self] in
                guard let cwd = SessionFocus.currentDirectory(of: pid),
                      let changes = GitChanges.summary(cwd: cwd) else { return }
                await MainActor.run {
                    guard let self, var current = self.model.activeDoneToast, current.id == toast.id else { return }
                    current.changes = changes
                    self.model.activeDoneToast = current
                }
            }
        }
        guard lasts else { return }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.activeDoneToast == toast else { return }
                self.clearDoneToast()
            }
        }
        doneToastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Clears a "waiting on you" card once its session is no longer waiting
    /// — answered in the terminal, or anywhere else.
    func resolveWaiting(waitingPIDs: Set<pid_t>) {
        if let parked = parkedWaiting, let pid = parked.pid, !waitingPIDs.contains(pid) { parkedWaiting = nil }
        guard let toast = model.activeDoneToast, toast.isBlocked else { return }
        if let pid = toast.pid, waitingPIDs.contains(pid) { return }
        if let pid = toast.pid, pendingFocus?.pid == pid { pendingFocus = nil }
        clearDoneToast()
    }

    /// Takes the done line down now, and the click offer with it — for the
    /// tour, whose demo line must not outlive its step.
    func dismissDoneToast() {
        if let pid = model.activeDoneToast?.pid, pendingFocus?.pid == pid { pendingFocus = nil }
        parkedWaiting = nil
        clearDoneToast()
    }

    private func clearDoneToast() {
        doneToastWork?.cancel()
        doneToastWork = nil
        let back = model.activeDoneToast?.isBlocked == false ? parkedWaiting : nil
        if model.activeDoneToast?.isBlocked == true { parkedWaiting = nil }
        parkedWaiting = back == nil ? parkedWaiting : nil
        withAnimation(NotchMotion.contents) { model.activeDoneToast = back }
        updateInteractiveRects()
    }

    /// A waiting card a finished one replaced, to bring back after it.
    private var parkedWaiting: DoneToast?

    /// Open the notch and show a usage reset notification modal card.
    func showResetAlert(_ event: UsageResetEvent, duration: TimeInterval = 5.0) {
        guard visibility != .hidden, let panel else {
            Log.usage.debug("reset alert skipped: notch hidden")
            return
        }
        model.activeResetAlert = event
        peek(for: duration, focusing: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.activeResetAlert == event {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.model.activeResetAlert = nil
                    }
                    self.updateInteractiveRects()
                }
            }
        }
    }

    /// How long after a peek folds a click still counts as answering it. Covers
    /// the reach for the mouse that started while the notch was still open.
    private static let focusGrace: TimeInterval = 2

    /// Raise the terminal the peeked session is running in, if the offer stands.
    private func takePendingFocus() -> Bool {
        guard let pending = pendingFocus, pending.until > Date() else {
            pendingFocus = nil
            return false
        }
        pendingFocus = nil
        focusSession(pending.pid)
        return true
    }

    /// An app brought to the front by the workspace, the route that is
    /// honoured for an app that is not itself active.
    static func bringForward(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        Log.usage.notice("done card: bring \(bundleID, privacy: .public) forward")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    /// The same exact-tab jump a session row gives, not just the app — by
    /// the same route the rows take, so a test can stand in for it.
    private func focusSession(_ pid: pid_t) {
        if let onFocusSession = model.onFocusSession {
            onFocusSession(pid)
        } else {
            Task { _ = await SessionFocus.focus(pid: pid) }
        }
    }

    /// Tear down a controller whose display is gone: hide first so no panel
    /// lingers on a screen that no longer exists, then stop its timers and
    /// monitors — a retired controller that kept polling would relocate
    /// another display's panel underneath a parked pointer.
    func retire() {
        apply(.hidden)
        stop()
    }

    /// Clicking the open notch pins it, so it stays put while you read it.
    func togglePinned() {
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        }
        updateInteractiveRects()
        onToggleKeepOpen?()
    }

    func cellIndex(along: CGFloat) -> Int? {
        let pitch = model.cellPitch * model.sizeScale
        for index in model.snapshots.indices {
            let centre = model.slack + model.ringCenter(index: index) * model.sizeScale
            if abs(along - centre) <= pitch / 2 { return index }
        }
        return nil
    }

    // MARK: - Odds and ends

    private func startClock() {
        // Keeps "Resets in N min" from going stale while the tooltip is open.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Right-click: on a ring — or on the tooltip it has open — that agent's
    /// own menu; anywhere else on the notch, the notch's.
    func contextMenu(at locationInWindow: CGPoint) -> NSMenu {
        if let index = cellIndex(atWindowPoint: locationInWindow), let menu = agentMenu(for: index) {
            Log.usage.debug("agent menu opened for \(self.model.snapshots[index].id, privacy: .public)")
            return menu
        }
        Log.usage.debug("context menu opened")
        let menu = NSMenu()
        // AppKit otherwise decides enablement itself and overrules the items'
        // own. Turning it off means every item has to say so for itself.
        menu.autoenablesItems = false
        for item in generalMenuItems() { menu.addItem(item) }
        return menu
    }

    /// Which ring a point in the window is on: the ring itself, or the
    /// tooltip that ring has open. Nil anywhere else.
    func cellIndex(atWindowPoint point: CGPoint) -> Int? {
        guard let panel else { return nil }
        let local = CGPoint(x: point.x, y: panel.frame.height - point.y)
        if model.isExpanded, let index = model.hoveredIndex,
           let card = tooltipRect(index: index), card.contains(local) {
            return index
        }
        guard notchRect.contains(local), let index = cellIndex(along: placement.along(of: local)),
              model.snapshots.indices.contains(index) else { return nil }
        return index
    }

    /// The notch's own items, the same in every menu it shows.
    /// `signIns`: the web sign-ins too — the notch's own menu has them; an
    /// agent's menu leaves the others' out.
    func generalMenuItems(signIns: Bool = true) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let keepOpen = NSMenuItem(
            title: L10n.t("Keep open"),
            action: #selector(MenuActions.togglePinned(_:)),
            keyEquivalent: ""
        )
        keepOpen.state = model.isAlwaysOn ? .on : .off
        keepOpen.target = menuActions
        keepOpen.isEnabled = true
        items.append(keepOpen)

        let refresh = NSMenuItem(
            title: L10n.t("Refresh All"),
            action: #selector(MenuActions.refreshNow(_:)),
            keyEquivalent: "R"
        )
        refresh.target = menuActions
        refresh.isEnabled = true
        items.append(refresh)

        for (index, entry) in signInItems.enumerated() where signIns {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(MenuActions.signIn(_:)),
                keyEquivalent: ""
            )
            item.target = menuActions
            item.tag = index
            item.isEnabled = true
            items.append(item)
        }
        items.append(.separator())
        items.append(ActionMenuItem(L10n.t("Settings…"), key: ",") { [weak self] in self?.onOpenSettings?() })
        let quit = NSMenuItem(title: L10n.t("Quit pillr"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = true
        items.append(quit)
        return items
    }

    private lazy var menuActions = MenuActions(
        refresh: { [weak self] in self?.onRefresh?() },
        signIn: { [weak self] index in self?.signInItems[safe: index]?.action() },
        togglePinned: { [weak self] in self?.togglePinned() }
    )
}


/// A menu item needs an Objective-C target, which a `@MainActor` Swift class
/// with closures cannot be directly.
final class MenuActions: NSObject {
    private let refresh: () -> Void
    private let signIn: (Int) -> Void
    private let pin: () -> Void

    init(
        refresh: @escaping () -> Void,
        signIn: @escaping (Int) -> Void,
        togglePinned: @escaping () -> Void
    ) {
        self.refresh = refresh
        self.signIn = signIn
        self.pin = togglePinned
    }

    @objc func refreshNow(_ sender: Any?) { refresh() }
    @objc func togglePinned(_ sender: Any?) { pin() }

    @objc func signIn(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        signIn(item.tag)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
