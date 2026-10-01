import AppKit
import SwiftUI

/// The desktop behind the panel, blurred, brought *into* the window.
///
/// Liquid Glass bends and blurs what lies behind it within its own window.
/// This panel is transparent, so behind the glass there was nothing, and
/// glass over nothing renders as a dense grey slab — the pill that never
/// looked like the system's own capsule. An `NSVisualEffectView` blending
/// behind the window is the one thing that can sample the screen under a
/// panel; put under the glass, cut to the same shape, it gives the glass
/// the blurred desktop to refract, and the pill sees through.
///
/// Cut with a mask *image* rather than a layer mask: a behind-window
/// effect view ignores layer masks, and a clipped one still blurred its
/// whole rectangle.
struct GlassBackdrop<S: Shape>: NSViewRepresentable {
    let shape: S
    /// The most see-through of the adaptive materials: light frost on a
    /// light Mac, dark on a dark one, and the screen behind it plainly
    /// blurred through either. The HUD material was a grey slab in light.
    var material: NSVisualEffectView.Material = .underWindowBackground
    /// How much of the frost shows, 0…1. The material's own tint is what
    /// makes the pill read as a slab; at half strength the screen behind
    /// comes through and the glass on top still has something to bend.
    var frost: CGFloat = 1
    /// How much of the material's own colour shows over its blur, 0…1.
    /// Unlike `frost`, which fades the blur and the colour together — and
    /// so lets the sharp screen through — this keeps the blur whole and
    /// thins only the tint: at a tenth it is close to clear glass. It is
    /// what stands in for the glass where the glass cannot see.
    var tint: CGFloat = 1

    func makeNSView(context: Context) -> ShapedEffectView {
        let view = ShapedEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        view.isEmphasized = false
        view.alphaValue = frost
        view.tint = Float(tint)
        view.path = { rect in shape.path(in: rect).cgPath }
        return view
    }

    func updateNSView(_ view: ShapedEffectView, context: Context) {
        view.material = material
        view.tint = Float(tint)
        if context.transaction.animation != nil, !context.transaction.disablesAnimations,
           abs(view.alphaValue - frost) > 0.001 {
            NSAnimationContext.runAnimationGroup { group in
                group.duration = ChromeGlassMotion.crossfade
                view.animator().alphaValue = frost
            }
        } else {
            view.alphaValue = frost
        }
        view.path = { rect in shape.path(in: rect).cgPath }
        view.needsLayout = true
    }

    final class ShapedEffectView: NSVisualEffectView {
        var path: ((CGRect) -> CGPath)?
        private var maskedSize: CGSize = .zero
        var tint: Float = 1 {
            didSet { if tint != oldValue { applyTint() } }
        }

        /// The material is a blur with two colour layers over it, `fill`
        /// and `tone`; the tint is their opacity. AppKit puts them back to
        /// full whenever it refreshes the material, so it is laid on again
        /// after each of its passes. Should a later macOS name them
        /// differently, nothing matches and the material keeps its own
        /// tint — frostier, never broken.
        private func applyTint() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for material in layer?.sublayers ?? [] {
                for sublayer in material.sublayers ?? [] where sublayer.name == "fill" || sublayer.name == "tone" {
                    sublayer.opacity = tint
                }
            }
            CATransaction.commit()
        }

        override func updateLayer() {
            super.updateLayer()
            applyTint()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyTint()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The material's layers are built on the way into the window,
            // after this returns.
            DispatchQueue.main.async { [weak self] in self?.applyTint() }
        }

        override func layout() {
            super.layout()
            applyTint()
            guard bounds.size != maskedSize, bounds.width > 0, bounds.height > 0, let path else { return }
            maskedSize = bounds.size
            let size = bounds.size
            maskImage = NSImage(size: size, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.addPath(path(rect))
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
                return true
            }
        }
    }
}

/// Liquid Glass where it can see what is under it; over the desktop, where
/// it cannot and would render a grey slab, the blurred screen itself with
/// its tint thinned to `frost`. `GlassSightline` decides which, and the two
/// crossfade. The backdrop under the glass keeps the frost it has always
/// had there.
@available(macOS 26.0, *)
struct AdaptiveGlass<S: Shape>: View {
    let shape: S
    let glass: Glass
    let frost: CGFloat
    let sees: Bool
    /// The tint over the desktop, when it should be heavier than `frost`.
    var fallbackTint: CGFloat? = nil

    var body: some View {
        ZStack {
            GlassBackdrop(shape: shape, frost: sees ? frost : 1, tint: sees ? 1 : (fallbackTint ?? frost))
            Color.clear.glassEffect(glass, in: shape)
                .opacity(sees ? 1 : 0)
        }
        .animation(.easeInOut(duration: ChromeGlassMotion.crossfade), value: sees)
    }
}

/// The chrome's glass — the pill and the orbs on it: clear, at the
/// transparency setting.
@available(macOS 26.0, *)
struct ChromeGlass<S: Shape>: View {
    let shape: S
    var glass: Glass = .clear

    @Environment(\.pillFrost) private var frost
    @Environment(\.glassSeesBehind) private var sees

    var body: some View {
        AdaptiveGlass(shape: shape, glass: glass, frost: frost, sees: sees)
    }
}

/// The cards' glass: regular, and never thinner than the cards' own frost
/// floor, since they carry text. Its sightline is the cards' own — a card
/// can hang over a window while the pill sits over the desktop.
@available(macOS 26.0, *)
struct CardGlass<S: Shape>: View {
    let shape: S
    static var readableTint: CGFloat { 0.85 }

    @Environment(\.pillFrost) private var frost
    @Environment(\.cardGlassSeesBehind) private var sees

    var body: some View {
        // Over the desktop the blur is of a wallpaper, often dark; a light
        // card at half tint came out mid-grey, and grey text on it could
        // not be read. Text first: nearly the whole tint, whatever the
        // transparency setting says.
        AdaptiveGlass(shape: shape, glass: .regular, frost: NotchLayout.cardFrost(frost), sees: sees,
                      fallbackTint: max(NotchLayout.cardFrost(frost), CardGlass<S>.readableTint))
    }
}

enum ChromeGlassMotion {
    /// Glass to blur and back: long enough to read as the surface changing
    /// rather than flickering, short enough to keep up with a window moved
    /// out from under the pill.
    static let crossfade: TimeInterval = 0.35
}
