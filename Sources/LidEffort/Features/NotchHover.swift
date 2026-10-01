import Combine
import SwiftUI

/// Where the pointer is over the notch's panel, for hover effects.
///
/// SwiftUI's own hover barely reaches in here: the panel never becomes key
/// and ignores the mouse until the pointer is over something it draws, so
/// `onHover` hears about few of the crossings. The window controller
/// already follows the pointer for opening and folding the notch; it hands
/// the position on through this, and only the views that ask are redrawn.
@MainActor
final class NotchPointer: ObservableObject {
    /// Panel-local, top-left origin — SwiftUI's global space in the panel.
    /// Nil when the pointer is not over anything the notch draws.
    @Published private(set) var location: CGPoint?

    func move(to location: CGPoint?) {
        if self.location != location { self.location = location }
    }

    /// Views under the pointer that a click would act on — the controller
    /// shows the pointing hand while there is one.
    @Published private(set) var hands: Set<UUID> = []

    func wantsHand(_ id: UUID, _ wanted: Bool) {
        if wanted { hands.insert(id) } else { hands.remove(id) }
    }
}

extension EnvironmentValues {
    @Entry var notchPointer: NotchPointer? = nil
}

extension View {
    /// Told when the pointer comes onto this view and leaves it.
    func notchHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(NotchHoverModifier(action: action))
    }

    /// Lifts the view when the pointer is on it: a soft plate behind it,
    /// a little larger, a shadow under — it comes forward from the list.
    func hoverLift(cornerRadius: CGFloat = Design.px(18),
                   inset: CGSize = CGSize(width: Design.px(16), height: Design.px(10)),
                   pointingHand: Bool = false) -> some View {
        modifier(HoverLiftModifier(cornerRadius: cornerRadius, inset: inset, pointingHand: pointingHand))
    }
}

private struct NotchHoverModifier: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.notchPointer) private var pointer

    func body(content: Content) -> some View {
        if let pointer {
            content.modifier(Tracked(pointer: pointer, action: action))
        } else {
            content.onHover(perform: action)
        }
    }

    private struct Tracked: ViewModifier {
        @ObservedObject var pointer: NotchPointer
        let action: (Bool) -> Void
        @State private var frame: CGRect = .zero
        @State private var inside = false

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                .onChange(of: pointer.location) { _ in update() }
                .onChange(of: frame) { _ in update() }
        }

        private func update() {
            let now = pointer.location.map { frame.contains($0) } ?? false
            guard now != inside else { return }
            inside = now
            action(now)
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let cornerRadius: CGFloat
    let inset: CGSize
    /// A click on it does something, so it gets the pointing hand.
    let pointingHand: Bool
    @State private var lifted = false
    @State private var id = UUID()
    @Environment(\.notchPointer) private var pointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.textPrimary.opacity(lifted ? 0.09 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Palette.textPrimary.opacity(lifted ? 0.1 : 0), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(lifted ? 0.28 : 0), radius: lifted ? Design.px(18) : 0, y: lifted ? Design.px(6) : 0)
                    .padding(.horizontal, -inset.width)
                    .padding(.vertical, -inset.height)
            }
            .scaleEffect(lifted && !reduceMotion ? 1.025 : 1)
            .offset(y: lifted && !reduceMotion ? -Design.px(2) : 0)
            .zIndex(lifted ? 1 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: lifted)
            .notchHover { inside in
                lifted = inside
                if pointingHand { pointer?.wantsHand(id, inside) }
            }
            .onDisappear { pointer?.wantsHand(id, false) }
    }
}
