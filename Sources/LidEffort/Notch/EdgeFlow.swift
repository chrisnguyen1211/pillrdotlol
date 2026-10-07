import AppKit
import SwiftUI

extension NotchEdge {
    /// Where a click on the move handle sends the notch: all four edges,
    /// clockwise — right, bottom, left, top — the round the tour's Show me
    /// flies. It used to skip the bottom (right went straight to left), so
    /// no number of clicks ever reached it.
    var nextSide: NotchEdge {
        switch self {
        case .right:  return .bottom
        case .bottom: return .left
        case .left:   return .top
        case .top:    return .right
        }
    }
}

/// The path a notch takes from one edge to another: along the bezel and
/// round the corners, never across the middle of the screen. Left to right
/// runs up, over and down — clockwise; the return runs the same corners the
/// other way rather than under the dock. To or from the bottom it goes the
/// shorter way round, clockwise when the two are equal.
///
/// Points are in top-left-origin screen space, half the stroke's depth in
/// from the edges so a stroke of `depth` sits flush with the bezel. Pure, so
/// the route can be checked without a screen.
enum EdgeFlowRoute {
    static func points(from: NotchEdge, at start: CGPoint,
                       to: NotchEdge, at end: CGPoint,
                       size: CGSize, depth: CGFloat) -> [CGPoint] {
        guard from != to else { return [start, end] }
        let half = depth / 2
        // Clockwise from the top left. Walking clockwise, each side ends at
        // the corner after it: the top at the top right, the right side at
        // the bottom right, and so on round.
        let corners = [CGPoint(x: half, y: half),
                       CGPoint(x: size.width - half, y: half),
                       CGPoint(x: size.width - half, y: size.height - half),
                       CGPoint(x: half, y: size.height - half)]
        func endCorner(_ edge: NotchEdge) -> Int {
            switch edge {
            case .left:   return 0
            case .top:    return 1
            case .right:  return 2
            case .bottom: return 3
            }
        }
        // Corner to corner in one direction until the side arrived at.
        func walk(from first: Int, to last: Int, step: Int) -> [CGPoint] {
            var route: [CGPoint] = []
            var corner = first
            while true {
                route.append(corners[corner])
                if corner == last { return route }
                corner = (corner + step + 4) % 4
            }
        }
        let clockwise = [start] + walk(from: endCorner(from), to: (endCorner(to) + 3) % 4, step: 1) + [end]
        let anticlockwise = [start] + walk(from: (endCorner(from) + 3) % 4, to: endCorner(to), step: -1) + [end]
        switch (from, to) {
        case (.left, .right): return clockwise
        case (.right, .left): return anticlockwise
        default:
            return length(of: anticlockwise) < length(of: clockwise) - 0.5 ? anticlockwise : clockwise
        }
    }

    static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The route with its corners rounded: each turn becomes an arc of
    /// `radius`, drawn as short straight legs. A body sampled across a
    /// sharp corner creases where the normal flips; across an arc it
    /// bends, the way a liquid does.
    static func rounded(_ points: [CGPoint], radius: CGFloat) -> [CGPoint] {
        guard points.count > 2, radius > 0 else { return points }
        var result = [points[0]]
        for index in 1..<(points.count - 1) {
            let prev = points[index - 1], corner = points[index], next = points[index + 1]
            let inLeg = hypot(corner.x - prev.x, corner.y - prev.y)
            let outLeg = hypot(next.x - corner.x, next.y - corner.y)
            let r = min(radius, inLeg / 2, outLeg / 2)
            guard r > 0 else { result.append(corner); continue }
            let inDir = CGPoint(x: (corner.x - prev.x) / inLeg, y: (corner.y - prev.y) / inLeg)
            let outDir = CGPoint(x: (next.x - corner.x) / outLeg, y: (next.y - corner.y) / outLeg)
            let from = CGPoint(x: corner.x - inDir.x * r, y: corner.y - inDir.y * r)
            let to = CGPoint(x: corner.x + outDir.x * r, y: corner.y + outDir.y * r)
            // A quadratic through the corner, flattened into legs.
            let legs = 10
            for step in 0...legs {
                let t = CGFloat(step) / CGFloat(legs)
                let a = CGPoint(x: from.x + (corner.x - from.x) * t, y: from.y + (corner.y - from.y) * t)
                let b = CGPoint(x: corner.x + (to.x - corner.x) * t, y: corner.y + (to.y - corner.y) * t)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// The point a fraction of the way along the route, and the unit
    /// tangent there — the direction of travel, for a body drawn across it.
    static func sample(_ points: [CGPoint], at fraction: CGFloat) -> (point: CGPoint, tangent: CGPoint) {
        guard points.count > 1 else { return (points.first ?? .zero, CGPoint(x: 1, y: 0)) }
        let total = length(of: points)
        var remaining = max(0, min(1, fraction)) * total
        for (a, b) in zip(points, points.dropFirst()) {
            let leg = hypot(b.x - a.x, b.y - a.y)
            guard leg > 0 else { continue }
            let tangent = CGPoint(x: (b.x - a.x) / leg, y: (b.y - a.y) / leg)
            if remaining <= leg {
                return (CGPoint(x: a.x + tangent.x * remaining, y: a.y + tangent.y * remaining), tangent)
            }
            remaining -= leg
        }
        let a = points[points.count - 2], b = points[points.count - 1]
        let leg = max(1, hypot(b.x - a.x, b.y - a.y))
        return (b, CGPoint(x: (b.x - a.x) / leg, y: (b.y - a.y) / leg))
    }
}

/// Where the drop is at `progress` of the journey, as fractions of the
/// route: the head leads and the tail follows, so the pill stretches into a
/// stream mid-flight and gathers itself back into a pill as it lands.
enum EdgeFlowMotion {
    static func window(progress: CGFloat, pillFraction: CGFloat) -> (tail: CGFloat, head: CGFloat) {
        let travel = 1 - pillFraction
        let head = pillFraction + travel * ease(min(1, max(0, progress / 0.85)))
        let tail = travel * ease(min(1, max(0, (progress - 0.15) / 0.85)))
        return (tail, head)
    }

    /// Ease in and out, quadratic.
    static func ease(_ x: CGFloat) -> CGFloat {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

/// The body of the drop, from `tail` to `head` along the route: not a
/// stroke of one width but a liquid — a full round head, a body that
/// swells behind it and thins away to a tail, and a ripple running down
/// its length that time keeps moving. Built as an outline: the centreline
/// is sampled along the route and each sample is pushed out both ways by
/// the width the profile gives it there.
struct EdgeFlowShape: Shape {
    let points: [CGPoint]
    var tail: CGFloat
    var head: CGFloat
    let depth: CGFloat
    /// Seconds, for the ripple.
    var time: Double = 0

    /// How liquid the body is, 0 … 1. It sets out as the pill and lands as
    /// the pill — a capsule of one width — and is a liquid only in between,
    /// so the hand-off to and from the real pill has nothing to jump over.
    var liquidity: CGFloat = 1

    /// Half-width at `t` (0 tail, 1 head) as a share of the full depth.
    /// `cap` is how much of the length a round end takes — a real
    /// semicircle, so it is the depth over the body's length rather than a
    /// fixed share, or a long body ends in a point. `liquidity` blends from
    /// the capsule (0) to the liquid's own profile (1).
    static func profile(_ t: CGFloat, time: Double, cap: CGFloat = 0.18, liquidity: CGFloat = 1) -> CGFloat {
        // The capsule: full width, a semicircle at each end.
        var capsule: CGFloat = 1
        if t > 1 - cap { capsule *= sqrt(max(0, 1 - pow((t - (1 - cap)) / cap, 2))) }
        if t < cap { capsule *= sqrt(max(0, 1 - pow((cap - t) / cap, 2))) }

        // The liquid: a thin tail, a body that swells behind a round head,
        // and a ripple down its length.
        let s = t * t * (3 - 2 * t)
        let body = 0.18 + 0.82 * s
        let bulbAt = 1 - cap - 0.1
        let bulb = 0.22 * exp(-pow((t - bulbAt) / 0.14, 2))
        let ripple = 0.08 * sin(Double(t) * 6 * .pi - time * 7) * Double(1 - t)
        var liquid = body + bulb + CGFloat(ripple)
        if t > 1 - cap { liquid *= sqrt(max(0, 1 - pow((t - (1 - cap)) / cap, 2))) }
        let tailCap = cap / 3
        if t < tailCap { liquid *= sqrt(max(0, 1 - pow((tailCap - t) / tailCap, 2))) }

        let mix = min(1, max(0, liquidity))
        return max(0.02, capsule + (liquid - capsule) * mix)
    }

    func path(in rect: CGRect) -> Path {
        guard head > tail, points.count > 1 else { return Path() }
        let route = EdgeFlowRoute.rounded(points, radius: depth * 1.5)
        let bodyLength = max(1, (head - tail) * EdgeFlowRoute.length(of: route))
        // A round end is half a depth long, whatever the body is.
        let cap = min(0.45, (depth / 2) / bodyLength)
        // Dense: an end's semicircle is a small share of a long body and
        // still has to come out round rather than faceted.
        let steps = 140
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let along = tail + (head - tail) * t
            let sample = EdgeFlowRoute.sample(route, at: along)
            let normal = CGPoint(x: -sample.tangent.y, y: sample.tangent.x)
            let half = depth / 2 * Self.profile(t, time: time, cap: cap, liquidity: liquidity)
            left.append(CGPoint(x: sample.point.x + normal.x * half, y: sample.point.y + normal.y * half))
            right.append(CGPoint(x: sample.point.x - normal.x * half, y: sample.point.y - normal.y * half))
        }
        var path = Path()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// The drop in flight.
///
/// It begins as the pill — the same capsule, the same glass and rim, at the
/// same place — melts into a liquid in colour as it travels, and gathers
/// itself back into the pill where it lands, so the real pill can take
/// over underneath a crossfade with nothing to jump over. Colour and glow
/// come and go with the liquidity; the shape blends the same way.
struct EdgeFlowView: View {
    let points: [CGPoint]
    let depth: CGFloat
    let pillFraction: CGFloat
    let duration: TimeInterval
    let start: Date
    let glassy: Bool

    /// How long the drop lingers, fading, once it has landed — the real
    /// pill fades in underneath it over the same time.
    static let handoff: TimeInterval = 0.3

    /// 0 at either end of the journey, 1 through the middle.
    static func liquidity(at progress: CGFloat) -> CGFloat {
        func ease(_ x: CGFloat) -> CGFloat { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        return ease(progress / 0.28) * ease((1 - progress) / 0.32)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSince(start)
            let progress = CGFloat(min(1, max(0, seconds / duration)))
            let liquidity = Self.liquidity(at: progress)
            let window = EdgeFlowMotion.window(progress: progress, pillFraction: pillFraction)
            let shape = EdgeFlowShape(points: points, tail: window.tail, head: window.head,
                                      depth: depth, time: seconds, liquidity: liquidity)
            let hues = LinearGradient(colors: MagicFlow.hues + MagicFlow.hues,
                                      startPoint: UnitPoint(x: -1 + Double(progress) * 2, y: 0),
                                      endPoint: UnitPoint(x: 1 + Double(progress) * 2, y: 1))
            let landed = max(0, seconds - duration)
            ZStack {
                // The glow first, so it sits behind the body and spills past
                // its edge. Only while liquid.
                if liquidity > 0.01 {
                    shape.fill(Color.white.opacity(0.5 * liquidity))
                        .blur(radius: depth * 0.6)
                }

                // The pill's own material, so the ends match it exactly.
                if glassy {
                    if #available(macOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    }
                } else {
                    shape.fill(Palette.notch)
                }

                // The liquid over it, coming and going with the liquidity.
                shape.fill(Palette.notch).opacity(0.9 * liquidity)
                shape.fill(hues).opacity(0.9 * liquidity)
                shape.fill(LinearGradient(colors: [.white.opacity(0.55), .clear, .clear],
                                          startPoint: .top, endPoint: .bottom))
                    .opacity(liquidity)

                // The pill's rim — dark outside, light inside — and the
                // liquid's brighter edge over it as it melts.
                shape.stroke(Color.black.opacity(0.45), lineWidth: NotchLayout.hairline * 1.5)
                shape.stroke(Color.white.opacity(0.6 + 0.2 * liquidity), lineWidth: NotchLayout.hairline * 0.75)

                // Droplets shed behind the tail, smaller and fainter the
                // further back — a liquid leaves some of itself behind.
                // They fade with the liquidity rather than popping.
                ForEach(0..<3, id: \.self) { index in
                    let lag = CGFloat(index + 1) * 0.035 * (1 - pillFraction)
                    let at = window.tail - lag
                    let sample = EdgeFlowRoute.sample(points, at: max(0, at))
                    let size = depth * (0.42 - CGFloat(index) * 0.1)
                    Circle()
                        .fill(hues)
                        .frame(width: size, height: size)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                        .opacity(at > 0 ? (0.9 - Double(index) * 0.25) * Double(liquidity) : 0)
                        .position(sample.point)
                }
            }
            // Once landed, out from over the real pill.
            .opacity(1 - min(1, landed / Self.handoff))
        }
        .ignoresSafeArea()
    }
}

/// The full-screen surface the drop runs on.
///
/// Its own window, the way the drop zones were: the notch panel is a strip
/// welded to one edge and the drop has to cross to another. Click-through,
/// short-lived, and at the notch's own level so it is what the eye follows
/// while the panel itself is hidden.
@MainActor
final class EdgeFlowOverlay {
    private var window: NSPanel?

    /// Runs the drop; `landed` fires the moment it arrives, while it is
    /// still on screen fading, so the real pill can fade in under it.
    func run(on screen: NSScreen, points: [CGPoint], depth: CGFloat, pillFraction: CGFloat,
             duration: TimeInterval, glassy: Bool, landed: @escaping @MainActor () -> Void) {
        let frame = screen.frame
        let view = EdgeFlowView(points: points, depth: depth, pillFraction: pillFraction,
                                duration: duration, start: Date(), glassy: glassy)
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        window = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            MainActor.assumeIsolated { landed() }
        }
        // The window itself is held here, not reached through `self`: the
        // notch lets go of the overlay the moment the pill is back — before
        // this fires — and through a weak `self` the window was never taken
        // down. Each edge change left a full-screen window behind, still
        // animating, and the notch grew slower with every move.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + EdgeFlowView.handoff + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                // Its animation stops with its content, not with the window
                // going off screen.
                panel.contentView = nil
                if self?.window === panel { self?.window = nil }
            }
        }
    }
}
