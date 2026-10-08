import XCTest
@testable import LidEffort

/// 1.1.1 died at launch on every Mac but the one that built it: `L10n` read
/// `Bundle.module`, whose generated accessor only knows the app's root and
/// the builder's `.build` folder, and calls `fatalError` when neither holds
/// the resource bundle.
final class ResourceBundleTests: XCTestCase {
    func testTheResourceBundleHoldsTheCatalogs() {
        XCTAssertNotNil(Bundle.appResources.url(forResource: "Assets", withExtension: "xcassets"))
        XCTAssertNotNil(Bundle.appResources.url(forResource: "LobeIcons-LICENSE", withExtension: "txt"))
        XCTAssertTrue(L10n.bundle === Bundle.appResources)
    }

    func testNoAppCodeReachesForBundleModule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LidEffort")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "ResourceBundle.swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
            if code.contains("Bundle.module") { offenders.append(file.lastPathComponent) }
        }
        XCTAssertGreaterThan(sources.path.count, 0)
        XCTAssertEqual(offenders, [], "use Bundle.appResources: Bundle.module crashes outside the build Mac")
    }
}
