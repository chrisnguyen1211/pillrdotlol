import XCTest
@testable import LidEffort

/// First-launch defaults and the choices that have to survive a relaunch.
@MainActor
final class PreferencesDefaultsTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    // MARK: Carrying settings across the bundle id change

    private func oldDomain(_ contents: [String: Any]) -> String {
        let name = "PreferencesTests.old.\(UUID().uuidString)"
        UserDefaults.standard.setPersistentDomain(contents, forName: name)
        return name
    }

    func testSettingsCarryAcrossTheBundleIDChange() {
        let (fresh, _) = makeDefaults()
        let old = oldDomain(["notchVisibility": "alwaysShow", "notchEdge": "top"])
        defer { UserDefaults.standard.removePersistentDomain(forName: old) }
        Preferences.migrateFromPreviousDomain(into: fresh, from: old)
        let preferences = Preferences(defaults: fresh)
        XCTAssertEqual(preferences.notchVisibility, .alwaysShow)
        XCTAssertEqual(preferences.notchEdge, .top)
    }

    /// Once the new domain is in use, nothing is copied again.
    func testTheCarryHappensOnce() {
        let (fresh, _) = makeDefaults()
        let old = oldDomain(["notchVisibility": "alwaysShow"])
        defer { UserDefaults.standard.removePersistentDomain(forName: old) }
        Preferences.migrateFromPreviousDomain(into: fresh, from: old)
        let preferences = Preferences(defaults: fresh)
        preferences.notchVisibility = .hidden
        Preferences.migrateFromPreviousDomain(into: fresh, from: old)
        XCTAssertEqual(preferences.notchVisibility, .hidden)
    }

    func testNothingToCarryIsHarmless() {
        let (fresh, _) = makeDefaults()
        Preferences.migrateFromPreviousDomain(into: fresh, from: "does.not.exist.\(UUID().uuidString)")
        XCTAssertEqual(Preferences(defaults: fresh).notchVisibility, .onHover)
    }

    // MARK: Defaults

    func testAFirstLaunchReadsTheDesignedDefaults() {
        let (fresh, _) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        XCTAssertTrue(preferences.isFirstLaunch)
        XCTAssertEqual(preferences.notchVisibility, .onHover)
        XCTAssertEqual(preferences.appPresence, .dock)
        XCTAssertEqual(preferences.notchEdge, .right)
        XCTAssertEqual(preferences.notchSize, .medium)
        XCTAssertEqual(preferences.weeklyRing, .off)
    }

    /// The switch starts where the Mac is and, once flipped, stays flipped.
    func testTheLightDarkSwitchSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        XCTAssertEqual(Preferences(defaults: fresh).interfaceMode, .system)
        let flipped = Preferences(defaults: fresh).interfaceMode.toggled
        Preferences(defaults: fresh).interfaceMode = flipped
        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).interfaceMode, flipped)
    }

    /// Off by default, and it has to stay chosen once it is chosen: an extra
    /// arc in a 44pt circle changes how every reading looks, so it is not
    /// something to switch on for somebody, nor to forget they switched on.
    func testTheWeeklyRingIsOffUntilAskedForAndThenSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        XCTAssertEqual(Preferences(defaults: fresh).weeklyRing, .off)

        Preferences(defaults: fresh).weeklyRing = .outside

        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).weeklyRing, .outside)
    }

    /// On by default — it is how the notch is carried to another edge — and
    /// once somebody hides it, it has to stay hidden across a relaunch.
    func testTheMoveHandleShowsUntilHiddenAndStaysHidden() {
        let (fresh, name) = makeDefaults()
        XCTAssertTrue(Preferences(defaults: fresh).showsMoveHandle)

        Preferences(defaults: fresh).showsMoveHandle = false

        XCTAssertFalse(Preferences(defaults: UserDefaults(suiteName: name)!).showsMoveHandle)
    }

    /// The size has to outlive the launch that chose it, or it reads as a
    /// setting that did not take.
    func testTheNotchSizeSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        Preferences(defaults: fresh).notchSize = .large

        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).notchSize, .large)
    }

    /// An install that predates the setting keeps exactly the notch it had.
    /// `medium` is the design frame at 1:1, so this is what makes that true.
    func testMediumIsTheSizeEveryEarlierVersionDrew() {
        XCTAssertEqual(NotchSize.medium.scale, 1)
    }

    // MARK: The slider, and which control is in charge

    /// The presets stay in charge until the slider is explicitly chosen, so
    /// an install that predates it draws exactly the notch it always drew.
    func testThePresetsAreStillInChargeByDefault() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.usesCustomNotchScale)
        XCTAssertEqual(preferences.notchScale, NotchSize.medium.scale)
    }

    /// Whichever control is in charge is the one `notchScale` answers with —
    /// that resolution is the whole point of keeping the two apart.
    func testTheScaleFollowsWhicheverControlIsInCharge() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.notchSize = .large
        preferences.customNotchScale = 0.9

        XCTAssertEqual(preferences.notchScale, NotchSize.large.scale)
        preferences.usesCustomNotchScale = true
        XCTAssertEqual(preferences.notchScale, 0.9, accuracy: 0.0001)
    }

    /// Switching back to the presets returns to the preset that was chosen,
    /// not to whichever one happens to sit nearest the slider.
    func testLeavingTheSliderReturnsToTheChosenPreset() {
        let (defaults, _) = makeDefaults()
        let preferences = Preferences(defaults: defaults)
        preferences.notchSize = .small
        preferences.usesCustomNotchScale = true
        preferences.customNotchScale = 1.5
        preferences.usesCustomNotchScale = false

        XCTAssertEqual(preferences.notchScale, NotchSize.small.scale)
    }

    /// A value written straight into `defaults` could otherwise shrink the
    /// notch to nothing or blow it off the screen, so it is clamped on the
    /// way in as well as on the way out of the slider.
    func testAnOutOfRangeScaleIsClamped() {
        let (defaults, name) = makeDefaults()
        let preferences = Preferences(defaults: defaults)

        preferences.customNotchScale = 12
        XCTAssertEqual(preferences.customNotchScale,
                       Preferences.customScaleRange.upperBound, accuracy: 0.0001)

        preferences.customNotchScale = -3
        XCTAssertEqual(preferences.customNotchScale,
                       Preferences.customScaleRange.lowerBound, accuracy: 0.0001)

        UserDefaults(suiteName: name)!.set(99.0, forKey: "customNotchScale")
        XCTAssertEqual(Preferences(defaults: UserDefaults(suiteName: name)!).customNotchScale,
                       Preferences.customScaleRange.upperBound, accuracy: 0.0001)
    }

    /// Both halves of the choice have to outlive the launch that made it.
    func testTheSliderChoiceSurvivesARelaunch() {
        let (fresh, name) = makeDefaults()
        let preferences = Preferences(defaults: fresh)
        preferences.usesCustomNotchScale = true
        preferences.customNotchScale = 1.35

        let reloaded = Preferences(defaults: UserDefaults(suiteName: name)!)
        XCTAssertTrue(reloaded.usesCustomNotchScale)
        XCTAssertEqual(reloaded.customNotchScale, 1.35, accuracy: 0.0001)
        XCTAssertEqual(reloaded.notchScale, 1.35, accuracy: 0.0001)
    }
}

@MainActor
final class NotchPositionPersistenceTests: XCTestCase {
    func testEachEdgesPositionSurvivesReopeningPreferences() throws {
        let name = "NotchPositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        for (index, edge) in NotchEdge.allCases.enumerated() {
            preferences.setOffset(CGFloat(index * 150 - 225), for: edge)
        }
        let reopened = Preferences(defaults: defaults)
        for (index, edge) in NotchEdge.allCases.enumerated() {
            XCTAssertEqual(reopened.offset(for: edge), CGFloat(index * 150 - 225))
        }
    }
}
