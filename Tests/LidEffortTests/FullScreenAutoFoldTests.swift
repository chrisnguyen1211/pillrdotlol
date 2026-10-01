import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LidEffort

@MainActor
final class FullScreenAutoFoldTests: XCTestCase {
    func testDetectorFindsFullScreenWindowMatchingScreenBounds() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: 9999, layer: 0, bounds: CGRect(x: 50, y: 50, width: 800, height: 600)),
            (pid: pid, layer: 0, bounds: screen),
            (pid: pid, layer: 24, bounds: screen) // menu bar or overlay
        ]

        XCTAssertTrue(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: pid, windows: windows))
    }

    func testDetectorFindsFullScreenWindowOnNotchedDisplay() {
        // On a MacBook with camera notch, CoreGraphics screen origin is (0, 0)
        // and full-screen windows start below the notch/menu bar (e.g. y=44)
        // extending to the bottom edge (height = 1117 - 44 = 1073).
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 0, y: 44, width: 1728, height: 1073))
        ]

        XCTAssertTrue(
            FullScreenDetector.isFullScreen(
                screenBounds: screen,
                frontmostPID: pid,
                windows: windows,
                safeAreaTopInset: 44
            ),
            "Full-screen window starting below the notch and reaching screen bottom must be detected"
        )
    }


    func testDetectorRejectsWindowWhenNotMatchingScreenBounds() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let pid: pid_t = 12345
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: pid, layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 800))
        ]

        XCTAssertFalse(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: pid, windows: windows))
    }

    func testDetectorRejectsFullScreenWindowOfNonFrontmostApp() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frontPID: pid_t = 12345
        let otherPID: pid_t = 67890
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = [
            (pid: otherPID, layer: 0, bounds: screen)
        ]

        XCTAssertFalse(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: frontPID, windows: windows))
    }

    func testControllerAutoFoldsWhenActiveSpaceChangesToFullScreen() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isExpanded = true
        controller.model.isPinned = true
        controller.isFullScreenActive = { true }

        // Post active space changed notification
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertFalse(controller.model.isExpanded, "The notch must fold when entering a full-screen space")
        XCTAssertFalse(controller.model.isPinned, "The notch must unpin when folded for full-screen")
    }

    func testControllerAutoFoldsWhenFullscreenAppActivates() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isExpanded = true
        controller.isFullScreenActive = { true }

        // Post application activation notification
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        XCTAssertFalse(controller.model.isExpanded, "The notch must fold when a full-screen app activates")
    }

    func testControllerDoesNotFoldWhenAppIsNotFullScreen() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isExpanded = true
        controller.isFullScreenActive = { false }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertTrue(controller.model.isExpanded, "The notch should stay open if the active space is not full-screen")
    }

    func testAlwaysOnRestoresExpandedWhenLeavingFullScreen() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isAlwaysOn = true
        controller.model.isExpanded = true

        // Simulate entering full-screen
        controller.isFullScreenActive = { true }
        controller.handleActiveSpaceOrAppChange()
        XCTAssertFalse(controller.model.isExpanded)

        // Simulate returning to desktop
        controller.isFullScreenActive = { false }
        controller.handleActiveSpaceOrAppChange()
        XCTAssertTrue(controller.model.isExpanded, "Always-on notch should unfold again when leaving full screen")
    }
}
