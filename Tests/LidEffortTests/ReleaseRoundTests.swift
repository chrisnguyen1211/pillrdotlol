import XCTest
import SwiftUI
import AppKit
@testable import LidEffort

/// The last round before a release: each of this version's features followed
/// end to end, from what the agents, git and the keys write down to what the
/// dashboard and the notch show, with real ledgers, a real git repository, a
/// real prompt socket and real renders, all in a scratch folder.
///
///     swift test --filter ReleaseRoundTests
@MainActor
final class ReleaseRoundTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("release-round-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The repository's root, from this file's place in it.
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private let calendar = Calendar.current
    /// Yesterday, so every moment in the day is already past.
    private lazy var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
    private func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }

    // MARK: - Productivity: agents, git, the coach, badges, the dashboard

    /// A day's work goes from the notch's sessions and git into the activity
    /// ledger, the coach's figures, the badges and the dashboard's widgets.
    func testAWorkingDayReachesTheDashboard() throws {
        // A repository with three commits of yours and one of someone else's.
        let repo = scratch.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        try git(["config", "user.email", "me@example.com"], in: repo)
        try git(["config", "user.name", "Me"], in: repo)
        for (index, hour) in [10.5, 11.25, 12.75].enumerated() {
            try commit("mine-\(index)", at: at(hour), author: "Me <me@example.com>", in: repo)
        }
        try commit("theirs", at: at(12), author: "Them <them@example.com>", in: repo)

        // Two agents at work: Claude 10:00 to 13:00, Codex 11:00 to 12:30.
        let ledgerURL = scratch.appendingPathComponent("activity.sqlite")
        let ledger = try XCTUnwrap(ActivityLedger(url: ledgerURL))
        func observe(_ agent: String, _ busy: Bool, _ hour: Double, _ id: String) {
            let sessions = busy ? [AgentSession(id: id, name: id, detail: "", state: .busy, waitingFor: nil, since: at(hour))] : []
            ledger.observe(agent: agent, sessions: sessions, at: at(hour))
        }
        observe("claude", true, 10, "c1")
        observe("codex", true, 11, "x1")
        observe("codex", false, 12.5, "x1")
        observe("claude", false, 13, "c1")
        ledger.completed(agent: "claude", session: "c1", blocked: false, folder: repo.path,
                         tree: GitChanges.Stats(files: 3, added: 120, removed: 30), at: at(13))
        ledger.answered(agent: "claude", question: false, asked: at(11.5), at: at(11.5).addingTimeInterval(12))
        ledger.flush()

        let summary = ledger.summary(from: day, to: at(24), now: at(18))
        XCTAssertEqual(summary.busy, 4.5 * 3600, accuracy: 1, "three hours of Claude, an hour and a half of Codex")
        XCTAssertEqual(summary.parallel, 1.5 * 3600, accuracy: 1)
        XCTAssertEqual(summary.finished, 1)
        XCTAssertEqual(summary.added, 120)
        XCTAssertEqual(summary.answered, 1)

        // The coach's figures: agent time, and only your commits, from the
        // folder the agent finished in.
        let figures = ProductivityCoach.gather(ledger: ledger, stores: [], now: at(18))
        XCTAssertEqual(figures.commits[day], 3, "someone else's commit is not yours")
        XCTAssertEqual(figures.commitTimes.count, 3)
        XCTAssertEqual(figures.busy[day] ?? 0, 4.5 * 3600, accuracy: 1)

        // Badges, given once.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "release-round-\(UUID().uuidString)"))
        let stats = Achievements.stats(ledger: ledger, commits: figures.commitTimes, paidThisMonth: 0, paidToday: 0,
                                       keys: 0, plans: 0, costPerSession: nil, finishedThisMonth: 0, now: at(18))
        let first = Achievements.award(stats, now: at(18), defaults: defaults)
        let ids = Set(first.map(\.id))
        XCTAssertTrue(ids.contains("dayHours.1"), "over two hours of agent work in a day")
        XCTAssertTrue(ids.contains("parallel.1"), "over an hour with two agents at once")
        XCTAssertFalse(ids.contains("hours.1"), "ten hours in all is not reached")
        XCTAssertEqual(Achievements.award(stats, now: at(19), defaults: defaults), [], "a badge is given once")
        let earned = Achievements.earned(defaults)
        XCTAssertEqual(Set(AchievementsWidget.held(earned).map(\.id)), ids, "the dashboard shows the badges earned, and only those")

        // The dashboard, with those figures, draws in every range and both
        // appearances.
        for range in DashboardModel.Range.allCases {
            let model = DashboardModel.forRender(range: range, sessions: [], keys: [], activity: summary, streak: 1,
                                                 commits: figures.commits.mapValues { Int($0) }, commitTimes: figures.commitTimes,
                                                 earned: earned, bestStreak: 1, busyDays: figures.busy)
            try assertDraws(VStack(spacing: 10) {
                DashboardFolded(model: model).frame(height: WidgetSize.rowHeight)
                DashboardSections(model: model)
            }.padding(12).frame(width: SettingsView.width), "dashboard-\(range)")
        }
        // The last seven days end on today, so the week's columns ring today.
        let model = DashboardModel.forRender(range: .week, sessions: [], keys: [], activity: summary, streak: 1)
        XCTAssertEqual(model.lastDays(7) { _ in 0 }.last?.day, calendar.startOfDay(for: Date()))
    }

    // MARK: - API usage: a key's readings to the dashboard

    /// A key read over a day goes into the spend ledger and comes back out
    /// as today's, this week's and this month's figures in the dashboard.
    func testAKeysReadingsReachTheAPIUsage() throws {
        let ledger = try XCTUnwrap(SpendLedger(url: scratch.appendingPathComponent("spend.sqlite")))
        let usd = APIUnit.money("USD")
        let now = Date()
        let dayStart = SpendLedger.range(.day, containing: now).from
        let weekStart = SpendLedger.range(.week, containing: now).from
        ledger.record(provider: "openrouter-1", reading: .spend(42, usd, .month), periods: [
            .init(period: .day, start: dayStart, amount: 2.5, unit: usd),
            .init(period: .week, start: weekStart, amount: 11, unit: usd),
        ], at: now)
        ledger.flush()
        let row = DashboardModel.KeyRow(id: "openrouter-1", name: "OpenRouter", glyph: .openrouter,
                                        day: ledger.used(provider: "openrouter-1", in: .day, now: now),
                                        week: ledger.used(provider: "openrouter-1", in: .week, now: now),
                                        month: ledger.used(provider: "openrouter-1", in: .month, now: now))
        XCTAssertEqual(row.figure(.day)?.amount, 2.5)
        XCTAssertEqual(row.figure(.week)?.amount, 11)
        XCTAssertEqual(row.figure(.month)?.amount, 42)
        XCTAssertEqual(ledger.providers(), ["openrouter-1"])

        let model = DashboardModel.forRender(range: .month, sessions: [], keys: [row], activity: .init(), streak: 0,
                                             paidByDay: (0..<7).map { (calendar.date(byAdding: .day, value: $0 - 6, to: calendar.startOfDay(for: Date()))!, Double($0)) })
        XCTAssertEqual(model.keySpend, 42, accuracy: 0.001, "this month, the key's month")
        XCTAssertEqual(model.planSpend, 0, "plans are not API usage")
        try assertDraws(VStack {
            SpendChartWidget(model: model).frame(height: 180)
            KeysWidget(model: model).frame(height: 120)
            APISpentWidget(model: model).frame(width: 160, height: WidgetSize.rowHeight)
        }.padding(12).frame(width: SettingsView.width), "api-usage")
    }

    // MARK: - The notch: a prompt answered somewhere else

    /// A permission held in the notch, answered in the terminal instead:
    /// the transcript shows the result, the settlement sees it, and the
    /// broker lets the hook go with no decision of its own.
    func testAPromptAnsweredInTheTerminalLeavesTheNotch() async throws {
        let transcript = scratch.appendingPathComponent("session.jsonl")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let call = #"{"type":"assistant","timestamp":"\#(iso.string(from: Date().addingTimeInterval(-1)))","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_e2e","name":"Bash","input":{"command":"npm test","description":"Run tests"}}]}}"#
        try (call + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let socket = "/tmp/lid-e2e-\(UUID().uuidString.prefix(8)).sock"
        let broker = PromptBroker(path: socket, patience: 30)
        defer { broker.stop() }
        var received: PendingPrompt?
        var gone: UUID?
        broker.onPrompt = { received = $0; return nil }
        broker.onGone = { gone = $0 }
        try broker.start()
        let hook = #"{"session_id":"s-e2e","cwd":"/Users/me/app","transcript_path":"\#(transcript.path)","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"}}"#
        let reply = Task.detached { PromptHookClient.exchange(Data(hook.utf8), path: socket) }
        for _ in 0..<150 where received == nil { try await Task.sleep(for: .milliseconds(20)) }
        let prompt = try XCTUnwrap(received, "the hook reached the notch")

        var settlement = PromptSettlement(sessionsDirectory: scratch.appendingPathComponent("sessions"))
        XCTAssertFalse(settlement.isSettled(prompt, seeing: settlement.observe(prompt)), "still being asked")

        // Answered in the terminal: Claude Code writes the call's result.
        let result = #"{"type":"user","timestamp":"\#(iso.string(from: Date().addingTimeInterval(2)))","message":{"role":"user","content":[{"tool_use_id":"toolu_e2e","type":"tool_result","content":"ok"}]}}"#
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((result + "\n").utf8))
        try handle.close()
        XCTAssertTrue(settlement.isSettled(prompt, seeing: settlement.observe(prompt)), "answered elsewhere")

        broker.release(prompt.id)
        let answer = await reply.value
        XCTAssertEqual(answer, Data(), "the hook hands back no decision of its own")
        for _ in 0..<100 where gone == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(gone, prompt.id, "the card, its notification and its reminder go")
    }

    // MARK: - What this version draws

    /// The sky through a day, the streak's fire at each milestone, every
    /// badge, and card text that keeps its contrast.
    func testEverythingNewDraws() throws {
        // The sky: a picture at every hour, night darker than noon.
        var tops: [Int: CGFloat] = [:]
        for hour in 0..<24 {
            let image = try render(DashboardSky(date: at(Double(hour) + 0.5)).frame(width: 300, height: 120))
            tops[hour] = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)).brightnessComponent
        }
        XCTAssertGreaterThan(tops[12]!, tops[0]! + 0.1, "noon is brighter than midnight")
        XCTAssertEqual(SkyClock.part(9), .morning)
        XCTAssertEqual(SkyClock.part(16), .afternoon)
        XCTAssertEqual(SkyClock.part(2), .night)

        // The fire: none under ten days, more of the card alight at each milestone.
        var lit: [Int] = []
        for level in 0...5 {
            let image = try render(StreakFire(level: level, date: Date(timeIntervalSinceReferenceDate: 812_345_678))
                .frame(width: 330, height: WidgetSize.rowHeight).background(Color.black))
            lit.append(Self.warmPixels(image))
        }
        XCTAssertEqual(lit[0], 0, "no fire before ten days")
        for (lower, higher) in zip(lit, lit.dropFirst()) { XCTAssertLessThan(lower, higher, "each milestone burns bigger: \(lit)") }
        XCTAssertEqual(StreakFire.milestones, [10, 50, 100, 150, 365])

        // Every badge has its own look and draws.
        for family in Achievements.families {
            XCTAssertNotNil(BadgeStyle.styles[family.id], "\(family.id) has a shape and enamel")
            for tier in Achievements.Tier.allCases {
                let image = try render(Medal(badge: .init(family: family.id, tier: tier), earned: true, size: 54))
                XCTAssertGreaterThan(Self.opaquePixels(image), 54 * 54 / 3, "\(family.id).\(tier.rawValue) is drawn")
            }
        }

        // Cards: the scrim that keeps their text readable is not thinned.
        if #available(macOS 26.0, *) {
            XCTAssertGreaterThanOrEqual(CardGlass<Rectangle>.darkScrim(sees: true), 0.87)
            XCTAssertGreaterThanOrEqual(CardGlass<Rectangle>.lightScrim, 0.45)
        }
    }

    // MARK: - The release itself

    /// The version people will see has its notes, in the app and in the
    /// file the appcast is made from, and they agree.
    func testTheReleaseIsWrittenUp() throws {
        let env = try String(contentsOf: Self.repo.appendingPathComponent("script/version.env"), encoding: .utf8)
        let version = try XCTUnwrap(env.split(separator: "\n").first { $0.hasPrefix("MARKETING_VERSION") }?
            .split(separator: "\"").dropFirst().first.map(String.init))
        let note = try XCTUnwrap(ReleaseNotes.all.first)
        XCTAssertEqual(note.version, version, "the newest note is for the version being released")
        let markdown = try String(contentsOf: Self.repo.appendingPathComponent("release-notes/\(version).md"), encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# pillr \(version)\n"))
        XCTAssertTrue(markdown.contains(note.headline), "the app and the appcast lead with the same line")
        for change in note.changes {
            XCTAssertTrue(markdown.contains("**\(change.title).**"), "\(change.title) is in the appcast's notes")
            if !change.detail.isEmpty {
                XCTAssertTrue(markdown.contains(change.detail), "\(change.title) reads the same in both")
            }
        }
        XCTAssertFalse(markdown.contains("—"), "no em dashes in what people read")
    }

    // MARK: - Helpers

    private func git(_ arguments: [String], in folder: URL, environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func commit(_ name: String, at date: Date, author: String, in repo: URL) throws {
        try "\(name)\n".write(to: repo.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        let stamp = "@\(Int(date.timeIntervalSince1970)) +0000"
        try git(["commit", "-q", "-m", name, "--author", author], in: repo,
                environment: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
    }

    private func render<V: View>(_ view: V, scheme: ColorScheme = .light) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "it draws")
    }

    /// Draws in both appearances, and keeps the pictures when asked to.
    private func assertDraws<V: View>(_ view: V, _ name: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(view.background(Color(nsColor: .windowBackgroundColor)), scheme: scheme)
            XCTAssertGreaterThan(image.height, 100, "\(name) has height")
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("release-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// Pixels in the fire's colours, over black: red well above blue.
    private static func warmPixels(_ image: CGImage) -> Int {
        let data = pixels(image)
        return stride(from: 0, to: data.count, by: 4).filter { Int(data[$0]) > 120 && Int(data[$0]) - Int(data[$0 + 2]) > 60 }.count
    }

    private static func opaquePixels(_ image: CGImage) -> Int {
        let data = pixels(image)
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 200 }.count
    }
}
