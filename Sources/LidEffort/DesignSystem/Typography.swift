import AppKit
import SwiftUI

/// The notch's type scale.
///
/// Taken from the approval card's: SF Pro throughout, only two weights —
/// regular for what is read, medium for what names or labels — and sizes
/// that step 14 / 13 / 12.5 / 12 around the body. Here the steps keep
/// those proportions at the notch's own body size, which is derived from
/// cap heights measured in the design frame and so tracks `Design.scale`
/// along with everything else. Nothing is semibold or bold any more: the
/// hierarchy is carried by size and colour, the way the card carries it.
enum Typography {
    /// The body's point size; every other step is a proportion of it.
    static let bodySize = Design.fontSize(capPixels: 18)

    /// A step on the card's scale — 13 is the body.
    static func size(_ step: CGFloat) -> CGFloat { bodySize * step / 13 }

    /// The percent under each provider ring. Cap height 27px in the frame.
    static let percent = Font.system(size: Design.fontSize(capPixels: 27), weight: .medium)

    /// "Claude Usage", "Needs your OK". Cap height 26px.
    static let cardTitle = Font.system(size: Design.fontSize(capPixels: 26), weight: .medium)

    /// A question, or what a permission is for: 14, medium.
    static let heading = Font.system(size: size(14), weight: .medium)
    static let headingNSFont = NSFont.systemFont(ofSize: size(14), weight: .medium)

    /// "Current session", "73% Used", an option's label: 13, regular.
    static let cardBody = Font.system(size: bodySize, weight: .regular)

    /// A section's name within a card — "Sessions", "Effort": 13, medium.
    static let cardLabel = Font.system(size: bodySize, weight: .medium)

    /// Buttons and pills: 12.5, medium.
    static let control = Font.system(size: size(12.5), weight: .medium)

    /// Counters and steps — "1 / 3", "2/2": 12, medium, digits that do not
    /// shift as they change.
    static let counter = Font.system(size: size(12), weight: .medium).monospacedDigit()

    /// What an option means, beside it: 12, regular.
    static let detail = Font.system(size: size(12), weight: .regular)

    /// A running clock — "12.3s": 12, monospaced, figures that hold still.
    static let clock = Font.system(size: size(12), weight: .regular, design: .monospaced).monospacedDigit()

    /// A command or a path: 12.5, monospaced.
    static let code = Font.system(size: size(12.5), weight: .regular, design: .monospaced)
}
