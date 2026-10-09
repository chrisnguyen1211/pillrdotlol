import XCTest
@testable import LidEffort

/// The real sun and moon behind the dashboard's sky.
final class SkyAstronomyTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func clock(_ hours: Double) -> String { String(format: "%02d:%02d", Int(hours), Int((hours - floor(hours)) * 60)) }

    func testAZonesPlaceIsReadFromZoneTab() throws {
        let saigon = try XCTUnwrap(SkyAstronomy.coordinates("+1045+10640"))
        XCTAssertEqual(saigon.latitude, 10.75, accuracy: 0.01)
        XCTAssertEqual(saigon.longitude, 106.667, accuracy: 0.01)
        let london = try XCTUnwrap(SkyAstronomy.coordinates("+513030-0000731"))
        XCTAssertEqual(london.latitude, 51.508, accuracy: 0.01)
        XCTAssertEqual(london.longitude, -0.125, accuracy: 0.01)
        let table = "# comment\nVN\t+1045+10640\tAsia/Ho_Chi_Minh\nGB\t+513030-0000731\tEurope/London\n"
        XCTAssertEqual(SkyAstronomy.place(for: TimeZone(identifier: "Europe/London")!, table: table), london)
        // A zone the table doesn't have: its offset's meridian.
        let tokyo = SkyAstronomy.place(for: TimeZone(identifier: "Asia/Tokyo")!, table: table)
        XCTAssertEqual(tokyo.longitude, 135, accuracy: 0.01)
    }

    /// Against published times, to within a few minutes.
    func testSunriseAndSunsetAreTheRealOnes() throws {
        let saigon = calendar("Asia/Ho_Chi_Minh")
        let october = SkyAstronomy.sunDay(on: day(2026, 10, 9, in: saigon), at: .init(latitude: 10.75, longitude: 106.667),
                                          calendar: saigon)
        XCTAssertEqual(october.rise, 5 + 40.0 / 60, accuracy: 0.1, "Saigon, 9 October: sunrise about 05:40, got \(clock(october.rise))")
        XCTAssertEqual(october.set, 17 + 37.0 / 60, accuracy: 0.1, "sunset about 17:37, got \(clock(october.set))")
        let london = calendar("Europe/London")
        let winter = SkyAstronomy.sunDay(on: day(2026, 12, 21, in: london), at: .init(latitude: 51.508, longitude: -0.125),
                                         calendar: london)
        XCTAssertEqual(winter.rise, 8 + 4.0 / 60, accuracy: 0.1, "London, midwinter: sunrise about 08:04, got \(clock(winter.rise))")
        XCTAssertEqual(winter.set, 15 + 53.0 / 60, accuracy: 0.1, "sunset about 15:53, got \(clock(winter.set))")
        let tromso = calendar("Europe/Oslo")
        let polar = SkyAstronomy.sunDay(on: day(2026, 12, 21, in: tromso), at: .init(latitude: 69.65, longitude: 18.96), calendar: tromso)
        XCTAssertEqual(polar.rise, polar.set, "polar night: no sunrise")
        XCTAssertEqual(SkyAstronomy.drawnHour(15, sun: polar), 0, "drawn as night")
    }

    func testTheMoonsPhaseFollowsTheMonth() {
        let utc = calendar("UTC")
        let eclipse = utc.date(from: DateComponents(year: 2024, month: 4, day: 8, hour: 18, minute: 21))!
        let phase = SkyAstronomy.moonPhase(eclipse)
        XCTAssertTrue(phase < 0.02 || phase > 0.98, "new moon at the 2024 eclipse, got \(phase)")
        let full = utc.date(from: DateComponents(year: 2024, month: 4, day: 23, hour: 23, minute: 49))!
        XCTAssertEqual(SkyAstronomy.moonPhase(full), 0.5, accuracy: 0.02, "full moon, 23 April 2024")
    }

    /// A full moon rises as the sun sets and is highest at midnight; a new
    /// one keeps the sun's hours.
    func testTheMoonRisesWithItsPhase() {
        func progress(_ hour: Double, _ phase: Double) -> Double? {
            SkyAstronomy.moonProgress(hour: hour, solarNoon: 12, phase: phase)
        }
        XCTAssertEqual(progress(0, 0.5) ?? -1, 0.5, accuracy: 0.01, "full: highest at midnight")
        XCTAssertEqual(progress(18, 0.5) ?? -1, 0, accuracy: 0.05, "full: rising as the sun sets")
        XCTAssertNil(progress(12, 0.5), "full: down at noon")
        XCTAssertEqual(progress(12, 0) ?? -1, 0.5, accuracy: 0.01, "new: up with the sun")
        XCTAssertNil(progress(0, 0), "new: down at midnight")
        XCTAssertEqual(progress(18, 0.25) ?? -1, 0.5, accuracy: 0.01, "first quarter: highest at sunset")
        XCTAssertNotNil(progress(6.5, 0.75), "last quarter: still up in the morning")
    }

    /// The real day lands on the drawn one: sunrise on the drawn sunrise,
    /// sunset on the drawn sunset, and the night runs on without a jump.
    func testTheRealDayIsMappedOntoTheDrawnOne() {
        let sun = SkyAstronomy.SunDay(rise: 5.67, noon: 11.65, set: 17.62)
        XCTAssertEqual(SkyAstronomy.drawnHour(5.67, sun: sun), SkyAstronomy.drawnRise, accuracy: 0.001)
        XCTAssertEqual(SkyAstronomy.drawnHour(17.62, sun: sun), SkyAstronomy.drawnSet, accuracy: 0.001)
        XCTAssertGreaterThan(SkyAstronomy.drawnHour(17.7, sun: sun), SkyAstronomy.drawnSet, "just after sunset is dusk")
        let beforeMidnight = SkyAstronomy.drawnHour(23.999, sun: sun)
        let afterMidnight = SkyAstronomy.drawnHour(0.001, sun: sun)
        XCTAssertLessThan(abs(beforeMidnight - afterMidnight).truncatingRemainder(dividingBy: 24), 0.01, "no jump at midnight")
        XCTAssertEqual(SkyClock.part(SkyAstronomy.drawnHour(18.5, sun: sun)), .dusk, "an hour after a 17:37 sunset is dusk, not daylight")
    }
}
