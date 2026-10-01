import XCTest

class TestPath: XCTestCase {
    func testPrintPath() {
        print("PATH IS: \(#filePath)")
        print("URL IS: \(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Sources/Localizable.xcstrings").standardizedFileURL.path)")
    }
}
