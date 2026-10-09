import SwiftUI
import LidEffortCore
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    /// Per runtime, so Ollama's relay switching off clears its own readings
    /// and nobody else's.
    private var performances: [String: [String: LocalModelPerformance]] = [:]
    private var ledger = LocalTokenLedger()
    private var localMetricsEnabled = false

    /// The Ollama relay's own id; its readings are keyed by model name.
    static let ollamaSource = "ollama-local"

    func setLocalMetricsEnabled(_ enabled: Bool) {
        localMetricsEnabled = enabled
        if !enabled { performances[Self.ollamaSource] = nil; thinkingModels = [:] }
        snapshots = snapshots.map(decorated)
    }

    func updateSnapshots(_ providerSnapshots: [ProviderSnapshot]) {
        let hoveredID = hoveredSnapshot?.id
        let next = ProviderOrder.cells(from: providerSnapshots, keeping: snapshots).map(decorated)
        let nextHoveredIndex = hoveredID.flatMap { id in next.firstIndex { $0.id == id } }
        if hoveredIndex != nextHoveredIndex { hoveredIndex = nextHoveredIndex }
        snapshots = next
    }

    func updatePerformances(_ measurements: [String: LocalModelPerformance],
                            source: String = NotchViewModel.ollamaSource) {
        performances[source] = measurements
        snapshots = snapshots.map(decorated)
    }

    /// Logged tokens per cell, read against `now` as it is drawn so "today"
    /// rolls over at midnight without a new line being written.
    func updateLedger(_ ledger: LocalTokenLedger) {
        self.ledger = ledger
        snapshots = snapshots.map(decorated)
    }

    private func decorated(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        guard let model = snapshot.localModel else { return snapshot }
        var snapshot = snapshot
        let shows = localMetricsEnabled || snapshot.localRuntimeMeasuresSpeed
        snapshot.showsLocalPerformance = shows
        snapshot.localPerformance = shows
            ? performances[snapshot.providerID]?[Self.performanceKey(for: snapshot, model: model)] : nil
        snapshot.localLedger = ledger.summary(for: snapshot.id, now: now)
        snapshot.localContextFraction = snapshot.localLedger?.contextFraction(contextLength: model.contextLength)
        return snapshot
    }

    /// Ollama's relay knows a model by the name a client used, with Ollama's
    /// implicit `:latest`; everything else reports by notch cell id.
    static func performanceKey(for snapshot: ProviderSnapshot, model: LocalRuntimeReading.Model) -> String {
        snapshot.providerID == ollamaSource ? OllamaThinkingStream.modelKey(model.name) : snapshot.id
    }

    @Published var thinkingModels: [String: Date] = [:]
    /// What each local model instance is doing, keyed by cell id. Ollama's
    /// thinking relay reports through `thinkingModels`; LM Studio's state
    /// poll reports here, phase and queue included.
    @Published var localActivities: [String: LocalModelActivity] = [:]

    /// Live agent sessions, keyed by the provider they belong to. They surface
    /// inside that provider's own ring rather than as a cell of their own — one
    /// ring per provider, so nothing in the notch looks like a ring without
    /// being one.
    @Published var sessions: [String: [AgentSession]] = [:]

    /// Which cell the cursor is over, if any. Driven from the window controller
    /// rather than SwiftUI's `.onHover`: the panel ignores mouse events until
    /// the cursor is over it, so SwiftUI cannot see the crossing that turns
    /// event handling on in the first place.
    @Published var hoveredIndex: Int?
    /// Ticked on refresh so the "Resets in N min" copy stays honest.
    @Published var now: Date = Date()
    @Published var resetTimeFormat: ResetTimeFormat = .automatic

    /// Active usage reset notification event to present beside the notch.
    @Published var activeResetAlert: UsageResetEvent?

    func resetAlertIndex(for event: UsageResetEvent) -> Int? {
        // A key's alert points at the API keys cell it is drawn in.
        snapshots.firstIndex {
            $0.id == event.providerID || $0.keyGroup?.contains { $0.id == event.providerID } == true
        }
    }

    /// The lid-effort module's state: the level, and what each agent's
    /// config was set to for its current model. Nil until the module starts.
    @Published var effort: EffortState?
    /// The effort-change card, shown beside the notch for a moment after a
    /// lid gesture. Cleared by the controller that raised it.
    @Published var activeEffortAlert: EffortChangeEvent?

    /// Where the lid is while it is still moving, in levels, continuous;
    /// nil once it rests. The card's bar follows it.
    @Published var effortPreview: Double?
    /// The tooltip's bar let go on a value: the provider's id and the index
    /// on its scale. Wired by the app delegate to the effort module.
    var onSetEffort: ((String, Int) -> Void)?
    /// The card's bar let go on a lid level, 0 = low.
    var onSetLidLevel: ((Int) -> Void)?

    /// A session just finished, said in a line beside the folded pill.
    /// Cleared by the controller that raised it.
    @Published var activeDoneToast: DoneToast?

    /// The level to mark on a provider's ring — only for providers the lid
    /// actually drives (Claude, Codex, Grok and their profiles), and never
    /// for a local model cell.
    func effortLevel(for snapshot: ProviderSnapshot) -> EffortLevel? {
        guard let effort, snapshot.localModel == nil,
              effort.value(forProviderID: snapshot.providerID) != nil else { return nil }
        return effort.level
    }

    /// The dots on a provider's ring: its model's whole scale, filled to the
    /// value its config holds.
    func effortDots(for snapshot: ProviderSnapshot) -> EffortDotState? {
        guard snapshot.localModel == nil else { return nil }
        return effort?.dots(forProviderID: snapshot.providerID)
    }

    /// What that provider's config currently says, for the tooltip.
    func effortValue(for snapshot: ProviderSnapshot) -> String? {
        guard snapshot.localModel == nil, connectNeed(for: snapshot) == nil else { return nil }
        return effort?.value(forProviderID: snapshot.providerID)
    }

    /// Providers that cannot be read until their account is seen to — see
    /// `ConnectNeed`. Keyed by cell id; pushed by the app delegate.
    @Published var connectNeeds: [String: ConnectNeed] = [:]
    var onConnect: ((String) -> Void)?

    func connectNeed(for snapshot: ProviderSnapshot) -> ConnectNeed? {
        snapshot.localModel == nil ? connectNeeds[snapshot.id] : nil
    }

    /// The tooltip's well under the readings: the effort bar, or in its
    /// place what connecting the account takes. Same height either way.
    func hasEffortRow(for snapshot: ProviderSnapshot) -> Bool {
        effortValue(for: snapshot) != nil || connectNeed(for: snapshot) != nil
    }

    /// Which cell the effort card points at: the first ring the lid drives.
    func effortAlertIndex() -> Int? {
        // The ring of the agent you were working with, when the change
        // came from its session; the first ring with a level otherwise.
        if let agent = activeEffortAlert?.agent,
           let index = snapshots.firstIndex(where: {
               EffortState.targetID(forProviderID: $0.providerID) == agent && effortLevel(for: $0) != nil
           }) {
            return index
        }
        return snapshots.firstIndex { effortLevel(for: $0) != nil }
    }

    /// Whether the notch is open or folded away to its pill.
    @Published var isExpanded = false {
        didSet {
            // The tooltip's "Answers sent" goes with the tooltip.
            if !isExpanded, promptEcho?.origin == .tooltip { promptEcho = nil }
        }
    }
    /// Clicked open, so it stays open until clicked shut again. A gesture,
    /// not a setting: it lasts as long as this session of looking at it.
    @Published var isPinned = false

    /// The standing choice from Settings — "Always show".
    ///
    /// Separate from `isPinned` because the two are not the same claim, and
    /// sharing one flag is what let a click on the bar undo a setting. Clicking
    /// toggles a pin; only Settings moves this.
    @Published var isAlwaysOn = false

    /// Held open, by either route. What the folding logic actually asks.
    var staysOpen: Bool { isPinned || isAlwaysOn }
    /// Providers with a fetch in flight, driven by the store.
    @Published var refreshing: Set<String> = []
    /// Bumped each time the settings orb is clicked, by either route.
    ///
    /// A count rather than a flag: the gear turns to `spins * 360`, so a
    /// second click while the first turn is still running carries on round
    /// instead of restarting from wherever it had got to.
    @Published var settingsSpins = 0

    @Published private(set) var refreshingCells: Set<String> = []

    func isRefreshing(_ snapshot: ProviderSnapshot) -> Bool {
        if let keys = snapshot.keyGroup { return keys.contains { refreshing.contains($0.id) } }
        return snapshot.localModel == nil
            ? refreshing.contains(snapshot.providerID)
            : refreshingCells.contains(snapshot.id)
    }

    func refresh(_ snapshot: ProviderSnapshot, using refreshProvider: (String) async -> Void) async {
        // The API keys cell is every key in it, checked side by side.
        if let keys = snapshot.keyGroup {
            await withoutActuallyEscaping(refreshProvider) { refresh in
                await withTaskGroup(of: Void.self) { group in
                    for key in keys { group.addTask { await refresh(key.id) } }
                }
            }
            return
        }
        guard snapshot.localModel != nil else {
            await refreshProvider(snapshot.providerID)
            return
        }
        guard refreshingCells.insert(snapshot.id).inserted else { return }
        defer { refreshingCells.remove(snapshot.id) }
        // A shared inventory fetch is not activity in every loaded model.
        // Only the clicked cell presses in, even when it joins an existing poll.
        async let feedback: Void = Task.sleep(nanoseconds: 380_000_000)
        await refreshProvider(snapshot.providerID)
        _ = try? await feedback
    }
    /// The settings handle is under the cursor.
    @Published var isHoveringSettings = false
    /// The move handle is under the cursor.
    @Published var isHoveringMove = false
    /// Bumped each time the move handle is pressed, on the same counter
    /// pattern `settingsSpins` uses and for the same reason.
    @Published var moveSpins = 0
    /// The notch is in hand: the move handle has been held past its threshold
    /// and the drop zones are up, waiting for a release.
    @Published var isMoving = false
    /// A direct SwiftUI tap on the settings orb, independent of the panel's
    /// own AppKit-level click routing (`NotchPanel.mouseDown` →
    /// `NotchWindowController.handleClick`). That path relies on the panel's
    /// `ignoresMouseEvents` toggle and a custom `hitTest` staying in exact
    /// agreement with this model's own geometry on every click; this gives
    /// the one action people actually get stuck without a second, ordinary
    /// route that only needs SwiftUI's own gesture recognition to work.
    var onOpenSettings: (() -> Void)?
    /// A tap on a session row in the tooltip: jump to the terminal tab the
    /// session runs in. Takes the session's pid; wired to `SessionFocus`.
    var onFocusSession: ((pid_t) -> Void)?
    /// Reply or Stop, from a session's row or its done card.
    var onSessionAction: ((SessionAction) -> Void)?
    /// Which screen edge the notch is welded to. Everything geometric reads
    /// this through `placement` rather than assuming an axis.
    @Published var edge: NotchEdge = .right
    /// A user-chosen nudge along that edge, in screen points from the centred
    /// default — set live while ⌥-dragging the pill, and by
    /// `NotchGeometry.panelFrame` from there. Reset to whatever was stored for
    /// the new edge whenever `edge` changes; this type does not own that
    /// persistence, only the live value.
    @Published var alongOffset: CGFloat = 0
    /// What every measured distance is multiplied by before it reaches the
    /// screen — the Appearance size choice, as a number.
    ///
    /// Everything in this type stays in **unscaled** points, the size the
    /// design frame is drawn at, and so does `NotchLayout`. Scaling at the
    /// source would mean threading a factor through forty constants and
    /// leaving each one no longer comparable to the frame it is quoted from.
    /// The multiplication happens once, at the two places that touch the
    /// screen: the panel's frame and the drawn content.
    @Published var sizeScale: CGFloat = 1
    /// The cards' own size — tooltips, prompts, the done card — apart from
    /// the pill's: see `Preferences.cardScale`. Cards are drawn at the design
    /// size times this, and every place that measures one multiplies by it.
    @Published var cardScale: CGFloat = 1
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var accentColor: AccentColorChoice = .system
    /// Whether a provider's weekly limit gets a ring of its own, and where.
    /// Mirrored here for the same reason `accentColor` is: the notch is a
    /// separate window, and it has to redraw the moment Settings changes this.
    @Published var weeklyRing: WeeklyRing = .off
    /// Whether the move handle is on the notch at all. Mirrored from Settings
    /// like `weeklyRing`.
    @Published var showsMoveHandle = true
    /// Mirrors the persisted Appearance choice so the separate notch window
    /// redraws immediately when Settings changes it.
    @Published var surfaceStyle: NotchSurfaceStyle = .glass
    /// Light or dark glass, from the switch in Settings. Nil follows the Mac.
    @Published var interfaceMode: InterfaceMode?
    /// How much frost the pill keeps under its glass — see `Preferences.pillFrost`.
    @Published var pillFrost: CGFloat = 0.5
    /// Whether there is a window under the pill for its glass to refract,
    /// as last looked up on the slow poll — see `GlassSightline`.
    @Published var glassSeesBehind = true
    /// The same for the card that is up, which can be somewhere else.
    @Published var cardGlassSeesBehind = true
    /// The wallpaper's tone under the card, when it is over the desktop.
    @Published var cardTone: ColorScheme?

    /// See `Preferences.promptCardOverFullScreen`.
    @Published var promptCardOverFullScreen = true
    /// A full-screen app is in front and the card is to wait for it: the
    /// prompt is held, sounded, and shown when you are back.
    @Published var promptCardHeldForFullScreen = false
    /// The prompt card beside the folded pill, when it is to be drawn.
    var visiblePromptCard: PendingPrompt? {
        guard !isExpanded, !promptCardHeldForFullScreen else { return nil }
        return currentPrompt
    }
    /// The display's own notch, when this edge has to share the bezel with one.
    ///
    /// Set by the window controller from the screen the panel is on, because
    /// that is the only thing that knows which screen that is.
    @Published var hardwareNotch: HardwareNotch?
    /// Hidden while the intro tour's film is on screen.
    @Published var tourVeiled = false

    /// How much screen there is to spend on the panel.
    ///
    /// The tooltip's budget comes out of this: how many sessions a card can
    /// list before the panel holding it would run off the display. Zero until
    /// the controller says otherwise, which reads as "no screen known yet".
    @Published var screenSize: CGSize = .zero

    /// Visible slice of the panel along its edge, in local stack coordinates.
    @Published var visibleAlongRange: ClosedRange<CGFloat>?

    func tooltipAlong(index: Int, length: CGFloat) -> CGFloat {
        let centre = slack + ringCenter(index: index) * sizeScale
        guard let range = visibleAlongRange else { return centre }
        let lower = range.lowerBound + length / 2
        let upper = range.upperBound - length / 2
        guard lower <= upper else { return (range.lowerBound + range.upperBound) / 2 }
        return min(max(centre, lower), upper)
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Language change leaves snapshots untouched; tick `now` so copy
        // already on screen is redrawn against the new catalog.
        NotificationCenter.default.publisher(for: L10n.didChange)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            .store(in: &cancellables)
    }

    /// Take the notch geometry of whichever screen the panel is on.
    func adopt(screen: ScreenDescribing) {
        let merging = edge == .top ? screen.hardwareNotch : nil
        if hardwareNotch != merging { hardwareNotch = merging }
        // `frame`, not `visibleFrame`: the panel is centred on the full screen
        // and may sit under the menu bar, so the menu bar is not room lost.
        let size = screen.frameValue.size
        if screenSize != size { screenSize = size }
    }

    /// How far in from the bezel the notch's contents start.
    ///
    /// Zero everywhere except a top notch merging with the display's own. There
    /// the shape runs up past the menu bar to meet the hardware, and that top
    /// band is a **hole in the screen** — anything drawn in it is not dimmed or
    /// clipped, it is simply not there. So the readings start below it.
    /// Exactly the hardware's height, and nothing on top of it: the readings
    /// then sit the frame's own `ringMargin` below the hardware's bottom edge,
    /// which is the same distance a ring sits from the bezel on every other
    /// placement. Adding a gap as well pads them twice and leaves them adrift
    /// of the notch they are supposed to belong to.
    var contentInset: CGFloat { hardwareNotch?.height ?? 0 }

    /// How much of each end of the bar the flare actually takes.
    var flare: CGFloat {
        hangsFromBezel ? NotchLayout.bezelFillet : NotchLayout.curlRadius
    }

    /// Across the top or the bottom the notch hangs from the bezel as a tab —
    /// the hardware notch's own form — whether or not this display has one.
    /// Down a side it stays the floating capsule.
    var hangsFromBezel: Bool { !edge.isVertical }

    /// Whether a label slot runs under the rings. Only a local model's speed
    /// is ever written there; across the bar, the slot goes when none is
    /// showing, so the rings sit in the middle of it.
    var showsCellLabels: Bool {
        edge.isVertical || snapshots.contains { $0.localModel != nil }
    }

    /// How deep the bar is below any hardware band: what it holds.
    var bodyDepth: CGFloat { NotchLayout.bodyDepth(for: edge, labels: showsCellLabels) }

    /// Whether the shape is drawn the way the Mac's own notch is — flush to
    /// the bezel, no flares — so the two are one object rather than two.
    var isFlushWithHardware: Bool { hardwareNotch != nil }

    /// The hardware notch as the *shape* needs it, which is only where one is
    /// being drawn as.
    var joinedNotch: HardwareNotch? { hardwareNotch }

    /// The corner the shape actually draws at its far end.
    ///
    /// Not always `cornerRadius`: a bar drawn as the hardware notch caps it at
    /// the hardware's own rounding, so that the shape is the same at rest as it
    /// is open. Everything the orb does hangs off this rather than off the
    /// nominal figure — the orb traces the corner that is drawn, not the one
    /// that was asked for.
    var drawnCornerRadius: CGFloat {
        if hugsPill { return bodyDepth / 2 }
        guard hangsFromBezel else { return NotchLayout.cornerRadius }
        // Folded onto a hardware notch it is that notch, rounding and all.
        if let hardwareNotch, !isExpanded { return min(NotchLayout.cornerRadius, hardwareNotch.height / 2) }
        return openTabCorner
    }

    /// The open tab's lower corners: in proportion to how deep it hangs, so a
    /// bar that has grown to take the rings rounds like a thing that size —
    /// the hardware's small rounding on a bar three times its depth read as a
    /// box — and never rounder than the design's corner.
    var openTabCorner: CGFloat {
        min(NotchLayout.cornerRadius, (contentInset + bodyDepth) * Self.tabCornerRatio)
    }

    static let tabCornerRatio: CGFloat = 0.3

    /// What the orb scales to as it folds away. Nestled in a flare it grows
    /// outward along the normal and is swallowed by the notch's black; hanging
    /// off a corner there is nothing to be swallowed by, so it draws in on
    /// itself and leaves by the fade.
    var orbMergeScale: CGFloat {
        orbHugsCorner || orbsInline ? 0.6 : NotchLayout.orbMergeScale
    }

    /// The circle the resting arc follows.
    var orbArcRadius: CGFloat {
        orbHugsCorner
            ? NotchLayout.orbConvexArcRadius(corner: drawnCornerRadius)
            : NotchLayout.orbArcRadius
    }

    /// Extra length at each end of the body so the notch has something to open
    /// out *into*.
    ///
    /// A single ring makes a body about 117pt across; this Mac's notch is 220.
    /// Left alone the hardware would be wider than the bar it is supposed to
    /// grow into, which reads as a mistake. Matching it exactly is not enough
    /// either — a bar the same width as the notch is a straight column, and the
    /// notch appears not to have opened at all. So the floor is the notch plus
    /// a fillet's worth of opening at each side, and a corner's worth beyond
    /// that for the bar's own rounding to live in.
    var endSpread: CGFloat { endSpread(cellCount: snapshots.count) }

    func endSpread(cellCount: Int) -> CGFloat {
        let room = inlineRoom
        guard let hardwareNotch else { return room }
        // Expressed against the whole shape, not just its body: with no flares
        // the drawn width *is* the shape's length, and that is what has to
        // clear the hardware.
        let drawn = NotchLayout.shapeLength(
            cellCount: cellCount, edge: edge, flare: flare
        ) + 2 * room
        let wanted = hardwareNotch.width + 2 * NotchLayout.cornerRadius
        return room + max(0, (wanted - drawn) / 2)
    }

    /// Where the settings orb sits.
    ///
    /// Ordinarily it is concentric with the far flare, one radius in from the
    /// bezel and level with the end of the shape. A flush bar has no flare, so
    /// it hugs the bar's own bottom-end corner from outside instead — same
    /// idea, turned inside out. Left where it was it becomes a dot on the
    /// bar's flat edge.
    ///
    /// Only the capsule down a side now: a bar hung from the bezel carries its
    /// handles inside it (`orbsInline`), with or without a hardware notch.
    var orbHugsCorner: Bool { hugsPill }

    /// Across a hanging tab the handles ride inside the bar, one at each end.
    var orbsInline: Bool { hangsFromBezel }

    /// The room each end of the bar keeps for its handle, beyond the pad the
    /// rings already had: an end pad as deep as the handle's own margin
    /// across the bar, the handle, and a ring's spacing to the first ring.
    var inlineRoom: CGFloat {
        guard orbsInline else { return 0 }
        return inlineOrbEndPad + NotchLayout.inlineOrbDiameter + NotchLayout.inlineOrbGap
            - NotchLayout.padStart(for: edge)
    }

    /// From the end of the bar's straight run to its handle — the same as
    /// from the handle to the bar's lower edge, so it sits square in the end.
    var inlineOrbEndPad: CGFloat { (bodyDepth - NotchLayout.inlineOrbDiameter) / 2 }

    /// The capsule has no flare pocket either, but unlike the flush bar its
    /// ends are semicircles: the orbs sit on the stack's axis just past each
    /// end, and their resting arcs are concentric with those ends.
    var hugsPill: Bool { NotchLayout.pillShape && !hangsFromBezel }

    /// Where each orb's resting arc is centred on the capsule: straight past
    /// the far end for the settings orb, straight past the near end for the
    /// move handle — on the axis, not in a corner. Nil off the capsule.
    var pillOrbCentre: CGFloat? { hugsPill ? Self.circleFraction(of: edge.alongDirection) : nil }
    var pillMoveCentre: CGFloat? {
        hugsPill ? Self.circleFraction(of: CGPoint(x: -edge.alongDirection.x, y: -edge.alongDirection.y)) : nil
    }

    /// A direction as SwiftUI's trim fraction: 0 at three o'clock, clockwise
    /// with y growing downward.
    static func circleFraction(of direction: CGPoint) -> CGFloat {
        let turns = atan2(direction.y, direction.x) / (2 * .pi)
        return turns < 0 ? turns + 1 : turns
    }

    var orbAlong: CGFloat {
        // Square in the far end of the bar, however far the bar was spread to
        // cover a hardware notch — the rings stay centred, the handles ride
        // the ends.
        if orbsInline {
            return shapeLength - flare - inlineOrbEndPad - NotchLayout.inlineOrbDiameter / 2
        }
        guard orbHugsCorner else { return shapeLength }
        return cornerCentreAlong + drawnCornerRadius + NotchLayout.orbGap + NotchLayout.orbDiameter / 2
    }

    /// Reserve the full hit area even while only the resting arc is visible,
    /// so revealing the settings button cannot put it beyond the screen.
    var trailingExtent: CGFloat {
        max(0, orbAlong - shapeLength + NotchLayout.orbHotZone / 2).rounded(.up)
    }

    /// Where the move handle sits: the settings orb's position mirrored to the
    /// near end of the stack. Measured back from zero the same distance the
    /// orb sits past `shapeLength`, so the pair stay symmetric about the notch
    /// at every size and on every edge.
    var moveAlong: CGFloat {
        shapeLength - orbAlong
    }

    /// Where the bar's far corner actually turns, along the stack.
    ///
    /// Inset from the bar's end by the *flare* as well as by the corner's own
    /// radius — the shape's body starts a flare in from each end, and the
    /// corner is rounded off that body, not off the shape's outer bound.
    /// Leaving the flare out slid the arc a whole fillet down the bar, and the
    /// gap it is supposed to hold opened from 9pt at one end to 19pt at the
    /// other.
    var cornerCentreAlong: CGFloat {
        shapeLength - flare - drawnCornerRadius
    }

    var orbInset: CGFloat {
        if orbsInline { return contentInset + bodyDepth / 2 }
        guard orbHugsCorner else { return contentInset + NotchLayout.orbInsetFromEdge }
        return contentInset + bodyDepth / 2
    }

    /// Where the resting arc sits relative to the button.
    ///
    /// Inside a flare's pocket the two are one object — the arc is just the
    /// outer edge of the same orb, and this is zero. Past a capsule's end they
    /// part company: the button sits clear of the capsule, and the arc stays
    /// back on the end it traces.
    var orbArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        // Straight back along the axis to the end's centre of curvature.
        let back = -(drawnCornerRadius + NotchLayout.orbGap + NotchLayout.orbDiameter / 2)
        return CGSize(width: back * edge.alongDirection.x, height: back * edge.alongDirection.y)
    }

    /// `orbArcOffset` mirrored: the move handle hangs off the near corner, so
    /// its arc tucks back *forward* along the stack rather than backward.
    var moveArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        let forward = drawnCornerRadius + NotchLayout.orbGap + NotchLayout.orbDiameter / 2
        return CGSize(width: forward * edge.alongDirection.x, height: forward * edge.alongDirection.y)
    }

    /// The points the settings handle answers around: the button you are
    /// reaching for, and — where it has parted company with it — the arc you
    /// can actually see.
    var orbHandlePoints: [CGPoint] {
        let button = CGPoint(x: orbAlong, y: orbInset)
        guard orbHugsCorner else { return [button] }

        let arcCentre = CGPoint(x: orbAlong + orbArcOffset.width,
                                y: orbInset + orbArcOffset.height)
        let reach = hypot(button.x - arcCentre.x, button.y - arcCentre.y)
        guard reach > 0 else { return [button] }
        // The middle of the quadrant, which is out from its centre in the same
        // direction the button went.
        let arcMid = CGPoint(
            x: arcCentre.x + orbArcRadius * (button.x - arcCentre.x) / reach,
            y: arcCentre.y + orbArcRadius * (button.y - arcCentre.y) / reach
        )
        return [arcMid, button]
    }

    /// Whether a point in stack space is on the settings handle.
    ///
    /// A circle around each of those points, rather than one box around the
    /// pair. The handle is a round thing in two places, and the bounding box of
    /// the two takes in a great deal of ground that is near neither — which is
    /// why the button used to appear well before the pointer reached the arc.
    /// Inside the bar the handle's reach stops short of the first ring's.
    var handleReach: CGFloat {
        orbsInline ? (NotchLayout.inlineOrbDiameter + NotchLayout.inlineOrbGap) / 2 : NotchLayout.orbHotZone / 2
    }

    func isOnOrbHandle(along: CGFloat, across: CGFloat) -> Bool {
        let radius = handleReach
        return orbHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }

    /// The move handle's own points, mirroring `orbHandlePoints` at the near
    /// end of the stack.
    var moveHandlePoints: [CGPoint] {
        // No points, not merely no drawing. Every way of reaching the handle —
        // hover, a press, and the window's own click-through region — is
        // measured from these, so a hidden handle has to report none or it
        // leaves an invisible spot that still starts a move.
        guard showsMoveHandle else { return [] }
        let button = CGPoint(x: moveAlong, y: orbInset)
        guard orbHugsCorner else { return [button] }

        let arcCentre = CGPoint(x: moveAlong + moveArcOffset.width,
                                y: orbInset + moveArcOffset.height)
        let reach = hypot(button.x - arcCentre.x, button.y - arcCentre.y)
        guard reach > 0 else { return [button] }
        let arcMid = CGPoint(
            x: arcCentre.x + orbArcRadius * (button.x - arcCentre.x) / reach,
            y: arcCentre.y + orbArcRadius * (button.y - arcCentre.y) / reach
        )
        return [button, arcMid]
    }

    func isOnMoveHandle(along: CGFloat, across: CGFloat) -> Bool {
        let radius = handleReach
        return moveHandlePoints.contains {
            hypot(along - $0.x, across - $0.y) <= radius
        }
    }


    /// Where the tooltip's tail tip sits, measured in from the bezel: just off
    /// the inner face of a shape that the extension has made deeper.
    var tooltipInset: CGFloat {
        notchDrawnDepth + NotchLayout.tailGap
    }

    /// How deep the notch body reaches on screen — the design-frame depth at
    /// the size it is actually drawn.
    ///
    /// Where the notch ends is where the tooltip begins, and the tooltip is not
    /// drawn at that size, so this is the seam between the two spaces rather
    /// than a measurement either of them owns.
    var notchDrawnDepth: CGFloat {
        (contentInset + bodyDepth) * sizeScale
    }

    /// The straight part of the shape, flares excluded.
    var bodyLength: CGFloat {
        NotchLayout.bodyLength(
            cellCount: snapshots.count, edge: edge, spacing: cellSpacing
        ) + 2 * endSpread
    }

    /// Distance along the stack to cell `index`'s ring centre, widening
    /// included so the readings stay in the middle of the bar.
    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge, flare: flare,
                              spacing: cellSpacing) + endSpread
    }

    var cellSpacing: CGFloat { cellSpacing(cellCount: snapshots.count) }
    var cellPitch: CGFloat { NotchLayout.cellAlong(for: edge) + cellSpacing }

    private func cellSpacing(cellCount: Int) -> CGFloat {
        guard edge.isVertical, screenSize.height > 0, cellCount > 1 else {
            return NotchLayout.cellSpacing
        }
        // Extra model cells spend the gaps first. Reserve the cards actually
        // present; assuming four quota windows for every local model overflows laptops.
        let slack = NotchLayout.slack(for: edge,
            maxCardHeight: snapshots.isEmpty ? NotchLayout.maxCardHeight(sessionCap: 0)
                : contentCardHeight(sessionCap: 0),
            notchScale: sizeScale, cardScale: cardScale)
        let packed = NotchLayout.shapeLength(cellCount: cellCount, edge: edge,
                                             flare: flare, spacing: 0)
        return min(NotchLayout.cellSpacing,
                   max(0, ((screenSize.height - 2 * slack) / sizeScale - packed) / CGFloat(cellCount - 1)))
    }

    /// A provider with no activity source gets none, rather than borrowing
    /// somebody else's.
    func activity(for snapshot: ProviderSnapshot) -> ActivitySummary? {
        guard let model = snapshot.localModel else { return activity(for: snapshot.providerID) }
        if let local = localActivities[snapshot.id] {
            return ActivitySummary(sessions: [AgentSession(id: snapshot.id, name: local.label,
                detail: snapshot.displayName, state: .busy, waitingFor: nil, since: local.since)],
                queued: local.queued, note: local.note)
        }
        guard let since = thinkingModels[OllamaThinkingStream.modelKey(model.name)] else { return nil }
        return ActivitySummary(sessions: [AgentSession(id: snapshot.id, name: L10n.t("Thinking"),
            detail: snapshot.displayName, state: .busy, waitingFor: nil, since: since)])
    }

    func activity(for providerID: String) -> ActivitySummary? {
        ActivitySummary(sessions: (sessions[providerID] ?? []).filter { !isStale($0) })
    }

    /// Claude Code prompts waiting on an answer, oldest first — see
    /// `PromptBroker`. Shown in the Claude tooltip, and beside the folded pill.
    @Published var prompts: [PendingPrompt] = [] {
        didSet {
            // Picks made on a prompt that has gone are dropped; the one in
            // view stays in view if it is still there, else the next one.
            let ids = Set(prompts.map(\.id))
            drafts = drafts.filter { ids.contains($0.key) }
            if let selectedPromptID, let i = prompts.firstIndex(where: { $0.id == selectedPromptID }) {
                promptIndex = i
            } else {
                promptIndex = min(promptIndex, max(0, prompts.count - 1))
            }
            selectedPromptID = currentPrompt?.id
        }
    }
    var onAnswerPrompt: ((UUID, PromptAnswer) -> Void)?
    var onOpenPrompt: ((PendingPrompt) -> Void)?

    /// The line that says a prompt was answered, for a moment, where the
    /// prompt was.
    @Published private(set) var promptEcho: PromptEcho?

    /// An answer from the notch: sent on, and said for a moment where it
    /// was given.
    /// Prompts answered without the "Answers sent" line: the tour's demos,
    /// which the tour answers with a card of its own — the line on top of
    /// it said the same thing twice, and claimed something was sent.
    var quietPrompts: Set<UUID> = []

    func answer(_ id: UUID, with answer: PromptAnswer, from origin: PromptEcho.Origin = .card) {
        if !quietPrompts.contains(id), let prompt = prompts.first(where: { $0.id == id }) {
            say(PromptEcho(answer: answer, prompt: prompt, origin: origin))
        }
        onAnswerPrompt?(id, answer)
    }

    func open(_ prompt: PendingPrompt, from origin: PromptEcho.Origin = .card) {
        if !quietPrompts.contains(prompt.id) { say(PromptEcho(answer: .passThrough, prompt: prompt, origin: origin)) }
        onOpenPrompt?(prompt)
    }

    private func say(_ echo: PromptEcho) {
        withAnimation(NotchMotion.contents) { promptEcho = echo }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PromptEcho.lasts)
            guard let self, self.promptEcho == echo else { return }
            self.endEcho()
        }
    }

    /// Takes the "Answers sent" line down. In a tooltip, the tooltip goes
    /// with it, in the same movement — it was held up for the line, and
    /// letting it fold first left the line hanging on its own.
    func endEcho() {
        guard let echo = promptEcho else { return }
        if echo.origin == .tooltip, let onTooltipEchoEnded {
            withAnimation(NotchMotion.unfold) {
                promptEcho = nil
                onTooltipEchoEnded()
            }
        } else {
            withAnimation(NotchMotion.contents) { promptEcho = nil }
        }
    }

    /// Set by the window controller: with the line gone, whether the
    /// tooltip — and the notch — fold now, which depends on the pointer.
    var onTooltipEchoEnded: (() -> Void)?

    /// Which of several waiting prompts is on screen. Several sessions can
    /// be blocked at once; each keeps its place in the queue, and the card
    /// pages between them.
    @Published private(set) var promptIndex = 0
    private var selectedPromptID: UUID?

    /// The answer being put together for each prompt, kept here rather
    /// than in a view, so paging away and back — or folding the notch and
    /// opening it again — loses nothing that was picked.
    @Published var drafts: [UUID: PromptDraft] = [:]

    var currentPrompt: PendingPrompt? {
        prompts.indices.contains(promptIndex) ? prompts[promptIndex] : prompts.first
    }

    /// "1 of 2", when more than one session is waiting.
    var promptQueue: PromptQueuePosition? {
        guard prompts.count > 1 else { return nil }
        return PromptQueuePosition(index: promptIndex, count: prompts.count)
    }

    func pagePrompt(by delta: Int) {
        guard !prompts.isEmpty else { return }
        promptIndex = (promptIndex + delta + prompts.count) % prompts.count
        selectedPromptID = currentPrompt?.id
    }

    func draft(for prompt: PendingPrompt) -> Binding<PromptDraft> {
        Binding(
            get: { self.drafts[prompt.id] ?? PromptDraft(questions: prompt.questions) },
            set: { self.drafts[prompt.id] = $0 }
        )
    }

    /// The prompt a provider's tooltip carries: Claude's default profile
    /// only, since that is the settings file the hook is installed in.
    func prompt(for snapshot: ProviderSnapshot) -> PendingPrompt? {
        guard snapshot.localModel == nil, snapshot.providerID == ClaudeProfile.defaultID else { return nil }
        return currentPrompt
    }

    /// Sessions blocked on a prompt, by process, and since when — so the
    /// list marks each of them as waiting, not only the one on screen.
    var promptWaiting: [pid_t: Date] {
        prompts.reduce(into: [:]) { map, prompt in
            if let pid = prompt.pid, map[pid] == nil { map[pid] = prompt.receivedAt }
        }
    }

    /// The ring whose tooltip carries the waiting prompt, if one is waiting.
    var promptCellIndex: Int? {
        guard currentPrompt != nil else { return nil }
        return snapshots.firstIndex { prompt(for: $0) != nil }
    }

    /// A question left unanswered does not go away by itself: while one is
    /// waiting, the open notch stays open with its tooltip up, and only an
    /// answer — or the session taking it back — lets it fold.
    var holdsForPrompt: Bool { isExpanded && heldTooltipIndex != nil }

    /// The ring whose tooltip is saying "Answers sent": it stays up for the
    /// line, and folds when the line goes.
    var echoCellIndex: Int? {
        guard promptEcho?.origin == .tooltip else { return nil }
        return snapshots.firstIndex { $0.localModel == nil && $0.providerID == ClaudeProfile.defaultID }
    }

    /// The tooltip held up regardless of the pointer: a waiting question's,
    /// or the answer's line just after it.
    var heldTooltipIndex: Int? { promptCellIndex ?? echoCellIndex ?? tourHeldIndex }

    /// The ring whose tooltip the intro tour is showing — held up the same
    /// way a waiting question's is, until the tour moves on.
    @Published var tourHeldIndex: Int?
    /// What the tour is pointing at in that tooltip.
    @Published var tourFocus: TooltipTourFocus?

    /// How tall the prompt is in that provider's tooltip right now — it
    /// fits the question on screen.
    func promptHeight(for snapshot: ProviderSnapshot) -> CGFloat {
        prompt(for: snapshot).map {
            PromptPanel.height(for: $0, index: drafts[$0.id]?.index ?? 0, queued: promptQueue != nil)
        } ?? 0
    }

    /// The question the prompt card is on, for sizing it.
    func promptIndex(of prompt: PendingPrompt) -> Int { drafts[prompt.id]?.index ?? 0 }

    /// The session cap for one tooltip: a prompt takes the room of as many
    /// rows as it is tall — at its tallest, so the list does not change
    /// length as the questions go by — and the card stays inside the panel.
    func sessionCap(for snapshot: ProviderSnapshot) -> Int {
        let prompt = self.prompt(for: snapshot).map { PromptPanel.maxHeight(for: $0, queued: promptQueue != nil) } ?? 0
        guard prompt > 0 else { return sessionCap }
        let row = 2 * NotchLayout.cardBodyLineHeight + NotchLayout.sessionRowGap + NotchLayout.blockSpacing
        return max(1, sessionCap - Int((prompt + NotchLayout.blockSpacing) / row) - 1)
    }

    /// The most sessions a tooltip lists — see `Preferences.tooltipSessionLimit`.
    @Published var sessionLimit = 6
    /// Idle for longer than this and a session is left out — see
    /// `Preferences.hideIdleSessionsAfterHours`. Nil keeps every one.
    @Published var staleIdleAfter: TimeInterval? = 6 * 3600

    /// Idle, and idle for long enough that it is a terminal left open rather
    /// than a session anyone is in. Only idle ones: a session waiting on you
    /// since this morning is still waiting on you.
    func isStale(_ session: AgentSession) -> Bool {
        guard session.state == .idle, let after = staleIdleAfter else { return false }
        return now.timeIntervalSince(session.since) > after
    }

    var hoveredSnapshot: ProviderSnapshot? {
        guard let hoveredIndex, snapshots.indices.contains(hoveredIndex) else { return nil }
        return snapshots[hoveredIndex]
    }

    var shapeLength: CGFloat { shapeLength(cellCount: snapshots.count) }

    var panelSize: CGSize { panelSize(cellCount: snapshots.count) }

    /// How stack space maps onto the panel right now.
    var placement: NotchPlacement { NotchPlacement(edge: edge, panelSize: panelSize) }

    /// Room at each end of the stack, for this edge.
    var slack: CGFloat { slack(cellCount: snapshots.count) }

    func slack(cellCount: Int) -> CGFloat {
        NotchLayout.slack(for: edge,
                          maxCardHeight: maxCardHeight(cellCount: cellCount),
                          notchScale: sizeScale, cardScale: cardScale)
    }

    /// How many sessions a tooltip may list here before it has to summarise
    /// the rest — as many as this screen has room for.
    var sessionCap: Int { min(sessionLimit, sessionCap(cellCount: snapshots.count)) }

    private var hasTokenUsage: Bool {
        snapshots.contains { $0.tokenUsage != nil }
    }

    private var hasPlan: Bool {
        snapshots.contains { $0.plan != nil }
    }

    private var hasResetCredits: Bool {
        snapshots.contains { $0.resetCredits != nil }
    }

    func sessionCap(cellCount: Int) -> Int {
        guard screenSize != .zero else { return NotchLayout.defaultSessionCap }
        return NotchLayout.sessionsFitting(cardBudget: cardBudget(cellCount: cellCount),
                                           windowCount: NotchLayout.maxWindowCount,
                                           hasTokenUsage: hasTokenUsage,
                                           hasPlan: hasPlan,
                                           hasResetCredits: hasResetCredits)
    }

    private func contentCardHeight(sessionCap: Int) -> CGFloat {
        snapshots.map { snapshot in
            NotchLayout.cardHeight(windowCount: snapshot.windows.count,
                groupCount: Set(snapshot.windows.compactMap(\.group)).count,
                moneyWindowCount: snapshot.windows.filter { $0.money != nil }.count,
                usageDetailGroupCount: snapshot.usageDetail?.visibleGroups.count ?? 0,
                sessionCount: snapshot.localModel == nil ? sessionCap + 1 : 0,
                sessionCap: sessionCap,
                statusMessage: snapshot.statusMessage,
                blockMessage: snapshot.block?.summary(now: now),
                hasTokenUsage: snapshot.tokenUsage != nil,
                hasPlan: snapshot.plan != nil,
                hasResetCredits: snapshot.resetCredits != nil,
                localModelName: snapshot.localModel?.name,
                showsLocalPerformance: snapshot.showsLocalPerformance,
                localLedgerRows: snapshot.localLedgerRowCount,
                compactRowCount: snapshot.compactRowCount,
                costRows: costRows(for: snapshot),
                keyGroupBody: keyGroupBody(for: snapshot))
        }.max() ?? 0
    }

    /// The tallest the API keys card may be: the card the panel is already
    /// sized for at its tallest, so a long list of keys is cut short rather
    /// than growing the panel off the screen.
    ///
    /// Measured against the default session cap, never the one the screen
    /// allows: along a side edge that cap is worked out from the stack's
    /// length, which is worked out from the tallest card — this one — and
    /// asking for it here went round that loop until the stack ran out.
    var keyCardBudget: CGFloat {
        NotchLayout.maxCardHeight(sessionCap: NotchLayout.defaultSessionCap,
                                  hasTokenUsage: hasTokenUsage, hasPlan: hasPlan,
                                  hasResetCredits: hasResetCredits)
    }

    /// The API keys card's rows, as `NotchLayout.cardHeight` budgets them.
    /// Zero for every other card.
    func keyGroupBody(for snapshot: ProviderSnapshot) -> CGFloat {
        guard let keys = snapshot.keyGroup else { return 0 }
        return NotchLayout.keyGroupPlan(keys, cardBudget: keyCardBudget).body
    }

    /// Project rows a card may list: the ones the cost model has, capped at
    /// what the section draws.
    func costRows(for snapshot: ProviderSnapshot) -> Int {
        CostSection.rowCount(for: snapshot)
    }

    func maxCardHeight(cellCount: Int) -> CGFloat {
        let cap = sessionCap(cellCount: cellCount)
        return snapshots.isEmpty
            ? NotchLayout.maxCardHeight(sessionCap: cap, hasTokenUsage: hasTokenUsage, hasPlan: hasPlan,
                                        hasResetCredits: hasResetCredits)
            : contentCardHeight(sessionCap: cap)
    }

    /// How tall the tallest card may be before the panel runs off the screen.
    ///
    /// Which way it runs out differs by orientation, because the card's height
    /// is spent on a different axis: along a side edge it is spent *along* the
    /// stack, half of it past each end, so the stack itself takes its share
    /// first. Along a horizontal edge the card hangs *inward* instead, and what
    /// it competes with is the depth already spent on the notch body and tail.
    /// The screen is measured in real points, and everything it is compared
    /// against here is unscaled. Dividing brings the screen into the same space
    /// rather than scaling the four constants below it: at `large` a card sized
    /// against the raw height would be drawn a quarter taller than it was
    /// budgeted for, and run off the bottom of a small display.
    private func cardBudget(cellCount: Int) -> CGFloat {
        // In the card's own units: a larger card has fewer of them to fill.
        if edge.isVertical {
            return (screenSize.height / sizeScale
                - shapeLength(cellCount: cellCount)
                - 2 * NotchLayout.cardCorner) / cardScale
        }
        return (screenSize.height / sizeScale
            - contentInset
            - bodyDepth
            - NotchLayout.tailLength
            - NotchLayout.tailGap) / cardScale
    }

    /// The drawn extent of the notch body right now, along the stack.
    ///
    /// Where it is joining the display's own notch, folding away means becoming
    /// exactly that notch — same width, same height. The resting pill is the
    /// wrong object there: it hangs below the hardware as a separate little
    /// tab, which is the very seam this placement exists to remove. Matching
    /// the hardware instead means nothing shows at rest at all, and reaching
    /// for it makes the notch itself grow.
    var notchLength: CGFloat {
        if isExpanded { return shapeLength }
        return hardwareNotch?.width ?? NotchLayout.pillHeight
    }

    /// And across it.
    var notchDepth: CGFloat {
        if isExpanded { return contentInset + bodyDepth }
        return hardwareNotch?.height ?? NotchLayout.pillWidth
    }

    /// What the notch folds away to, whether or not it is open right now —
    /// the hit region has to know that while the notch is still open.
    var restingLength: CGFloat { hardwareNotch?.width ?? NotchLayout.pillHeight }
    var restingDepth: CGFloat { hardwareNotch?.height ?? NotchLayout.pillWidth }

    /// What wakes the folded notch, in panel points: the resting shape and a
    /// band around it, or the resting shape alone.
    ///
    /// The band is for the pill. A 10pt sliver on a screen edge is a fiddly
    /// target, and the only cost of surrounding it is that it opens a little
    /// eagerly. Joined to the hardware notch the band is a different matter:
    /// the notch is already a generous target, and a band around it reached
    /// 34pt *below* the menu bar — across the title bar of a window tiled
    /// against the centre of the screen, whose close, minimise and zoom
    /// buttons then opened the notch on approach and disappeared under it.
    /// Flush with the hardware, what wakes the notch is the notch.
    var wakeLength: CGFloat { max(restingLength * sizeScale, wakeBand) }
    var wakeDepth: CGFloat { restingDepth * sizeScale + wakeBand }
    private var wakeBand: CGFloat { isFlushWithHardware ? 0 : NotchLayout.pillHotZone }

    /// The drawn size of the notch body, in panel axes.
    var notchSize: CGSize {
        NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth)
    }

    /// Where the notch starts along the stack. Both states share a centre line,
    /// so folding away does not slide the notch along the edge as it shrinks.
    var notchLeadingInset: CGFloat {
        slack + (shapeLength - notchLength) / 2
    }

    /// Sized from an explicit count rather than from `snapshots`.
    ///
    /// `@Published` notifies its subscribers in `willSet`, so a sink reacting to
    /// a change in the provider list still sees the *old* array if it reads the
    /// model back. Taking the count as an argument is the only way to be sure
    /// the panel is sized for the list that caused the change.
    func shapeLength(cellCount: Int) -> CGFloat {
        NotchLayout.shapeLength(cellCount: cellCount,
                                edge: edge, flare: flare,
                                spacing: cellSpacing(cellCount: cellCount))
            + 2 * endSpread(cellCount: cellCount)
    }

    /// The panel as it lands on screen, size choice included.
    ///
    /// Two spaces, added rather than multiplied together: the notch is drawn at
    /// `sizeScale`, and the tooltip is drawn at one size whatever the notch is
    /// set to — its text has a legible size of its own, and shrinking the
    /// reading you opened the notch to read is the opposite of the point.
    ///
    /// So the notch's share scales and the card's share does not. Scaling the
    /// whole panel instead left the card cropped at the small end, where the
    /// panel had shrunk around a card that had not.
    func panelSize(cellCount: Int) -> CGSize {
        let card = maxCardHeight(cellCount: cellCount)
        return NotchPlacement.panelSize(
            edge: edge,
            length: shapeLength(cellCount: cellCount) * sizeScale
                + 2 * NotchLayout.slack(for: edge, maxCardHeight: card, notchScale: sizeScale, cardScale: cardScale),
            depth: (contentInset + bodyDepth) * sizeScale
                + NotchLayout.tooltipDepth(for: edge, maxCardHeight: card, cardScale: cardScale)
        )
    }
}
