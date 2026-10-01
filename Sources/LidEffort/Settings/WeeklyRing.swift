import Foundation

/// Whether the weekly limit gets a ring of its own, and where it sits.
///
/// The cell draws one window: the provider's declared headline, which for
/// Claude is the current session. The weekly allowance is the one that actually
/// runs out first on a busy week, and until now the only way to see it was to
/// hover. A second, thinner arc puts it on the same glance.
///
/// Inside or outside rather than a single "on", because which one reads better
/// is not something this can decide for somebody: the notch is small, the two
/// arcs are close together at any size, and whether the inner gap or the bezel
/// margin is the clearer place depends on the size the notch is set to and on
/// the eyes looking at it.
enum WeeklyRing: String, CaseIterable, Identifiable {
    /// One ring, as every version before this drew it.
    case off
    /// In the gap between the glyph and the track, where the activity arc also
    /// lives — closer to the reading it belongs to, tighter on space.
    case inside
    /// Just beyond the track, in the margin the notch already keeps clear of
    /// its bezel — more room, and further from the headline it sits beside.
    case outside

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:     return L10n.t("Off")
        case .inside:  return L10n.t("Inside")
        case .outside: return L10n.t("Outside")
        }
    }

    var explanation: String {
        switch self {
        case .off:
            return L10n.t("One ring per provider, showing the headline limit. The weekly allowance stays in the hover card.")
        case .inside:
            return L10n.t("A thinner ring for the weekly limit, drawn inside the main one. It shares the gap with the working indicator.")
        case .outside:
            return L10n.t("A thinner ring for the weekly limit, drawn around the main one, in the margin between the ring and the notch edge.")
        }
    }

    /// Where the arc's centre-line sits, measured from the ring's centre. Nil
    /// when there is no second ring to place.
    var radius: CGFloat? {
        switch self {
        case .off:     return nil
        case .inside:  return NotchLayout.weeklyInsideRadius
        case .outside: return NotchLayout.weeklyOutsideRadius
        }
    }
}
