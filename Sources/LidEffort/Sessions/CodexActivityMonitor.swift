import AppKit
import Combine
import Foundation

/// Reports whether Codex is mid-turn.
///
/// Codex publishes no status field — no equivalent of Claude Code's `status` or
/// Cursor's `unfinishedRunAt`. What it does do is append to a thread's rollout
/// log continuously while a turn runs, so a rollout written moments ago means
/// work is happening now.
///
/// **That is a heuristic, and it is labelled as one.** It cannot tell a turn
/// that is thinking from one that finished a second ago, so it errs short: the
/// ring stops spinning `staleAfter` seconds after the last write rather than
/// claiming activity it cannot see. If Codex grows a real status field this
/// should be replaced by it.
@MainActor
final class CodexActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let stateStore: URL
    private let desktopStore: URL
    private let profile: CodexProfile
    private let interval: TimeInterval
    /// How long after the last write a turn is still considered in flight.
    private let staleAfter: TimeInterval
    private var timer: Timer?

    init(
        profile: CodexProfile = .default(),
        stateStore: URL? = nil,
        desktopStore: URL? = nil,
        interval: TimeInterval = 2,
        staleAfter: TimeInterval = 8
    ) {
        self.profile = profile
        self.stateStore = stateStore ?? profile.stateURL
        self.desktopStore = desktopStore ?? profile.desktopStoreURL
        self.interval = interval
        self.staleAfter = staleAfter
    }

    func start() {
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = Self.read(stateStore: stateStore, desktopStore: desktopStore,
                              staleAfter: staleAfter, profile: profile)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(stateStore: URL, desktopStore: URL,
                     staleAfter: TimeInterval, now: Date = Date(),
                     profile: CodexProfile = .default()) -> [AgentSession] {
        // Both surfaces, because "Codex" is two programs that record their work
        // in different places: the CLI and the VS Code extension append to a
        // rollout, and the desktop app writes to its own catalogue. Whichever
        // moved last is the one that is working.
        var candidates: [(id: String, name: String, at: Date)] = []

        if let rollout = CodexStore.newestRollout(in: stateStore),
           let modified = (try? FileManager.default
               .attributesOfItem(atPath: rollout.path))?[.modificationDate] as? Date {
            candidates.append((id: "\(profile.id).\(rollout.lastPathComponent)",
                               name: profile.displayName, at: modified))
        }
        if let desktop = CodexStore.newestDesktopThread(in: desktopStore) {
            candidates.append((id: "\(profile.id).desktop", name: desktop.title,
                               at: desktop.updatedAt))
        }

        guard let newest = candidates.max(by: { $0.at < $1.at }),
              let session = session(id: newest.id, name: newest.name,
                                    modified: newest.at, staleAfter: staleAfter, now: now)
        else { return [] }
        return [session]
    }

    /// Only work recorded within the window counts. Anything older is a
    /// finished turn, and reporting it as work in progress would be a guess
    /// dressed as a fact.
    static func session(
        id: String, name: String, modified: Date, staleAfter: TimeInterval, now: Date
    ) -> AgentSession? {
        let age = now.timeIntervalSince(modified)
        let state: AgentSession.State
        if age <= staleAfter { state = .busy }
        else if age <= staleAfter + 9 { state = .success }
        else if age <= staleAfter + 15 { state = .idle }
        else { return nil }

        let detail: String
        switch state {
        case .busy: detail = L10n.t("Working")
        case .success: detail = L10n.t("Complete")
        case .idle: detail = L10n.t("Idle")
        case .waiting: detail = L10n.t("Waiting") // Should not happen in Codex right now
        }

        return AgentSession(
            id: id,
            name: name,
            detail: detail,
            state: state,
            waitingFor: nil,
            since: modified
        )
    }
}
