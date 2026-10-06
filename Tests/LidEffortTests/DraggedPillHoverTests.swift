import XCTest
@testable import LidEffort

private struct TestScreen: ScreenDescribing {
    var frameValue: CGRect
    var visibleFrameValue: CGRect { frameValue }
}

@MainActor
final class DragOvershootTests: XCTestCase {
    func testTheOffsetIsTheInverseOfThePlacement() {
        let screen = CGRect(x: 0, y: -1200, width: 1920, height: 1200)
        for edge in [NotchEdge.left, .right, .top, .bottom] {
            for offset in [CGFloat(-200), 0, 150] {
                let frame = NotchGeometry.panelFrame(for: TestScreen(frameValue: screen), panelSize: CGSize(width: 300, height: 600),
                                                     edge: edge, alongOffset: offset)
                XCTAssertEqual(NotchWindowController.alongOffset(of: frame, on: screen, edge: edge), offset, accuracy: 0.5, "\(edge)")
            }
        }
    }
}
