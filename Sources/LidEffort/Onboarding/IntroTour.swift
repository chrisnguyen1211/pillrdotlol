import AppKit
import Combine
import LidEffortCore
import SwiftUI

/// The intro tour: once spyx is set up, a few sticky notes walk through what
/// the pill does — by doing it. The notes point at the real notch with
/// marker doodles drawn over the screen, and the demos are real too: a
/// finished session slides out of the pill, an approval and a question wait
/// on it to be answered. Answering them sends nothing anywhere.
@MainActor
final class IntroTour: ObservableObject {
    enum Step: Int, CaseIterable {
        case hello, sessions, done, approval, question, anywhere, lid, finish

        /// The steps shown on a ring's tooltip, held open between them.
        var holdsTooltip: Bool { self == .hello || self == .sessions }

        /// Whether the note sits in the middle of the screen rather than
        /// beside the part of the notch it is about.
        var isCentred: Bool { self == .anywhere || self == .lid || self == .finish }
    }

    /// The Liquid Glass tour opens with a short film before its first step.
    enum Phase { case intro, steps }

    @Published private(set) var step: Step = .hello
    @Published private(set) var phase: Phase = .steps
    /// The look, fixed for the length of a run.
    @Published private(set) var style: TourStyle = .glass
    /// When the intro started — its every frame is worked out from this.
    @Published private(set) var introStart = Date()
    /// Where the real pill is, for the intro's pill to fly into.
    @Published private(set) var pillRect: CGRect?
    /// The reader's own agents, for the intro's scroll to come to rest on.
    @Published private(set) var introAgents: [ProviderGlyph] = [.claude, .openai, .grok]
    static var introLength: TimeInterval { IntroTimeline.length }

    /// The reader's agents as the notch has them, for the cards' pictures —
    /// real readings when there are some, a stand-in trio when not.
    var pillAgents: [ProviderSnapshot] {
        let real = Array((fleet?.tourAgents ?? []).prefix(3))
        if !real.isEmpty { return real }
        return [(ProviderGlyph.claude, "Claude", 0.35), (.openai, "Codex", 0.62), (.grok, "Grok", 0.84)].map { glyph, name, used in
            ProviderSnapshot(id: "tour-\(name)", displayName: name, glyph: glyph, fidelity: .official, status: .ok,
                             windows: [LimitWindow(id: "w", label: "Session", usedFraction: used)], headlineID: "w")
        }
    }

    /// The demo prompts, as pictures — the same prompts the steps put up.
    /// Made once: a prompt made afresh on every frame of a picture is a new
    /// prompt every frame, and its card started over thirty times a second.
    var sampleApproval: PendingPrompt? { samples.approval }
    var sampleQuestion: PendingPrompt? { samples.question }

    /// What the effort card lists, from the lid's own readings.
    var effortValues: [(name: String, value: String)] {
        let values = effortState.values.sorted { $0.key < $1.key }.map { (name: $0.key.capitalized, value: $0.value) }
        return values.isEmpty ? [(name: "Claude", value: effortState.level.description)] : values
    }
    /// What to cheer when the person has just done the thing.
    @Published private(set) var celebration: String?
    /// When this step's doodles started drawing, and when the last cheer's
    /// sparkles did. The strokes are drawn against these clocks, not from
    /// the moment a view appeared: the doodle layer is rebuilt as the pill
    /// moves, and a stroke that started over on each rebuild never finished —
    /// the arrow that sometimes was not there.
    @Published private(set) var drawingSince = Date()
    @Published private(set) var cheeredAt = Date()
    /// The part of the notch this step is about, in screen coordinates.
    @Published private(set) var anchor: CGRect?
    @Published private(set) var screenFrame: CGRect = .zero
    @Published private(set) var edge: NotchEdge = .right
    @Published private(set) var cardFrame: CGRect = .zero
    @Published private(set) var effortState = EffortState()
    /// The edges the pill has been to on "anywhere" — the step is done when
    /// it has seen all four.
    @Published private(set) var visitedEdges: Set<NotchEdge> = []
    /// While "Show me" is flying it round.
    @Published private(set) var isFlying = false
    /// What the person just did with a demo prompt, said in a card where the
    /// prompt was — the tour's own tooltip, so answering is a step of the
    /// tour rather than the moment everything vanished.
    @Published private(set) var result: TourResult?

    var hasVisitedEveryEdge: Bool { visitedEdges.count == NotchEdge.allCases.count }

    /// How much of a prompt card's rect, on the pill's side, is the gap and
    /// the tail rather than the card — the result card leaves it as a tail.
    var resultTailInset: CGFloat {
        NotchLayout.tailGap + NotchLayout.tailLength * CGFloat(preferences.cardScale)
    }
    /// Where the pill was before the tour brought it home to the right, when
    /// that was somewhere else — the last note offers it back.
    @Published private(set) var edgeBeforeTour: NotchEdge?

    /// The pill's home. The tour is laid out for it — notes to its left,
    /// arrows pointing right — and every drawing in it shows it there.
    static let homeEdge: NotchEdge = .right

    static let cardSize = CGSize(width: 380, height: 430)

    var onEnd: (() -> Void)?
    /// The first launch's intro, with setup to follow: the last card says
    /// what comes next rather than "you're all set".
    @Published var leadsIntoSetup = false
    var isRunning: Bool { cardPanel != nil }

    private weak var fleet: NotchFleet?
    private let preferences: Preferences
    private let effort: () -> EffortController?
    private var demoPrompts: [UUID] = []
    private var overlayPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var poll: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var levelAtLidStep: EffortLevel?
    private var advanceWork: DispatchWorkItem?
    private let samples = (approval: IntroTour.demoApproval(), question: IntroTour.demoQuestion())
    private let sound = MeditationRise()
    private let sounds = TourSounds()
    private var revealWork: DispatchWorkItem?

    private func play(_ effect: TourSounds.Sound) {
        guard preferences.tourSound else { return }
        sounds.play(effect)
    }
    private var introWork: DispatchWorkItem?

    init(fleet: NotchFleet, preferences: Preferences, effort: @escaping () -> EffortController?) {
        self.fleet = fleet
        self.preferences = preferences
        self.effort = effort
    }

    // MARK: Running

    /// Straight to one step, film skipped — `--tour-at done` — for trying a
    /// step without going through the ones before it.
    func start(at step: Step) {
        start(skippingIntro: true)
        go(to: step)
    }

    func start() { start(skippingIntro: false) }

    private func start(skippingIntro: Bool) {
        guard !isRunning else { cardPanel?.orderFrontRegardless(); return }
        // Home first: fly the pill to the right if it lives somewhere else,
        // and let it land before the first note points at it.
        let travelled = bringHome()
        edge = preferences.notchEdge
        style = preferences.tourStyle
        phase = style == .glass && !skippingIntro ? .intro : .steps
        fleet?.isTouring = true
        // A first-time user has no limits used and no sessions yet: the
        // tour shows its own, and the real readings come back at the end.
        fleet?.showTourDemo(snapshots: TourDemo.snapshots(), sessions: TourDemo.sessions())
        makePanels()
        preferences.$notchEdge
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] edge in
                // The edge itself is read off the notch in `follow`: taken
                // from the preference as well, the two disagreed while the
                // pill was in flight and the doodles flickered between them.
                guard let self else { return }
                if self.step == .anywhere { self.arrived(at: edge) }
            }
            .store(in: &cancellables)
        if let controller = effort() {
            effortState = controller.state
            controller.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    self.effortState = state
                    if self.step == .lid, let before = self.levelAtLidStep, state.level != before {
                        self.levelAtLidStep = state.level
                        self.play(.tick)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.play(.approve) }
                        self.cheer(L10n.t("You got it — effort is \(state.level.description) now."))
                    }
                }
                .store(in: &cancellables)
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        if phase == .intro {
            playIntro()
        } else if skippingIntro {
            return
        } else {
            go(to: .hello, peekAfter: travelled ? 1.1 : 0)
        }
    }

    /// The Liquid Glass film: the screen dims, a drop of glass swells into
    /// the pill, the name arrives on the bowl's strike, and the pill flies
    /// home to the right edge — then the first card.
    private func playIntro() {
        // Not yet: the film starts when its sound is ready, on the same frame.
        introStart = Date().addingTimeInterval(3600)
        cardPanel?.orderOut(nil)
        var seen = Set<ProviderGlyph>()
        let mine = (fleet?.tourAgents ?? []).map(\.glyph).filter { seen.insert($0).inserted }
        if !mine.isEmpty { introAgents = Array(mine.prefix(4)) }
        // The real pill stays out of sight until the film's lands on it.
        fleet?.setTourVeil(true)
        follow()
        // The sky's clouds, for this screen, drawn before the first frame
        // rather than on it — and before the sound, so the film waits on both.
        let started = Date()
        PixelSky.prepare(for: screenFrame.size)
        Log.usage.debug("intro sky drawn in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        if preferences.tourSound {
            sound.prepare { [weak self] in self?.beginFilm() }
        } else {
            beginFilm()
        }
    }

    private func beginFilm() {
        guard isRunning, phase == .intro else { return }
        introStart = Date()
        overlayPanel?.ignoresMouseEvents = false
        if preferences.tourSound { sound.play() }
        let reveal = DispatchWorkItem { [weak self] in self?.fleet?.setTourVeil(false) }
        revealWork = reveal
        DispatchQueue.main.asyncAfter(deadline: .now() + IntroTimeline.reveal, execute: reveal)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.overlayPanel?.ignoresMouseEvents = true
            self.phase = .steps
            self.cardPanel?.orderFrontRegardless()
            self.go(to: .hello)
        }
        introWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.introLength, execute: work)
    }

    /// Moves the pill to its home edge, remembering where it was. True when
    /// it had to travel.
    @discardableResult
    func bringHome() -> Bool {
        guard preferences.notchEdge != Self.homeEdge else { return false }
        edgeBeforeTour = preferences.notchEdge
        preferences.notchEdge = Self.homeEdge
        return true
    }

    /// The last note's "Back to top" (or wherever it was).
    func restoreEdge() {
        guard let before = edgeBeforeTour else { return }
        play(.flow)
        edgeBeforeTour = nil
        preferences.notchEdge = before
        end()
    }

    /// The steps this Mac has something to show for: approving and
    /// answering only where an agent here can ask through a hook.
    var steps: [Step] {
        Step.allCases.filter { step in
            (step != .approval && step != .question) || AgentHooks.claudePresent
        }
    }

    func next() {
        if let following = steps.first(where: { $0.rawValue > step.rawValue }) { go(to: following) } else { end() }
    }

    func back() {
        if let previous = steps.last(where: { $0.rawValue < step.rawValue }) { go(to: previous) }
    }

    /// The film, cut short by a click: straight to the first card.
    func skipIntro() {
        guard isRunning, phase == .intro else { return }
        introWork?.cancel()
        revealWork?.cancel()
        sound.stop()
        fleet?.setTourVeil(false)
        overlayPanel?.ignoresMouseEvents = true
        phase = .steps
        cardPanel?.orderFrontRegardless()
        go(to: .hello)
    }

    func end() {
        fleet?.releaseTourTooltip()
        fleet?.dismissDoneToast()
        fleet?.endTourDemo()
        fleet?.isTouring = false
        introWork?.cancel()
        revealWork?.cancel()
        fleet?.setTourVeil(false)
        sound.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [sounds] in sounds.stop() }
        advanceWork?.cancel()
        stopFlying()
        clearDemos()
        poll?.invalidate()
        poll = nil
        cancellables.removeAll()
        overlayPanel?.orderOut(nil)
        overlayPanel?.contentView = nil
        cardPanel?.orderOut(nil)
        cardPanel?.contentView = nil
        overlayPanel = nil
        cardPanel = nil
        onEnd?()
    }

    // MARK: Steps

    private func go(to step: Step, peekAfter delay: TimeInterval = 0) {
        Log.usage.debug("tour: \(String(describing: self.step), privacy: .public) → \(String(describing: step), privacy: .public), fleet \(self.fleet == nil ? "gone" : "here", privacy: .public)")
        advanceWork?.cancel()
        clearDemos()
        celebration = nil
        result = nil
        drawingSince = Date()
        stopFlying()
        // Off "anywhere", wherever it was sent: home to the right, where the
        // rest of the tour — and the person, most days — expects it.
        if self.step == .anywhere, step != .anywhere, preferences.notchEdge != Self.homeEdge {
            preferences.notchEdge = Self.homeEdge
        }
        let from = self.step
        if from.holdsTooltip, !step.holdsTooltip { fleet?.releaseTourTooltip() }
        // The demo's "delivered" line is set to last the whole Done step.
        // Left up, it waited behind the next step's prompt and came back
        // over the tour's own card the moment the prompt was answered.
        if from == .done, step != .done { fleet?.dismissDoneToast() }
        self.step = step
        if step != from || phase == .steps && step != .hello {
            play(step == .finish ? .finish : .next)
        }
        switch step {
        case .hello:
            // The first thing to see: an agent's limits and its sessions,
            // on the real tooltip, held open for as long as this step lasts.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.step == .hello else { return }
                self?.fleet?.holdTourTooltip(focus: .limits)
            }
        // These show beside the folded pill only, so fold it first — a peek
        // still open from the step before hid them.
        case .sessions:
            fleet?.holdTourTooltip(focus: .sessions)
        case .done:
            fleet?.endPeek()
            fleet?.showDoneToast(Self.demoFinished(), duration: 30)
        case .approval:
            fleet?.endPeek()
            show(Self.demoApproval())
        case .question:
            fleet?.endPeek()
            show(Self.demoQuestion())
        case .anywhere:
            visitedEdges = [preferences.notchEdge]
        case .lid:
            levelAtLidStep = effort()?.state.level
        case .finish:
            fleet?.peek(for: 2.5, focusing: nil)
        }
        follow()
    }

    private func show(_ prompt: PendingPrompt?) {
        guard let prompt else { return }
        demoPrompts.append(prompt.id)
        fleet?.addPrompt(prompt, quiet: true)
    }

    private func clearDemos() {
        for id in demoPrompts { fleet?.removePrompt(id) }
        demoPrompts.removeAll()
    }

    /// An answer on one of the tour's own prompts: taken here, sent nowhere.
    /// True when it was one of them.
    func handleAnswer(_ id: UUID, with answer: PromptAnswer = .passThrough) -> Bool {
        guard demoPrompts.contains(id) else { return false }
        demoPrompts.removeAll { $0 == id }
        // Where the prompt stood, kept: the result card takes its place.
        let spot = anchor
        fleet?.removePrompt(id)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            result = TourResult(answer: answer, question: step == .question, at: spot)
        }
        cheer(result?.isPositive == false ? L10n.t("That works too.") : L10n.t("Nice! That's all it takes."))
        // Each answer its own sound: approving is not answering a question,
        // and saying no is quieter still.
        switch answer {
        case .allow, .allowAlways: play(.approve)
        case .answers: play(.answer)
        case .deny, .passThrough: play(.deny)
        }
        return true
    }

    /// A click on one of the demo's sessions: nothing to raise, so the tour
    /// says what would have happened. True when it was a demo session.
    func handleSessionClick(_ pid: pid_t) -> Bool {
        guard TourDemo.pids.contains(pid) else { return false }
        let name = TourDemo.session(pid: pid).map { "\($0.name) (\($0.detail))" } ?? L10n.t("that session")
        cheer(L10n.t("Jumped to \(name) — its window comes to the front."))
        play(.approve)
        return true
    }

    /// The anywhere step's "Show me": on to the next edge round the screen.
    func sendRound() {
        let order = Self.round
        let at = order.firstIndex(of: preferences.notchEdge) ?? 0
        preferences.notchEdge = order[(at + 1) % order.count]
    }

    func sendHome() { preferences.notchEdge = Self.homeEdge }

    /// Round the screen from home, clockwise, and home again.
    static let round: [NotchEdge] = [.right, .bottom, .left, .top]
    static let hopInterval: TimeInterval = 2.1
    private var flight: [DispatchWorkItem] = []

    /// "Show me": the whole way round — every side, a pause on each for the
    /// pill to land and be looked at, then home.
    func flyRound() {
        guard !isFlying else { return }
        isFlying = true
        let start = Self.round.firstIndex(of: preferences.notchEdge) ?? 0
        for hop in 1...Self.round.count {
            let edge = Self.round[(start + hop) % Self.round.count]
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.step == .anywhere else { return }
                self.preferences.notchEdge = edge
                if hop == Self.round.count { self.isFlying = false }
            }
            flight.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(hop - 1) * Self.hopInterval, execute: work)
        }
    }

    private func stopFlying() {
        flight.forEach { $0.cancel() }
        flight.removeAll()
        isFlying = false
    }

    /// The pill landed on `edge` during "anywhere".
    func arrived(at edge: NotchEdge) {
        visitedEdges.insert(edge)
        play(.flow)
        if hasVisitedEveryEdge {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.play(.answer) }
            cheer(edge == Self.homeEdge ? L10n.t("All four sides, and home. spyx can be anywhere!")
                                        : L10n.t("All four sides! spyx can be anywhere."))
            return
        }
        switch edge {
        case .right:  cheer(L10n.t("Home on the right."))
        case .bottom: cheer(L10n.t("Down along the bottom!"))
        case .left:   cheer(L10n.t("Over on the left!"))
        case .top:    cheer(L10n.t("Up top, like a notch!"))
        }
    }

    private func cheer(_ text: String) {
        cheeredAt = Date()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { celebration = text }
    }

    /// For the render tests: a step, and where things are, without panels.
    func showForTesting(_ step: Step, anchor: CGRect?, screen: CGRect, edge: NotchEdge, celebration: String? = nil,
                        result: TourResult? = nil, visited: Set<NotchEdge> = [], style: TourStyle = .doodle,
                        phase: Phase = .steps, introAt: TimeInterval = 0) {
        self.style = style
        self.phase = phase
        introStart = Date().addingTimeInterval(-introAt)
        pillRect = anchor
        self.step = step
        self.result = result
        self.visitedEdges = visited
        drawingSince = .distantPast
        cheeredAt = .distantPast
        self.anchor = anchor
        self.screenFrame = screen
        self.edge = edge
        self.celebration = celebration
        cardFrame = Self.cardFrame(anchor: step.isCentred ? nil : anchor, edge: edge, visible: screen, size: Self.cardSize)
    }

    // MARK: Where things are

    /// Keeps the doodles on the notch while it moves: an edge change flies
    /// the pill across the screen, and a card opening moves what they point at.
    private func follow() {
        let wanted: NotchWindowController.TourAnchor
        switch step {
        case .hello, .sessions: wanted = .tooltip
        case .done: wanted = .toast
        case .approval, .question: wanted = .prompt
        default: wanted = .notch
        }
        let found = fleet?.tourAnchor(wanted) ?? fleet?.tourAnchor(.notch)
        guard let found else { return }
        // Pointing at the pill wherever it has flown on "anywhere"; at the
        // result card, once there is one, rather than at the pill behind it.
        let rect: CGRect? = result?.rect ?? (step == .anywhere ? fleet?.tourAnchor(.notch)?.rect
                                                                : step.isCentred ? nil : found.rect)
        if anchor != rect { anchor = rect }
        if edge != found.edge { edge = found.edge }
        if let overlayPanel, !overlayPanel.isVisible { overlayPanel.orderFrontRegardless() }
        if phase == .steps, let cardPanel, !cardPanel.isVisible { cardPanel.orderFrontRegardless() }
        let pill = fleet?.tourAnchor(.notch)?.rect
        if pillRect != pill { pillRect = pill }
        let frame = found.screen.frame
        if screenFrame != frame {
            screenFrame = frame
            overlayPanel?.setFrame(frame, display: true)
        }
        let card = Self.cardFrame(anchor: step.isCentred ? nil : rect, edge: found.edge,
                                  visible: found.screen.visibleFrame, size: Self.cardSize)
        if cardFrame != card {
            cardFrame = card
            cardPanel?.setFrame(card, display: true)
        }
    }

    /// Beside what it is about, on the side away from the bezel, a gap off
    /// it; in the middle of the screen when it is about no one place.
    static func cardFrame(anchor: CGRect?, edge: NotchEdge, visible: CGRect, size: CGSize,
                          gap: CGFloat = 130) -> CGRect {
        var origin: CGPoint
        if let a = anchor {
            switch edge {
            case .right:  origin = CGPoint(x: a.minX - gap - size.width, y: a.midY - size.height / 2)
            case .left:   origin = CGPoint(x: a.maxX + gap, y: a.midY - size.height / 2)
            case .top:    origin = CGPoint(x: a.midX - size.width / 2, y: a.minY - gap - size.height)
            case .bottom: origin = CGPoint(x: a.midX - size.width / 2, y: a.maxY + gap)
            }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let inset = visible.insetBy(dx: 24, dy: 24)
        origin.x = min(max(origin.x, inset.minX), inset.maxX - size.width)
        origin.y = min(max(origin.y, inset.minY), inset.maxY - size.height)
        return CGRect(origin: origin, size: size).integral
    }

    // MARK: Panels

    private func makePanels() {
        let overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        // A panel hides when its app stops being the active one, which for
        // spyx is nearly always — and took the doodles with it.
        overlay.hidesOnDeactivate = false
        overlay.level = .floating
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        overlay.contentView = NSHostingView(rootView: TourOverlay(tour: self))
        overlay.orderFrontRegardless()
        overlayPanel = overlay

        let card = NSPanel(contentRect: CGRect(origin: .zero, size: Self.cardSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false
        card.level = .floating
        card.becomesKeyOnlyIfNeeded = true
        card.hidesOnDeactivate = false
        // Above the notch's own panel. At the same level as the doodles it
        // sat under the notch, and where a done note or a prompt's card
        // reached over it, Next took the click on behalf of the notch.
        card.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        card.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        card.contentView = style == .glass
            ? FirstClickHostingView(rootView: AnyView(GlassTourCard(tour: self)))
            : FirstClickHostingView(rootView: AnyView(TourCard(tour: self)))
        if phase == .steps { card.orderFrontRegardless() }
        cardPanel = card
    }

    // MARK: The demos

    static func demoFinished() -> SessionCompletionWatcher.Event {
        let session = AgentSession(id: "spyx-tour", name: "my-app", detail: L10n.t("Refactored the auth flow"),
                                   state: .success, waitingFor: nil, since: Date())
        return SessionCompletionWatcher.Event(session: session, reason: .finished, providerID: ClaudeProfile.defaultID)
    }

    static func demoApproval() -> PendingPrompt? {
        prompt([
            "tool_name": "Bash",
            "session_id": "spyx-tour",
            "cwd": "/Users/you/my-app",
            "tool_input": ["command": "npm run build", "description": "Build the app"],
            "permission_suggestions": [["type": "addRules", "behavior": "allow"]],
        ], context: PromptContext(title: "my-app", ask: L10n.t("Ship the new login screen"),
                                  lead: L10n.t("Tests pass. Building before I deploy."), branch: "main"))
    }

    static func demoQuestion() -> PendingPrompt? {
        prompt([
            "tool_name": "AskUserQuestion",
            "session_id": "spyx-tour",
            "cwd": "/Users/you/my-app",
            "tool_input": ["questions": [[
                "question": L10n.t("Which database should the sync job write to?"),
                "header": L10n.t("Database"),
                "multiSelect": false,
                "options": [
                    ["label": "Postgres", "description": L10n.t("The main cluster")],
                    ["label": "SQLite", "description": L10n.t("A local file, for tests")],
                    ["label": L10n.t("Both"), "description": L10n.t("Postgres, mirrored to SQLite")],
                ],
            ]]],
        ], context: PromptContext(title: "my-app", ask: L10n.t("Add an offline sync job"),
                                  lead: L10n.t("Two places it could write to."), branch: "sync"))
    }

    private static func prompt(_ json: [String: Any], context: PromptContext) -> PendingPrompt? {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var prompt = PendingPrompt(hookInput: data) else { return nil }
        prompt.sessionName = "my-app"
        prompt.context = context
        return prompt
    }
}

// MARK: - What each step says, in either look

extension IntroTour {
    var stepTitle: String {
        switch step {
        case .hello: return L10n.t("Every limit, at a glance")
        case .sessions: return L10n.t("Many sessions, one place")
        case .done: return L10n.t("Done? I'll tell you.")
        case .approval: return L10n.t("Approve from right here")
        case .question: return L10n.t("Answer questions too")
        case .anywhere: return L10n.t("spyx can be anywhere!")
        case .lid: return L10n.t("Tilt the lid to think harder")
        case .finish: return leadsIntoSetup ? L10n.t("One more minute") : L10n.t("You're all set ✨")
        }
    }

    var stepText: String {
        switch step {
        case .hello:
            return L10n.t("Each ring is one coding agent. Hover it for its session and weekly limits, when they reset, and every session it's running — no opening Claude, Codex or Cursor to check. Click a session to jump straight to it.")
        case .sessions:
            return L10n.t("Running several sessions across Claude, Codex and Cursor? Each ring lists its own — working, waiting on you, done or idle. Click one to jump straight to its window. Try it on one of these.")
        case .done:
            return L10n.t("When an agent finishes, a note slides out of the pill — even with the notch folded. Click it to jump straight to that session.")
        case .approval:
            return result == nil
                ? L10n.t("Claude wants to run something? Allow or deny it without leaving what you're doing. Go on, try — this one's only a demo.")
                : L10n.t("That's the whole of it: one click, and you're back to what you were doing.")
        case .question:
            return result == nil
                ? L10n.t("When Claude asks, pick an answer and press Send. It goes back to the right session, and Claude keeps going.")
                : L10n.t("Several sessions asking at once? Each question waits under its own session, in turn.")
        case .anywhere:
            return L10n.t("Drag the pill to any edge, or hover it and click ↻. Show me flies it round all four sides and back home to the right.")
        case .lid:
            if !effortState.sensorAvailable {
                return L10n.t("This Mac has no lid sensor, so set the level from the dots on any ring's tooltip instead.")
            }
            return L10n.t("Hold ⌘ and tilt the lid: open it further for more effort, close it a little for less. Let go to set it — every agent follows.")
        case .finish:
            if leadsIntoSetup {
                return L10n.t("Next, a short setup: pick your agents and give macOS's permissions once, so nothing interrupts you later.")
            }
            return L10n.t("I'm on the edge of your screen whenever you need me. Setup and this tour are in Settings → General if you want them again.")
        }
    }
}

/// A hosting view that takes the first click: the tour's note sits in a panel
/// that never becomes key, and without this the first press on Next only
/// focused it.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the person did with one of the tour's prompts, and what it would
/// have meant for a real session — shown in a card where the prompt was.
struct TourResult: Equatable {
    let title: String
    let detail: String?
    let meaning: String
    let isPositive: Bool
    /// Where the prompt card stood, in screen coordinates.
    let rect: CGRect?

    init(answer: PromptAnswer, question: Bool, at rect: CGRect?) {
        self.rect = rect
        switch answer {
        case .allow:
            title = L10n.t("Allowed")
            detail = "npm run build"
            meaning = L10n.t("Claude runs it and carries on — you never left your window.")
            isPositive = true
        case .allowAlways:
            title = L10n.t("Allowed, and remembered")
            detail = "npm run build"
            meaning = L10n.t("Claude won't ask about this command again in that project.")
            isPositive = true
        case .deny:
            title = L10n.t("Denied")
            detail = "npm run build"
            meaning = L10n.t("Claude skips it and asks you what to do instead.")
            isPositive = false
        case .answers(let answers):
            title = L10n.t("Answered")
            detail = answers.values.flatMap { $0 }.joined(separator: ", ")
            meaning = L10n.t("The answer goes straight back to that session, and Claude keeps going.")
            isPositive = true
        case .passThrough:
            title = question ? L10n.t("Left to Claude") : L10n.t("Opened in Claude")
            detail = nil
            meaning = L10n.t("Claude asks in its own window instead — your call, every time.")
            isPositive = false
        }
    }
}
