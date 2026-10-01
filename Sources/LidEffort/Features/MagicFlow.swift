import SwiftUI

/// The colours a thing takes when it is flowing: a bar at the top of its
/// scale, the notch running round the bezel. Bright and several, so a flow
/// reads as a flow and not as a highlight that happens to move.
enum MagicFlow {
    static let hues: [Color] = [
        Color(hex: 0x7C5CFF),   // violet
        Color(hex: 0xFF5CA8),   // pink
        Color(hex: 0xFFB65C),   // amber
        Color(hex: 0x5CE1FF),   // cyan
        Color(hex: 0x7C5CFF),   // and round again
    ]

    /// The hues laid along a line, for a shape that spans one.
    static func gradient(from start: UnitPoint = .leading, to end: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(colors: hues, startPoint: start, endPoint: end)
    }

    /// Liquid running left to right through a capsule of the given size:
    /// the hues slide along it, a wave rolls over its surface, and a bright
    /// drop leads the way — the bar is a channel with something flowing in
    /// it, not a pipe lit from inside.
    struct Stream: View {
        let width: CGFloat
        let height: CGFloat
        var period: Double = 1.8

        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((seconds / period).truncatingRemainder(dividingBy: 1))
                let head = max(height * 1.3, width * 0.16)
                ZStack(alignment: .leading) {
                    // Twice the width so the seam is never in view: as the
                    // phase runs the gradient slides right by one width.
                    LinearGradient(colors: hues + hues, startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 2, height: height)
                        .offset(x: -width + width * phase)

                    // The surface: a wave of light rolling along the top,
                    // and its shadow under it, so the liquid has a depth.
                    Wave(phase: CGFloat(seconds * 2.2), amplitude: height * 0.22,
                         wavelength: max(height * 3, width / 3), crest: 0.42)
                        .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: width, height: height)
                    Wave(phase: CGFloat(seconds * 2.2) + .pi, amplitude: height * 0.18,
                         wavelength: max(height * 3, width / 3), crest: 0.8)
                        .fill(Color.black.opacity(0.28))
                        .frame(width: width, height: height)

                    // The leading drop: rounder than the channel, glowing.
                    Ellipse()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: head, height: height * 0.9)
                        .blur(radius: height * 0.12)
                        .shadow(color: .white.opacity(0.9), radius: height * 0.7)
                        .offset(x: -head + (width + head) * phase, y: 0)
                }
                .frame(width: width, height: height, alignment: .leading)
                .clipShape(Capsule())
            }
        }
    }

    /// Everything above a sine surface, so a fill through it reads as a
    /// crest of light (or a trough of shade) rolling across the liquid.
    struct Wave: Shape {
        var phase: CGFloat
        var amplitude: CGFloat
        var wavelength: CGFloat
        /// Where the surface sits, as a share of the height from the top.
        var crest: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let baseline = rect.minY + rect.height * crest
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            let steps = max(8, Int(rect.width / 3))
            for i in 0...steps {
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
                let y = baseline + amplitude * sin(x / wavelength * 2 * .pi - phase)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }
}
