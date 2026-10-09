import XCTest
import SwiftUI
@testable import LidEffort

/// The dashboard, drawn with figures set by hand.
@MainActor
final class DashboardRenderTests: XCTestCase {
    func testTheDashboardRenders() throws {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!.start
        func row(_ day: Int, _ model: String, _ cost: Double) -> TimelinePane.Row {
            let first = start.addingTimeInterval(Double(day) * 86_400 + 9 * 3600)
            return TimelinePane.Row(sessionID: "\(day)\(model)", account: "Claude", accountIndex: 0, project: "/r", cwd: "/r",
                                    model: model, first: first, last: first.addingTimeInterval(3600), turns: 20, tokens: 100_000, cost: cost)
        }
        let usd = APIUnit.money("USD")
        var activity = ActivityLedger.Summary()
        activity.busy = 9 * 3600; activity.parallel = 2 * 3600; activity.waiting = 1800
        activity.finished = 14; activity.sessions = 19; activity.added = 1840; activity.removed = 420
        activity.answered = 23; activity.medianAnswer = 18
        activity.busyByAgent = ["claude": 6 * 3600, "codex": 2 * 3600, "grok": 3600]
        let model = DashboardModel.forRender(
            range: .week,
            sessions: [row(0, "claude-opus-5-5", 12), row(1, "claude-opus-5-5", 18), row(2, "claude-sonnet-5-5", 4), row(2, "gpt-5.6", 7)],
            keys: [
                .init(id: "a", name: "OpenRouter", glyph: .openrouter, day: .init(amount: 1.2, unit: usd, since: nil),
                      week: .init(amount: 8.4, unit: usd, since: nil), month: .init(amount: 31, unit: usd, since: nil)),
                .init(id: "b", name: "DeepSeek", glyph: .deepseek, day: .init(amount: 0.3, unit: usd, since: Date()),
                      week: .init(amount: 0.3, unit: usd, since: Date()), month: nil),
            ],
            plans: [
                .init(id: "claude", agentName: "Claude", glyph: .claude, reported: "Max 20x", name: "Max 20x", monthly: 200,
                      currency: "USD", source: .table),
                .init(id: "cursor", agentName: "Cursor", glyph: .cursor, reported: "pro_plus", name: "Pro+", monthly: 60,
                      currency: "USD", source: .table),
                .init(id: "kimi", agentName: "Kimi", glyph: .kimi, reported: "Vivace", name: "Vivace", monthly: nil,
                      currency: "USD", source: nil),
            ],
            activity: activity, streak: 6,
            commits: Dictionary(uniqueKeysWithValues: (0..<110).compactMap { back -> (Date, Int)? in
                let day = Calendar.current.date(byAdding: .day, value: -back, to: Calendar.current.startOfDay(for: Date()))!
                let n = (back * 7 + 3) % 11
                return n > 3 ? (day, n - 3) : nil
            }),
            coach: [.init(at: Date(), kind: .record, metric: "busy", timeframe: "week", period: start, value: 9 * 3600,
                          previous: 7 * 3600, shown: true),
                    .init(at: Date().addingTimeInterval(-86_400 * 3), kind: .record, metric: "commits", timeframe: "day",
                          period: start, value: 14, previous: 11, shown: false)],
            paidByDay: (0..<7).map { (Calendar.current.date(byAdding: .day, value: $0 - 6, to: Calendar.current.startOfDay(for: Date()))!,
                                      Double([3, 8, 2, 12, 6, 9, 4][$0])) },
            paidByHour: (0..<24).map { $0 >= 9 && $0 <= 18 ? Double(($0 * 5) % 7) : 0 },
            commitTimes: (0..<9).map { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(9 + $0 % 5) * 3600) },
            earned: ["hours.1": Date(), "hours.2": Date(), "commits.1": Date(), "streak.1": Date(), "tokenMaxxer.1": Date(),
                     "tokenMaxxer.2": Date(), "tokenMaxxer.3": Date(), "dayHours.1": Date(), "keys.1": Date(), "late.1": Date()],
            bestStreak: 11,
            busyDays: Dictionary(uniqueKeysWithValues: (0..<14).map { back in
                (Calendar.current.date(byAdding: .day, value: -back, to: Calendar.current.startOfDay(for: Date()))!,
                 Double((back * 5 + 2) % 9) * 3600)
            }))
        let view = VStack(spacing: 16) {
            DashboardFolded(model: model).frame(height: WidgetSize.rowHeight)
            CommitsWidget(model: DashboardModel.forRender(range: .today, sessions: [], keys: [], activity: .init(), streak: 0,
                                                          commitTimes: (0..<9).map { Calendar.current.startOfDay(for: Date())
                                                              .addingTimeInterval(Double(9 + $0 % 5) * 3600) }),
                          compact: false).frame(height: 158)
            DashboardSections(model: model)
        }
        .padding(18)
        .frame(width: SettingsView.width)
        for dark in [false, true] {
            let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.nsImage)
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("dashboard-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// Every badge, a family a row, bronze to gold.
    func testEveryBadgeRenders() throws {
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(Achievements.families, id: \.id) { family in
                HStack(spacing: 18) {
                    ForEach(Achievements.Tier.allCases, id: \.self) { tier in
                        let badge = Achievements.Badge(family: family.id, tier: tier)
                        VStack(spacing: 3) {
                            Medal(badge: badge, earned: true, size: 64)
                            Text(Achievements.name(badge)).font(.system(size: 10, weight: .medium))
                        }
                        .frame(width: 92)
                    }
                }
            }
        }
        .padding(20)
        for dark in [false, true] {
            let renderer = ImageRenderer(content: sheet.background(dark ? Color(white: 0.12) : Color(white: 0.95))
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("badges-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The notch card for badges just earned, one and several, and the
    /// burst at a few moments.
    func testTheBadgeCardRenders() throws {
        let one = Achievements.note([.init(family: "tokenMaxxer", tier: .gold)])
        let three = Achievements.note([.init(family: "streak", tier: .silver), .init(family: "commits", tier: .bronze),
                                       .init(family: "late", tier: .gold)])
        XCTAssertEqual(one.badges.count, 1)
        XCTAssertEqual(three.badges.count, 3)
        func event(_ note: CardNote) -> UsageAlertEvent {
            var event = UsageAlertEvent(kind: .recap, providerID: "coach", providerName: "", windowLabel: "",
                                        glyph: .third, previousFraction: 0, currentFraction: 0, resetsAt: nil)
            event.note = note
            return event
        }
        let sheet = VStack(spacing: 14) {
            UsageResetCard(event: event(one), direction: .leading, onDismiss: {})
            UsageResetCard(event: event(three), direction: .leading, onDismiss: {})
            HStack(spacing: 6) {
                ForEach([0.15, 0.4, 0.8, 1.3, 2.4], id: \.self) { moment in
                    BadgeBurst(badges: [.init(family: "streak", tier: .gold)], size: 50, frozenAt: moment)
                }
            }
        }
        .padding(16)
        .environment(\.badgeBurstFrozenAt, 2.4)
        for dark in [false, true] {
            let renderer = ImageRenderer(content: sheet.background(dark ? Color(white: 0.1) : Color(white: 0.93))
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("badge-card-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The Streak card's fire at each milestone: none under ten days, a
    /// blaze at a year.
    func testTheStreakFireGrowsAtEachMilestone() throws {
        XCTAssertEqual(StreakFire.level(9), 0)
        XCTAssertEqual(StreakFire.level(10), 1)
        XCTAssertEqual(StreakFire.level(50), 2)
        XCTAssertEqual(StreakFire.level(149), 3)
        XCTAssertEqual(StreakFire.level(150), 4)
        XCTAssertEqual(StreakFire.level(400), 5)
        XCTAssertEqual(StreakFire.next(12), 50)
        XCTAssertNil(StreakFire.next(365))
        for (lower, higher) in zip(0..<5, 1...5) { XCTAssertLessThan(StreakFire.reach(lower), StreakFire.reach(higher)) }
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678)
        let cards = VStack(spacing: 10) {
            ForEach([3, 10, 50, 100, 150, 365], id: \.self) { days in
                WidgetCard(title: "Streak", symbol: "flame.fill", tint: .orange,
                           backdrop: AnyView(StreakFire(level: StreakFire.level(days), date: date))) {
                    WidgetFigure(value: "\(days) days", detail: "Best: \(days) days")
                }
                .frame(width: 330, height: WidgetSize.rowHeight)
            }
        }
        .padding(12)
        let renderer = ImageRenderer(content: cards.background(Color(white: 0.92)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"], let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("streak-fire.png"))
        }
    }

    /// The dashboard opens on this month, so commits open on the GitHub
    /// grid, and then on whatever was chosen last.
    func testTheDashboardOpensOnThisMonthThenOnTheLastChoice() {
        let key = DashboardModel.Range.rememberedKey
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(DashboardModel.Range.remembered, .month)
        UserDefaults.standard.set("week", forKey: key)
        XCTAssertEqual(DashboardModel.Range.remembered, .week)
        XCTAssertEqual(DashboardMode(rawValue: "") ?? .folded, .folded, "folded, the small view, unless chosen otherwise")
    }

    /// The sky at the hours that look most unlike: morning, noon, golden
    /// afternoon, sunset, dusk and night.
    func testTheSkyFollowsTheHour() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        var dark: [Double] = []
        for hour in [7.5, 12.0, 16.5, 18.0, 19.5, 23.0] {
            let date = day.addingTimeInterval(hour * 3600)
            let renderer = ImageRenderer(content: DashboardSky(date: date).frame(width: SettingsView.width - 36, height: DashboardPanel.foldedHeight))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            // The top row's brightness: night is darker than noon.
            let rep = NSBitmapImageRep(cgImage: image)
            let top = rep.colorAt(x: 4, y: 4)!.usingColorSpace(.sRGB)!
            dark.append(top.brightnessComponent)
            if let dir = ProcessInfo.processInfo.environment["EFFORT_RENDER_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sky-\(hour).png"))
            }
        }
        XCTAssertGreaterThan(dark[1], dark[5])
        XCTAssertEqual(SkyClock.part(12), .noon)
        XCTAssertEqual(SkyClock.part(23), .night)
        XCTAssertEqual(SkyClock.part(18), .sunset)
    }
}
