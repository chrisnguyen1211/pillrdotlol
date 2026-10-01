import AppKit
import CoreGraphics

/// Whether Liquid Glass can see what is under the pill.
///
/// Glass in this panel refracts the app windows behind it — anyone's — but
/// not the desktop: over the wallpaper, the desktop widgets or the Stage
/// Manager strip it has nothing to sample and renders as a flat grey slab.
/// The pill sits on a screen edge, which is exactly where the desktop shows
/// through, so it was glass one moment and a slab the next depending on
/// whether a window happened to be underneath. The notch asks this on its
/// slow poll and, over the desktop, trades the glass for a blur it can see.
enum GlassSightline {
    struct Window: Equatable {
        var pid: pid_t
        var layer: Int
        var alpha: Double
        /// CoreGraphics coordinates: top-left origin on the primary display.
        var bounds: CGRect
    }

    /// Whether every point glass would sample under `rect` lies on a window
    /// it can see. `windows` are the ones below the panel, in any order.
    ///
    /// Only windows at the normal level or above count. The wallpaper, the
    /// desktop icons and the widgets all sit below it, and so does the
    /// desktop Stage Manager draws — none of which glass can see. System
    /// agents drawing at normal level (Stage Manager, the Dock) are left
    /// out by the caller through `blind`. A window that is not drawn at all
    /// — alpha zero, as a one-pixel utility window is — hides nothing.
    static func glassSees(_ rect: CGRect, through windows: [Window], blind: Set<pid_t> = []) -> Bool {
        let seeable = windows.filter { $0.layer >= 0 && $0.alpha > 0.5 && !blind.contains($0.pid) }
        return samples(of: rect).allSatisfy { point in
            seeable.contains { $0.bounds.contains(point) }
        }
    }

    /// Five points down the middle of the long side, clear of the rounded
    /// ends. The middle across the short side, since a folded pill is a few
    /// points deep and part of that may hang past the screen's edge. A card
    /// is broad both ways, and a window can cover half of it: three by three.
    static func samples(of rect: CGRect) -> [CGPoint] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        if min(rect.width, rect.height) >= gridFrom {
            let steps: [CGFloat] = [0.15, 0.5, 0.85]
            return steps.flatMap { y in
                steps.map { x in CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
            }
        }
        let vertical = rect.height >= rect.width
        return [0.1, 0.3, 0.5, 0.7, 0.9].map { fraction in
            vertical
                ? CGPoint(x: rect.midX, y: rect.minY + rect.height * fraction)
                : CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
        }
    }

    /// Broader than any pill, even open, is deep; narrower than any card.
    static let gridFrom: CGFloat = 120

    /// Agents that draw at the normal window level without being anything
    /// glass can see through to.
    private static let blindBundles: Set<String> = [
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
    ]

    /// Asks WindowServer about the windows under `windowNumber`. Only the
    /// windows' bounds and levels are read — nothing that needs screen
    /// recording.
    static func glassSees(_ rect: CGRect, below windowNumber: Int) -> Bool {
        guard windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements],
                                                    CGWindowID(windowNumber)) as? [[String: Any]]
        else { return true }
        var windows: [Window] = []
        var blind: Set<pid_t> = []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            windows.append(Window(pid: pid, layer: layer, alpha: alpha, bounds: bounds))
            if !blind.contains(pid), isBlind(pid) { blind.insert(pid) }
        }
        return glassSees(rect, through: windows, blind: blind)
    }

    private static func isBlind(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        if let bundle = app.bundleIdentifier, blindBundles.contains(bundle) { return true }
        return false
    }
}
