import LidEffortCore
import SwiftUI

// MARK: - Over the screen

/// The marker doodles drawn over the whole screen: an arrow from the note to
/// what it is about, a loop round the pill, sparkles when something works,
/// and — for "anywhere" — arrows out to every edge.
struct TourDoodles: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        GeometryReader { _ in
            ZStack {
                doodles
                    // Drawn afresh for every step and every cheer, so each
                    // arrives by being drawn rather than by appearing.
                    .id(tour.step.rawValue)
                if let result = tour.result, let rect = result.rect {
                    TourResultCard(result: result, edge: tour.edge)
                        .frame(width: body(of: local(rect)).width, height: body(of: local(rect)).height)
                        .position(x: body(of: local(rect)).midX, y: body(of: local(rect)).midY)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
    }

    /// A prompt card's rect less the gap and tail on the pill's side: the
    /// card itself.
    private func body(of rect: CGRect) -> CGRect {
        let inset = tour.resultTailInset
        switch tour.edge {
        case .right:  return CGRect(x: rect.minX, y: rect.minY, width: rect.width - inset, height: rect.height)
        case .left:   return CGRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset, height: rect.height)
        case .top:    return CGRect(x: rect.minX, y: rect.minY + inset, width: rect.width, height: rect.height - inset)
        case .bottom: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - inset)
        }
    }

    /// Screen coordinates (y up) to this view's (y down).
    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - tour.screenFrame.minX, y: tour.screenFrame.maxY - p.y)
    }

    private func local(_ r: CGRect) -> CGRect {
        let o = local(CGPoint(x: r.minX, y: r.maxY))
        return CGRect(x: o.x, y: o.y, width: r.width, height: r.height)
    }

    @ViewBuilder private var doodles: some View {
        let card = local(tour.cardFrame)
        let seed = UInt64(tour.step.rawValue * 31 + 5)
        if let anchorRect = tour.anchor.map(local) {
            let tip = nearestPoint(on: anchorRect.insetBy(dx: -12, dy: -12), toward: card)
            let tail = nearestPoint(on: card.insetBy(dx: -10, dy: -10), toward: anchorRect)
            let arrow = Doodle.arrow(from: tail, to: tip, bend: 0.22, seed: seed)
            MarkerStroke(path: arrow.shaft, since: tour.drawingSince)
            MarkerStroke(path: arrow.head, delay: 0.55, since: tour.drawingSince)
            if tour.step == .hello || tour.step == .anywhere {
                MarkerStroke(path: Doodle.loop(around: anchorRect.insetBy(dx: -26, dy: -26), seed: seed &+ 3),
                             width: 4, delay: 0.3, since: tour.drawingSince)
            }
            if tour.celebration != nil {
                sparkles(around: anchorRect)
            }
        }
        if tour.step == .anywhere && !tour.hasVisitedEveryEdge {
            edgesArrows(from: card)
        }
        if tour.step == .finish || (tour.step == .lid && tour.celebration != nil) {
            sparkles(around: card.insetBy(dx: -30, dy: -30))
        }
    }

    /// "spyx can be anywhere!" — a dashed arrow from the note out to the
    /// middle of each edge it could go to.
    @ViewBuilder private func edgesArrows(from card: CGRect) -> some View {
        let size = tour.screenFrame.size
        let targets: [(NotchEdge, CGPoint)] = [
            (.top, CGPoint(x: size.width / 2, y: 40)),
            (.bottom, CGPoint(x: size.width / 2, y: size.height - 40)),
            (.left, CGPoint(x: 40, y: size.height / 2)),
            (.right, CGPoint(x: size.width - 40, y: size.height / 2)),
        ]
        ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
            if !tour.visitedEdges.contains(target.0) {
                let from = nearestPoint(on: card.insetBy(dx: -14, dy: -14),
                                        toward: CGRect(origin: target.1, size: .zero))
                let arrow = Doodle.arrow(from: from, to: target.1, bend: index % 2 == 0 ? 0.12 : -0.12,
                                         seed: UInt64(90 + index))
                MarkerStroke(path: arrow.shaft, width: 3.5, dash: [10, 9], delay: 0.2 + Double(index) * 0.15,
                             since: tour.drawingSince)
                MarkerStroke(path: arrow.head, width: 3.5, delay: 0.8 + Double(index) * 0.15, since: tour.drawingSince)
            }
        }
    }

    private func sparkles(around rect: CGRect) -> some View {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(-0.08, -0.1, 12), (1.06, 0.05, 16), (0.95, 1.1, 10), (0.02, 1.02, 14)]
        return ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
            let point = CGPoint(x: rect.minX + rect.width * spot.0, y: rect.minY + rect.height * spot.1)
            MarkerStroke(path: Doodle.sparkle(at: point, size: spot.2), width: 3, delay: Double(index) * 0.08,
                         since: tour.cheeredAt)
        }
    }

    /// The point on a rectangle's edge facing another rectangle's centre.
    private func nearestPoint(on rect: CGRect, toward other: CGRect) -> CGPoint {
        let target = CGPoint(x: other.midX, y: other.midY)
        let dx = target.x - rect.midX, dy = target.y - rect.midY
        guard dx != 0 || dy != 0 else { return CGPoint(x: rect.midX, y: rect.midY) }
        let sx = dx == 0 ? .greatestFiniteMagnitude : (rect.width / 2) / abs(dx)
        let sy = dy == 0 ? .greatestFiniteMagnitude : (rect.height / 2) / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: rect.midX + dx * s, y: rect.midY + dy * s)
    }
}

// MARK: - The note

/// The sticky note: a doodle of what this step is about, a line in the
/// tour's hand, a sentence of plain text, and the way on.
struct TourCard: View {
    @ObservedObject var tour: IntroTour

    var body: some View {
        let size = IntroTour.cardSize
        ZStack {
            // Paper, lifted off the screen, a hair off square.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Doodle.paper)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                .padding(10)
            InkStroke(path: Doodle.box(CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24),
                                       radius: 20, seed: 11), width: 1.6, color: Doodle.ink.opacity(0.55))

            VStack(alignment: .leading, spacing: 10) {
                TourIllustration(step: tour.step, tour: tour)
                    .frame(height: 116)
                    .frame(maxWidth: .infinity)
                Text(title)
                    .font(Doodle.hand(tour.step == .anywhere ? 25 : 22))
                    .foregroundStyle(Doodle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Doodle.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                if let celebration = tour.celebration {
                    Text(celebration)
                        .font(Doodle.hand(15))
                        .foregroundStyle(Doodle.ink)
                        .padding(.horizontal, 8)
                        .background(Doodle.marker.opacity(0.75), in: Capsule())
                        .rotationEffect(.degrees(-1.5))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
        .frame(width: size.width, height: size.height)
        .rotationEffect(.degrees(-0.8))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: tour.step)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(IntroTour.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == tour.step ? Doodle.ink : Doodle.ink.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if tour.step == .finish, let before = tour.edgeBeforeTour {
                TourButton(title: L10n.t("Back to \(before.title.lowercased())"), filled: false) { tour.restoreEdge() }
            }
            if tour.step == .anywhere, !tour.hasVisitedEveryEdge || tour.isFlying {
                TourButton(title: tour.isFlying ? L10n.t("Flying…") : L10n.t("Show me"), filled: false) { tour.flyRound() }
                    .disabled(tour.isFlying)
                    .opacity(tour.isFlying ? 0.6 : 1)
            }
            TourButton(title: tour.step == .finish ? L10n.t("Let's go") : L10n.t("Next →"), filled: true) {
                tour.next()
            }
        }
    }

    private var title: String { tour.stepTitle }
    private var text: String { tour.stepText }
}

struct TourButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Doodle.hand(14))
                .foregroundStyle(filled ? Doodle.paper : Doodle.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background {
                    if filled {
                        Capsule().fill(Doodle.ink)
                    } else {
                        Capsule().strokeBorder(Doodle.ink.opacity(0.7), lineWidth: 1.5)
                    }
                }
                .scaleEffect(hovered ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
    }
}

// MARK: - The drawings

/// A doodle of what each step is about, in ink on the note — the pill as
/// it sits on a screen's right edge, the note it slides out, the lid.
struct TourIllustration: View {
    let step: IntroTour.Step
    @ObservedObject var tour: IntroTour

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                draw(in: &canvas, size: size, t: t)
            }
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let ink = GraphicsContext.Shading.color(Doodle.ink)
        let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        let w = size.width, h = size.height
        switch step {
        case .sessions:
            // A list of sessions, each with its state: working, waiting, done.
            let card = CGRect(x: w * 0.2, y: 8, width: w * 0.6, height: h - 16)
            canvas.stroke(Doodle.box(card, radius: 12, seed: 17), with: ink, style: style)
            let states: [Color] = [Doodle.blue, .orange, Doodle.green]
            for row in 0..<3 {
                let y = card.minY + 26 + CGFloat(row) * 28
                let pulse = row == 0 ? 0.6 + 0.4 * sin(t * 5) : 1
                canvas.fill(Path(ellipseIn: CGRect(x: card.minX + 16, y: y - 5, width: 10, height: 10)),
                            with: .color(states[row].opacity(pulse)))
                canvas.stroke(Doodle.line([CGPoint(x: card.minX + 34, y: y), CGPoint(x: card.maxX - 30 - CGFloat(row) * 18, y: y)],
                                          seed: UInt64(50 + row), wobble: 0.6),
                              with: .color(Doodle.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            let point = CGPoint(x: card.maxX - 26, y: card.minY + 26 + CGFloat(Int(t / 1.4) % 3) * 28 + 6)
            canvas.draw(Text("👆").font(.system(size: 18)), at: point)
        case .hello, .done, .approval, .question:
            // A screen with the pill on its right edge, eye inside.
            let screen = CGRect(x: w * 0.16, y: 6, width: w * 0.68, height: h - 12)
            canvas.stroke(Doodle.box(screen, radius: 14, seed: 3), with: ink, style: style)
            let pill = CGRect(x: screen.maxX - 34, y: screen.midY - 38, width: 26, height: 76)
            canvas.fill(Path(roundedRect: pill, cornerRadius: 13), with: ink)
            let look = sin(t * 1.6) * 3
            canvas.fill(Path(ellipseIn: CGRect(x: pill.midX - 8, y: pill.midY - 8, width: 16, height: 16)),
                        with: .color(Doodle.blue))
            canvas.fill(Path(ellipseIn: CGRect(x: pill.midX - 4 - 2 + look, y: pill.midY - 4, width: 8, height: 8)),
                        with: .color(.black))
            switch step {
            case .hello:
                let bubble = CGRect(x: pill.minX - 74, y: pill.minY - 18, width: 58, height: 30)
                canvas.stroke(Doodle.box(bubble, radius: 12, seed: 8), with: ink, style: style)
                canvas.draw(Text("hi!").font(Doodle.hand(16)).foregroundColor(Doodle.ink),
                            at: CGPoint(x: bubble.midX, y: bubble.midY))
            case .done:
                let slide = CGFloat((sin(t * 1.4) + 1) / 2) * 10
                let note = CGRect(x: pill.minX - 112 - slide, y: pill.midY - 18, width: 96, height: 36)
                canvas.stroke(Doodle.box(note, radius: 10, seed: 9), with: ink, style: style)
                canvas.stroke(Doodle.line([CGPoint(x: note.minX + 12, y: note.midY), CGPoint(x: note.minX + 19, y: note.midY + 7),
                                           CGPoint(x: note.minX + 31, y: note.midY - 8)], seed: 2, wobble: 0.4),
                              with: .color(Doodle.green), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                canvas.draw(Text("done").font(Doodle.hand(14)).foregroundColor(Doodle.ink),
                            at: CGPoint(x: note.midX + 12, y: note.midY))
            case .approval:
                let card = CGRect(x: pill.minX - 150, y: screen.minY + 14, width: 134, height: h - 40)
                canvas.stroke(Doodle.box(card, radius: 10, seed: 12), with: ink, style: style)
                canvas.draw(Text("$ npm run build").font(.system(size: 10, design: .monospaced)).foregroundColor(Doodle.ink),
                            at: CGPoint(x: card.midX, y: card.minY + 20))
                let allow = CGRect(x: card.midX + 4, y: card.maxY - 30, width: 54, height: 20)
                let deny = CGRect(x: card.minX + 10, y: card.maxY - 30, width: 50, height: 20)
                let pulse = 0.75 + 0.25 * sin(t * 4)
                canvas.fill(Path(roundedRect: allow, cornerRadius: 10), with: .color(Doodle.blue.opacity(pulse)))
                canvas.draw(Text("Allow").font(Doodle.hand(12)).foregroundColor(.white), at: CGPoint(x: allow.midX, y: allow.midY))
                canvas.stroke(Doodle.box(deny, radius: 10, seed: 13), with: ink, style: StrokeStyle(lineWidth: 1.6))
                canvas.draw(Text("Deny").font(Doodle.hand(12)).foregroundColor(Doodle.ink), at: CGPoint(x: deny.midX, y: deny.midY))
            default:
                let card = CGRect(x: pill.minX - 150, y: screen.minY + 12, width: 134, height: h - 36)
                canvas.stroke(Doodle.box(card, radius: 10, seed: 14), with: ink, style: style)
                canvas.draw(Text("?").font(Doodle.hand(22)).foregroundColor(Doodle.ink),
                            at: CGPoint(x: card.minX + 18, y: card.minY + 18))
                let picked = Int(t / 1.2) % 3
                for row in 0..<3 {
                    let y = card.minY + 40 + CGFloat(row) * 18
                    let dot = CGRect(x: card.minX + 14, y: y - 5, width: 10, height: 10)
                    canvas.stroke(Path(ellipseIn: dot), with: ink, style: StrokeStyle(lineWidth: 1.6))
                    if row == picked {
                        canvas.fill(Path(ellipseIn: dot.insetBy(dx: 2.5, dy: 2.5)), with: .color(Doodle.blue))
                    }
                    canvas.stroke(Doodle.line([CGPoint(x: dot.maxX + 8, y: y), CGPoint(x: card.maxX - 16 - CGFloat(row) * 14, y: y)],
                                              seed: UInt64(20 + row), wobble: 0.6),
                                  with: .color(Doodle.ink.opacity(0.5)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        case .anywhere:
            // The pill running round the screen's edges.
            let screen = CGRect(x: w * 0.2, y: 6, width: w * 0.6, height: h - 12)
            canvas.stroke(Doodle.box(screen, radius: 14, seed: 3), with: ink, style: style)
            // Each side the pill has been to, marked along it in green.
            let sides: [(NotchEdge, CGPoint, CGPoint)] = [
                (.top, CGPoint(x: screen.minX + 22, y: screen.minY - 5), CGPoint(x: screen.maxX - 22, y: screen.minY - 5)),
                (.right, CGPoint(x: screen.maxX + 5, y: screen.minY + 18), CGPoint(x: screen.maxX + 5, y: screen.maxY - 18)),
                (.bottom, CGPoint(x: screen.maxX - 22, y: screen.maxY + 5), CGPoint(x: screen.minX + 22, y: screen.maxY + 5)),
                (.left, CGPoint(x: screen.minX - 5, y: screen.maxY - 18), CGPoint(x: screen.minX - 5, y: screen.minY + 18)),
            ]
            for (side, a, b) in sides where tour.visitedEdges.contains(side) {
                canvas.stroke(Doodle.line([a, b], seed: UInt64(40 + side.rawValue.count), wobble: 0.8),
                              with: .color(Doodle.green), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
            canvas.draw(Text("\(tour.visitedEdges.count)/4").font(Doodle.hand(13)).foregroundColor(Doodle.ink.opacity(0.6)),
                        at: CGPoint(x: screen.maxX + 26, y: screen.minY + 8))
            let lap = (t / 4).truncatingRemainder(dividingBy: 1)
            let point = perimeter(screen.insetBy(dx: 9, dy: 9), at: lap)
            let vertical = abs(point.x - (screen.minX + 9)) < 1 || abs(point.x - (screen.maxX - 9)) < 1
            let pill = vertical ? CGSize(width: 12, height: 40) : CGSize(width: 40, height: 12)
            for trail in 1...4 {
                let back = perimeter(screen.insetBy(dx: 9, dy: 9), at: (lap - Double(trail) * 0.018 + 1).truncatingRemainder(dividingBy: 1))
                canvas.fill(Path(ellipseIn: CGRect(x: back.x - 2, y: back.y - 2, width: 4, height: 4)),
                            with: .color(Doodle.ink.opacity(0.35 - Double(trail) * 0.07)))
            }
            canvas.fill(Path(roundedRect: CGRect(x: point.x - pill.width / 2, y: point.y - pill.height / 2,
                                                 width: pill.width, height: pill.height), cornerRadius: 6), with: ink)
            canvas.draw(Text("zoom!").font(Doodle.hand(15)).foregroundColor(Doodle.ink.opacity(0.7)),
                        at: CGPoint(x: screen.midX, y: screen.midY))
        case .lid:
            drawLaptop(in: &canvas, size: size, t: t)
        case .finish:
            let centre = CGPoint(x: w / 2, y: h / 2)
            for i in 0..<8 {
                let angle = Double(i) / 8 * 2 * .pi + t * 0.3
                let r = 44 + 6 * sin(t * 3 + Double(i))
                let p = CGPoint(x: centre.x + CGFloat(cos(angle) * r), y: centre.y + CGFloat(sin(angle) * r) * 0.8)
                canvas.stroke(Doodle.sparkle(at: p, size: 6 + CGFloat(i % 3) * 2),
                              with: .color(i % 2 == 0 ? Doodle.blue : Doodle.ink), style: StrokeStyle(lineWidth: 2))
            }
            canvas.stroke(Doodle.line([CGPoint(x: centre.x - 20, y: centre.y), CGPoint(x: centre.x - 5, y: centre.y + 15),
                                       CGPoint(x: centre.x + 24, y: centre.y - 18)], seed: 4, wobble: 0.6),
                          with: .color(Doodle.green), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
    }

    /// A MacBook seen side-on, its lid swinging open and shut, the ⌘ key
    /// blinking beside it: the gesture, shown rather than described.
    private func drawLaptop(in canvas: inout GraphicsContext, size: CGSize, t: Double) {
        let ink = GraphicsContext.Shading.color(Doodle.ink)
        let hinge = CGPoint(x: size.width * 0.40, y: size.height - 22)
        let slab: CGFloat = 9
        // The base: a slab.
        let base = CGRect(x: hinge.x - 4, y: hinge.y, width: 132, height: slab)
        canvas.fill(Path(roundedRect: base, cornerRadius: slab / 2), with: .color(Doodle.ink.opacity(0.1)))
        canvas.stroke(Doodle.box(base, radius: slab / 2, seed: 30, wobble: 0.5), with: ink,
                      style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        // The lid, swinging between a little shut and wide open — a slab too,
        // its screen glowing brighter the further it opens.
        let swing = (sin(t * 2.3) + 1) / 2
        let degrees = 58 + swing * 54 // up from the base
        let length: CGFloat = 94
        let lid = Path(roundedRect: CGRect(x: 0, y: -slab, width: length, height: slab), cornerRadius: slab / 2)
            .applying(CGAffineTransform(rotationAngle: -CGFloat(degrees) * .pi / 180)
                .concatenating(CGAffineTransform(translationX: hinge.x, y: hinge.y)))
        canvas.fill(lid, with: .color(Doodle.ink.opacity(0.1)))
        canvas.stroke(lid, with: ink, style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        let angle = CGFloat(degrees) * .pi / 180
        let inward = CGPoint(x: sin(angle) * 3, y: cos(angle) * 3)
        let screenStart = CGPoint(x: hinge.x + cos(angle) * 12 + inward.x, y: hinge.y - sin(angle) * 12 + inward.y)
        let screenEnd = CGPoint(x: hinge.x + cos(angle) * (length - 10) + inward.x, y: hinge.y - sin(angle) * (length - 10) + inward.y)
        canvas.stroke(Path { $0.move(to: screenStart); $0.addLine(to: screenEnd) },
                      with: .color(Doodle.blue.opacity(0.3 + 0.6 * swing)),
                      style: StrokeStyle(lineWidth: 3, lineCap: .round))
        canvas.fill(Path(ellipseIn: CGRect(x: hinge.x - 3.5, y: hinge.y - 3.5, width: 7, height: 7)), with: ink)
        // Motion marks past the lid's edge.
        for k in 0..<2 {
            let r = length + 12 + CGFloat(k) * 8
            var arc = Path()
            arc.addArc(center: hinge, radius: r, startAngle: .degrees(-degrees - 9), endAngle: .degrees(-degrees + 9), clockwise: false)
            canvas.stroke(arc, with: .color(Doodle.ink.opacity(0.45 - Double(k) * 0.15)),
                          style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        // ⌘, blinking while the lid moves.
        let key = CGRect(x: 18, y: size.height / 2 - 20, width: 44, height: 40)
        let held = tour.effortState.armed
        let blink = held ? 1 : 0.45 + 0.55 * (sin(t * 4.6) + 1) / 2
        canvas.fill(Path(roundedRect: key, cornerRadius: 9), with: .color(Doodle.ink.opacity(0.08 + 0.12 * blink)))
        canvas.stroke(Doodle.box(key, radius: 9, seed: 31), with: .color(Doodle.ink.opacity(0.4 + 0.6 * blink)),
                      style: StrokeStyle(lineWidth: 2))
        canvas.draw(Text("⌘").font(.system(size: 20, weight: .semibold)).foregroundColor(Doodle.ink.opacity(0.5 + 0.5 * blink)),
                    at: CGPoint(x: key.midX, y: key.midY))
        canvas.draw(Text("+").font(Doodle.hand(18)).foregroundColor(Doodle.ink.opacity(0.6)),
                    at: CGPoint(x: key.maxX + 16, y: key.midY))
        // Where the level is now.
        let level = tour.effortState.level
        canvas.draw(Text(level.description).font(Doodle.hand(15)).foregroundColor(Doodle.ink),
                    at: CGPoint(x: size.width - 36, y: 16))
        for (i, candidate) in EffortLevel.allCases.enumerated() {
            let bar = CGRect(x: size.width - 70 + CGFloat(i) * 13, y: 30, width: 9, height: 22)
            let on = candidate.rawValue <= level.rawValue
            canvas.fill(Path(roundedRect: bar.insetBy(dx: 0, dy: CGFloat(4 - i) * 2.5), cornerRadius: 3),
                        with: .color(on ? Doodle.blue : Doodle.ink.opacity(0.15)))
        }
    }

    /// A point round a rectangle's edge, 0…1 clockwise from the top-left.
    private func perimeter(_ rect: CGRect, at fraction: Double) -> CGPoint {
        let total = 2 * (rect.width + rect.height)
        var d = CGFloat(fraction) * total
        if d < rect.width { return CGPoint(x: rect.minX + d, y: rect.minY) }
        d -= rect.width
        if d < rect.height { return CGPoint(x: rect.maxX, y: rect.minY + d) }
        d -= rect.height
        if d < rect.width { return CGPoint(x: rect.maxX - d, y: rect.maxY) }
        d -= rect.width
        return CGPoint(x: rect.minX, y: rect.maxY - d)
    }
}

// MARK: - The tour's own tooltip

/// Where a demo prompt was, once it is answered: the notch's own card, dark
/// and quiet, saying what was done and what it would have meant — with a
/// marker note that this was the tour, so nothing went anywhere.
struct TourResultCard: View {
    let result: TourResult
    let edge: NotchEdge
    /// Glass, darkened so the white type holds, for the Liquid Glass tour.
    var glass = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: result.isPositive ? "checkmark.circle.fill" : "arrow.uturn.left.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(result.isPositive ? Doodle.green : Doodle.marker)
                Text(result.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if let detail = result.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
            }
            Text(result.meaning)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if glass {
                Label(L10n.t("Just the tour — nothing was sent"), systemImage: "sparkles")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(GlassTour.glow)
            } else {
                Text(L10n.t("↳ just the tour — nothing was sent"))
                    .font(Doodle.hand(14))
                    .foregroundStyle(Doodle.marker)
                    .rotationEffect(.degrees(-1.5))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if glass {
                // Glass under a dark wash: the type is white, and glass alone
                // over a light window left it unreadable.
                ZStack {
                    // The glow from the card's shape, not the glass's square view.
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.001))
                        .shadow(color: GlassTour.glow.opacity(0.35), radius: 18)
                    GlassSurface(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.62))
                    RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.2))
                }
            } else {
                solid
            }
        }
    }

    private var solid: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(white: 0.09).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}
