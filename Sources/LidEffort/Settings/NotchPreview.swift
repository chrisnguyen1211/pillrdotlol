import Combine
import SwiftUI

/// The notch itself, drawn small at the head of Settings, on a screen of its
/// own: the edge, size, surface, transparency and colour chosen below show
/// here the moment they change, rather than somewhere on the real screen
/// edge that may be behind this window or on another display.
///
/// It is the real `NotchRootView`, driven by a model of its own that mirrors
/// the preferences the way `NotchFleet` configures the live notches, so what
/// it shows is what the notch will draw.
struct NotchPreview: View {
    @ObservedObject var preferences: Preferences
    var usageStore: UsageStore? = nil

    @StateObject private var model = NotchViewModel()
    /// Made once: the fixtures carry reset times from `Date()`, so a fresh
    /// set never equals the last and would redraw the preview every time.
    @State private var fixtures = Array(Fixtures.snapshots().prefix(3))

    /// A made-up screen the preview's notch is laid out against; only its
    /// proportions matter.
    private static let screen = CGSize(width: 1512, height: 982)

    var body: some View {
        GeometryReader { proxy in
            let scale = fit(in: proxy.size)
            let panel = model.panelSize
            ZStack(alignment: alignment) {
                wallpaper
                NotchRootView(model: model)
                    .frame(width: panel.width, height: panel.height)
                    // The live panel's own rule: glass takes the switch,
                    // solid black stays dark.
                    .environment(\.colorScheme, glassy ? preferences.interfaceMode.colorScheme : .dark)
                    .scaleEffect(scale, anchor: anchor)
                    .frame(width: panel.width * scale, height: panel.height * scale, alignment: alignment)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.t("Preview of the notch"))
        .onAppear { sync() }
        // Coalesced, and after the change lands: `objectWillChange` fires
        // before the new value is stored, and a burst of writes is one redraw.
        .onReceive(preferences.objectWillChange
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)) { _ in sync() }
        .onReceive((usageStore?.$notchSnapshots.eraseToAnyPublisher()
                    ?? Empty<[ProviderSnapshot], Never>().eraseToAnyPublisher())
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in syncSnapshots() }
    }

    private var glassy: Bool { preferences.notchSurfaceStyle.effective == .glass }

    /// A dusk gradient standing in for a desktop, so the glass has
    /// something to bend and the solid style something to stand out from.
    private var wallpaper: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.32),
                                Color(red: 0.42, green: 0.25, blue: 0.40),
                                Color(red: 0.86, green: 0.52, blue: 0.38)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color(red: 1, green: 0.78, blue: 0.5).opacity(0.55))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)
                    .offset(x: 20, y: 40)
            }
    }

    /// The panel hugs the chosen edge of the little screen, centred along it.
    private var alignment: Alignment {
        switch model.edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var anchor: UnitPoint {
        switch model.edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Small enough that the open notch fits the long way with room to
    /// spare, and never larger than life.
    private func fit(in size: CGSize) -> CGFloat {
        let notch = model.notchSize
        guard notch.width > 0, notch.height > 0 else { return 1 }
        let along = model.edge.isVertical ? size.height / notch.height : size.width / notch.width
        let across = model.edge.isVertical ? size.width / notch.width : size.height / notch.height
        return min(1, along * 0.82, across * 0.7)
    }

    /// Only what changed is written. A `@Published` property announces
    /// every assignment, equal or not, and each announcement redraws the
    /// whole notch in here: writing all of them back on every preference
    /// change kept the window redrawing flat out — a full core, for as long
    /// as Settings was open.
    private func sync() {
        set(\.screenSize, Self.screen)
        set(\.edge, preferences.notchEdge)
        set(\.sizeScale, preferences.notchScale)
        set(\.cardScale, CGFloat(preferences.cardScale))
        set(\.accentColor, preferences.accentColor)
        set(\.weeklyRing, preferences.weeklyRing)
        set(\.showsMoveHandle, preferences.showsMoveHandle)
        set(\.surfaceStyle, preferences.notchSurfaceStyle)
        set(\.interfaceMode, preferences.interfaceMode)
        set(\.pillFrost, CGFloat(preferences.pillFrost))
        set(\.resetTimeFormat, preferences.resetTimeFormat)
        if model.snapshots.isEmpty { syncSnapshots() }
        set(\.isExpanded, true)
    }

    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NotchViewModel, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }

    private func syncSnapshots() {
        let live = usageStore?.notchSnapshots.filter { preferences.isConnected($0.id) } ?? []
        let next = live.isEmpty ? fixtures : live
        if model.snapshots != next { model.updateSnapshots(next) }
    }
}
