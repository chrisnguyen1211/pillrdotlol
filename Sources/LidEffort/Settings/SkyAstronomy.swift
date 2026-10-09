import Foundation

/// When the sun and the moon are really up where this Mac is, worked out on
/// the Mac: no location is asked for and nothing is fetched.
///
/// Where: the time zone's own place in the system's `zone.tab` (Asia/Ho_Chi_Minh
/// is 10°45′N 106°40′E), near enough for sunrise to the minute or two across
/// most of a zone. When: NOAA's sunrise equation for the sun; for the moon, its
/// phase along the synodic month, and a moon that crosses the sky about 50
/// minutes later each day, full opposite the sun and new beside it.
enum SkyAstronomy {
    struct Place: Equatable {
        let latitude: Double
        let longitude: Double
    }

    /// The sun's day, in local hours (6.5 is half past six).
    struct SunDay: Equatable {
        let rise: Double
        let noon: Double
        let set: Double
    }

    /// The moon now: how far across its arc (0 rising, 1 setting, nil when
    /// below the horizon), and its phase (0 new, 0.5 full).
    struct Moon: Equatable {
        let progress: Double?
        let phase: Double
    }

    // MARK: Where

    /// The time zone's place, or one made from its offset: on the equator's
    /// side of the tropics, at the zone's central meridian.
    static func place(for zone: TimeZone = .current, table: String? = zoneTable) -> Place {
        if let table, let found = place(of: zone.identifier, in: table) { return found }
        return Place(latitude: 20, longitude: Double(zone.secondsFromGMT()) / 3600 * 15)
    }

    static let zoneTable: String? = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)

    /// A zone's coordinates from a `zone.tab` line: `VN	+1045+10640	Asia/Ho_Chi_Minh`.
    static func place(of identifier: String, in table: String) -> Place? {
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == identifier else { continue }
            return coordinates(String(fields[1]))
        }
        return nil
    }

    /// ISO 6709 as zone.tab writes it: ±DDMM±DDDMM or ±DDMMSS±DDDMMSS.
    static func coordinates(_ text: String) -> Place? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func angle(_ part: Substring, degreeDigits: Int) -> Double? {
            guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
            let digits = Array(part.dropFirst())
            guard digits.count >= degreeDigits + 2, let degrees = Double(String(digits[0..<degreeDigits])),
                  let minutes = Double(String(digits[degreeDigits..<degreeDigits + 2])) else { return nil }
            let seconds = digits.count >= degreeDigits + 4 ? Double(String(digits[(degreeDigits + 2)..<(degreeDigits + 4)])) ?? 0 : 0
            return (sign == "-" ? -1 : 1) * (degrees + minutes / 60 + seconds / 3600)
        }
        guard let latitude = angle(text[..<split], degreeDigits: 2),
              let longitude = angle(text[split...], degreeDigits: 3) else { return nil }
        return Place(latitude: latitude, longitude: longitude)
    }

    // MARK: The sun

    static func julian(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }
    static func date(julian: Double) -> Date { Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400) }

    /// Sunrise, solar noon and sunset on the local day of `date`. With no
    /// sunset (midnight sun) the day runs edge to edge; with no sunrise
    /// (polar night) all three are noon.
    static func sunDay(on date: Date, at place: Place, calendar: Calendar = .current) -> SunDay {
        let localNoon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let n = (julian(localNoon) - 2_451_545.0 + 0.0008).rounded()
        let jStar = n - place.longitude / 360
        let m = (357.5291 + 0.985_600_28 * jStar).truncatingRemainder(dividingBy: 360) * .pi / 180
        let c = 1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m)
        let lambda = ((m * 180 / .pi) + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * .pi / 180
        let transit = 2_451_545.0 + jStar + 0.0053 * sin(m) - 0.0069 * sin(2 * lambda)
        let declination = asin(sin(lambda) * sin(23.44 * .pi / 180))
        let phi = place.latitude * .pi / 180
        let cosOmega = (sin(-0.833 * .pi / 180) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
        func hours(_ julianDay: Double) -> Double {
            let moment = Self.date(julian: julianDay)
            return moment.timeIntervalSince(calendar.startOfDay(for: date)) / 3600
        }
        let noon = hours(transit)
        if cosOmega > 1 { return SunDay(rise: noon, noon: noon, set: noon) }
        if cosOmega < -1 { return SunDay(rise: 0, noon: noon, set: 24) }
        let omega = acos(cosOmega) * 180 / .pi
        return SunDay(rise: hours(transit - omega / 360), noon: noon, set: hours(transit + omega / 360))
    }

    // MARK: The moon

    static let synodicMonth = 29.530_588_853
    /// A new moon to count from: 6 January 2000, 18:14 UTC.
    static let knownNewMoon = 2_451_550.26

    /// 0 at new moon, 0.5 at full, back towards 1.
    static func moonPhase(_ date: Date) -> Double {
        let cycles = (julian(date) - knownNewMoon) / synodicMonth
        return cycles - floor(cycles)
    }

    /// The moon trails the sun by its phase's share of a day: new, it
    /// keeps the sun's hours; full, it is highest at midnight. It is up for
    /// about half of the 24 h 50 min it takes to come round, ± 6.2 h of its
    /// own noon. (The month moving the phase is what makes it rise about
    /// 50 minutes later each day.)
    static let halfArc = 6.21
    static func moon(at date: Date, sun: SunDay, calendar: Calendar = .current) -> Moon {
        let phase = moonPhase(date)
        let hour = date.timeIntervalSince(calendar.startOfDay(for: date)) / 3600
        return Moon(progress: moonProgress(hour: hour, solarNoon: sun.noon, phase: phase), phase: phase)
    }

    /// How far across its arc the moon is, nil when it is down.
    static func moonProgress(hour: Double, solarNoon: Double, phase: Double) -> Double? {
        // The moon's hour angle, in hours, -12…12: 0 when highest.
        var angle = (hour - solarNoon - phase * 24).truncatingRemainder(dividingBy: 24)
        if angle > 12 { angle -= 24 }
        if angle < -12 { angle += 24 }
        guard abs(angle) <= halfArc else { return nil }
        return (angle + halfArc) / (2 * halfArc)
    }

    // MARK: The sky's hour

    /// The painter's hour for a real one: the sky is drawn for a sun that
    /// rises at 5.9 and sets at 19.0, so the real day is stretched or
    /// squeezed onto that one, piece by piece, night with night.
    static let drawnRise = 5.9, drawnSet = 19.0

    static func drawnHour(_ hour: Double, sun: SunDay) -> Double {
        guard sun.set - sun.rise > 0.1 else { return 0 }          // polar night
        guard sun.set - sun.rise < 23.9 else { return 12 }        // midnight sun
        if hour >= sun.rise && hour <= sun.set {
            return drawnRise + (hour - sun.rise) / (sun.set - sun.rise) * (drawnSet - drawnRise)
        }
        let night = 24 - (sun.set - sun.rise)
        let since = hour > sun.set ? hour - sun.set : hour + 24 - sun.set
        let drawn = drawnSet + since / night * (24 - (drawnSet - drawnRise))
        return drawn >= 24 ? drawn - 24 : drawn
    }
}
