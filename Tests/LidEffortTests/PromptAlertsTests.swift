import XCTest
@testable import LidEffort

/// How a waiting approval or question gets your attention.
@MainActor
final class PromptAlertsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "PromptAlertsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func prompt(_ json: String, pid: pid_t? = nil, name: String? = nil) throws -> PendingPrompt {
        var p = try XCTUnwrap(PendingPrompt(hookInput: Data(json.utf8)))
        p.pid = pid
        p.sessionName = name
        return p
    }
    private let bash = #"{"cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"npm test"}}"#
    private let ask = #"{"cwd":"/tmp/demo","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","options":[{"label":"A"},{"label":"B"}]}]}}"#

    func testDefaultsSoundOnceAndShowTheCard() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.promptSound)
        XCTAssertEqual(preferences.approvalSoundName, SessionChime.defaultBlocked)
        XCTAssertEqual(preferences.questionSoundName, SessionChime.defaultQuestion)
        XCTAssertNotEqual(preferences.approvalSoundName, preferences.questionSoundName, "the ear can tell them apart")
        XCTAssertEqual(preferences.promptReminderMinutes, 0)
        XCTAssertFalse(preferences.promptSystemNotification)
        XCTAssertTrue(preferences.promptCardOverFullScreen)
    }

    func testAnsweringFromTheNotchIsOnUnlessTurnedOff() {
        XCTAssertTrue(Preferences(defaults: defaults).answerPromptsFromNotch, "on by default")
        Preferences(defaults: defaults).answerPromptsFromNotch = false
        XCTAssertFalse(Preferences(defaults: defaults).answerPromptsFromNotch, "turned off stays off")
    }

    func testChoicesAreKept() {
        let preferences = Preferences(defaults: defaults)
        preferences.promptSound = false
        preferences.questionSoundName = "Tink"
        preferences.promptReminderMinutes = 2
        preferences.promptSystemNotification = true
        preferences.promptCardOverFullScreen = false
        let again = Preferences(defaults: defaults)
        XCTAssertFalse(again.promptSound)
        XCTAssertEqual(again.questionSoundName, "Tink")
        XCTAssertEqual(again.promptReminderMinutes, 2)
        XCTAssertTrue(again.promptSystemNotification)
        XCTAssertFalse(again.promptCardOverFullScreen)
    }

    func testAnUnknownReminderIsNever() {
        defaults.set(7, forKey: "promptReminderMinutes")
        XCTAssertEqual(Preferences(defaults: defaults).promptReminderMinutes, 0)
    }

    func testApprovalsAndQuestionsSoundDifferentAndSilenceIsSilence() throws {
        let preferences = Preferences(defaults: defaults)
        preferences.approvalSoundName = "Funk"
        preferences.questionSoundName = "Ping"
        XCTAssertEqual(PromptAlerts.sound(for: try prompt(bash), preferences: preferences), "Funk")
        XCTAssertEqual(PromptAlerts.sound(for: try prompt(ask), preferences: preferences), "Ping")
        preferences.promptSound = false
        XCTAssertNil(PromptAlerts.sound(for: try prompt(bash), preferences: preferences))
    }

    func testTheNotificationSaysWhoAndWhat() throws {
        let approval = PromptAlerts.notificationText(for: try prompt(bash, name: "nas-fix"))
        XCTAssertEqual(approval.title, "Needs your OK · nas-fix · demo")
        XCTAssertTrue(approval.body.contains("npm test"))
        let question = PromptAlerts.notificationText(for: try prompt(ask))
        XCTAssertEqual(question.title, "Claude asks · demo")
        XCTAssertEqual(question.body, "Which database?")
    }

    func testRemindersComeEveryFewMinutesOnlyWhileSomethingWaits() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var reminder = PromptReminder(minutes: 2)
        reminder.sounded(at: t0)
        XCTAssertFalse(reminder.due(waiting: true, now: t0.addingTimeInterval(90)))
        XCTAssertTrue(reminder.due(waiting: true, now: t0.addingTimeInterval(121)))
        XCTAssertFalse(reminder.due(waiting: true, now: t0.addingTimeInterval(150)), "counted again from the reminder")
        XCTAssertTrue(reminder.due(waiting: true, now: t0.addingTimeInterval(245)))
        XCTAssertFalse(reminder.due(waiting: false, now: t0.addingTimeInterval(600)), "nothing waiting, nothing to say")
        XCTAssertFalse(reminder.due(waiting: true, now: t0.addingTimeInterval(700)), "and the next prompt starts fresh")

        var never = PromptReminder(minutes: 0)
        never.sounded(at: t0)
        XCTAssertFalse(never.due(waiting: true, now: t0.addingTimeInterval(3600)))
    }

    func testSoundOnlyHoldsTheCardWhileAFullScreenAppIsInFront() throws {
        let controller = NotchWindowController()
        var fullScreen = true
        controller.isFullScreenActive = { fullScreen }
        controller.model.updateSnapshots(Fixtures.snapshots())
        controller.relocate()
        controller.model.promptCardOverFullScreen = false
        controller.model.prompts = [try prompt(bash)]

        controller.handleActiveSpaceOrAppChange()
        XCTAssertNil(controller.model.visiblePromptCard, "no card under a pointer busy in a game")
        XCTAssertNotNil(controller.model.currentPrompt, "the prompt itself still waits")

        fullScreen = false
        controller.handleActiveSpaceOrAppChange()
        XCTAssertNotNil(controller.model.visiblePromptCard, "back from full screen, the card is there")

        controller.model.promptCardOverFullScreen = true
        fullScreen = true
        controller.handleActiveSpaceOrAppChange()
        XCTAssertNotNil(controller.model.visiblePromptCard, "Show the card shows it over full screen too")
    }

    func testSearchFindsTheNewSettings() {
        XCTAssertTrue(SettingsIndex.search("fullscreen").contains { $0.title == "Over full-screen apps" })
        XCTAssertTrue(SettingsIndex.search("remind").contains { $0.section == .notifications })
        XCTAssertTrue(SettingsIndex.search("question sound").contains { $0.section == .notifications })
    }
}
