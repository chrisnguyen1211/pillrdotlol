import XCTest
@testable import LidEffort

/// The permission a person grants by clicking "Allow access…": one read may
/// show the keychain dialogue, and nothing on a timer ever may.
final class PromptPermissionTests: XCTestCase {
    func testNothingIsOwedUntilSomebodyAsks() {
        XCTAssertFalse(PromptPermission().take())
    }

    func testAskingOwesExactlyOneRead() {
        let permission = PromptPermission()
        permission.grant()
        XCTAssertTrue(permission.take())
        XCTAssertFalse(permission.take(), "a second read spent the same click")
    }

    /// A click whose refresh never reached the keychain must not be spent by
    /// some poll much later — the dialogue would then appear on a timer.
    func testAnUnspentPermissionLapses() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let permission = PromptPermission(now: { clock.now })
        permission.grant()
        clock.now = clock.now.addingTimeInterval(PromptPermission.window + 1)
        XCTAssertFalse(permission.take())
    }
}

/// Antigravity's keychain item is written through Go's keyring, which files it
/// with `/usr/bin/security` — so it is refused the same way Claude Code's is,
/// and on a five-minute retry the dialogue kept coming back. Only a person's
/// click may make a read interactive.
final class AntigravityKeychainPromptTests: XCTestCase {
    private var interactive: [Bool] = []

    override func setUp() {
        super.setUp()
        interactive = []
        AntigravityCredentials.forgetCached()
        AntigravityCredentials.readKeychainForTesting = { [unowned self] flag in
            interactive.append(flag)
            return (errSecItemNotFound, nil)
        }
    }

    override func tearDown() {
        AntigravityCredentials.readKeychainForTesting = nil
        AntigravityCredentials.forgetCached()
        super.tearDown()
    }

    func testABackgroundReadNeverPrompts() {
        _ = try? AntigravityCredentials.load()
        XCTAssertEqual(interactive.first, false)
    }

    func testAllowAccessLetsTheNextReadPromptAndNoMore() {
        AntigravityCredentials.askAgain()
        _ = try? AntigravityCredentials.load()
        AntigravityCredentials.forgetCached()
        _ = try? AntigravityCredentials.load()
        XCTAssertEqual(interactive, [true, false])
    }
}
