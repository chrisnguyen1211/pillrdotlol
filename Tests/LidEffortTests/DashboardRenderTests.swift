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
