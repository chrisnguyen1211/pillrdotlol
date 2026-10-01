import SwiftUI

/// The four places the notch can land, shown while one is being carried.
///
/// Drawn as the notch's own outline rather than as a generic rectangle: the
/// shape differs per edge — a side edge is a tall pill, a horizontal one is a
/// wide bar — and showing the real silhouette is what makes the choice legible
/// before you commit to it.
///
/// All four are always visible while carrying, and the one under the pointer
/// grows and solidifies. Showing only the nearest would mean discovering the
/// other three by sweeping the pointer around, which is the thing a preview is
/// supposed to save you from.
struct EdgeDropZones: View {
    /// Which zone the pointer is currently over, if any.
    let target: NotchEdge?
    /// The screen this is covering, in its own local coordinates.
    let size: CGSize
    /// The notch's resting footprint, so a zone is the size the notch will
    /// actually be rather than a guess.
    let restingDepth: CGFloat
    let restingLength: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long dashes with a clear gap. Short ones blur into a solid line at the
    /// length these outlines run — a bottom zone is most of the screen wide.
    private static let dash: [CGFloat] = [Design.px(34), Design.px(26)]
    /// Heavy enough to read as a deliberate outline from across the screen.
    /// The first version was drawn at 10 and vanished against a busy desktop.
    private static let stroke: CGFloat = Design.px(16)
    /// The unselected zones are quiet but never faint: all four have to be
    /// legible the moment the handle is held, since seeing the options is the
    /// whole point of showing them before the pointer arrives.
    private static let restingOpacity: CGFloat = 0.72

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(NotchEdge.allCases) { edge in
                zone(edge)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func zone(_ edge: NotchEdge) -> some View {
        let isTarget = edge == target
        let frame = frame(for: edge)
        return SideNotchShape(edge: edge, hanging: !edge.isVertical)
            .stroke(
                Palette.textPrimary.opacity(isTarget ? 1 : Self.restingOpacity),
                style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round, dash: Self.dash)
            )
            // A dark wash inside every zone, deeper on the target. It is what
            // separates a dashed outline from the wallpaper behind it — a
            // stroke alone disappears over a light or busy desktop, which is
            // exactly where you most need to see where the notch can go.
            .background(
                SideNotchShape(edge: edge, hanging: !edge.isVertical)
                    .fill(Palette.notch.opacity(isTarget ? 0.62 : 0.3))
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            // The target swells slightly. Scaled about its own centre, which
            // for a zone welded to an edge pushes it a few points off the
            // bezel — deliberate: it reads as lifting toward the pointer.
            .scaleEffect(isTarget ? 1.06 : 1)
            .animation(
                NotchMotion.respectingReduceMotion(
                    .spring(response: 0.3, dampingFraction: 0.75), reduceMotion
                ),
                value: isTarget
            )
    }

    /// Where a zone sits, welded to its own edge and centred along it.
    ///
    /// A side edge takes the resting length down the screen; a horizontal one
    /// turns that on its side, for the same reason the real notch does — four
    /// cells stacked vertically off the menu bar would reach a quarter of the
    /// way down the screen.
    private func frame(for edge: NotchEdge) -> CGRect {
        switch edge {
        case .right:
            return CGRect(x: size.width - restingDepth,
                          y: (size.height - restingLength) / 2,
                          width: restingDepth, height: restingLength)
        case .left:
            return CGRect(x: 0,
                          y: (size.height - restingLength) / 2,
                          width: restingDepth, height: restingLength)
        case .top:
            return CGRect(x: (size.width - restingLength) / 2,
                          y: 0,
                          width: restingLength, height: restingDepth)
        case .bottom:
            return CGRect(x: (size.width - restingLength) / 2,
                          y: size.height - restingDepth,
                          width: restingLength, height: restingDepth)
        }
    }

    /// The edge whose zone contains `point`, or the nearest one within reach.
    ///
    /// Nearest-edge rather than strict hit testing: the zones are thin, and
    /// requiring the pointer to land inside a 40pt strip would make dropping
    /// feel like threading a needle. The screen is split into four triangles
    /// about its centre, so every point on it belongs to exactly one edge.
    static func edge(at point: CGPoint, in size: CGSize) -> NotchEdge {
        let dxLeft = point.x
        let dxRight = size.width - point.x
        let dyTop = point.y
        let dyBottom = size.height - point.y
        let nearest = min(dxLeft, dxRight, dyTop, dyBottom)
        if nearest == dxRight { return .right }
        if nearest == dxLeft { return .left }
        if nearest == dyTop { return .top }
        return .bottom
    }
}
