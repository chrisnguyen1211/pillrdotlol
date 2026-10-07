import AppKit
import SwiftUI

/// The light/dark switch: a tile holding a sun that becomes a moon. The
/// disc grows and a second, hidden disc slides in to bite a crescent out of
/// it while the icon turns; going back, the bite slides away, the disc
/// shrinks, and six rays pop out one after another.
struct ThemeToggle: View {
    @Binding var mode: InterfaceMode
    var size: CGFloat = 32

    private var dark: Bool { mode == .dark }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.5)) { mode = mode.toggled }
        } label: {
            SunMoon(dark: dark)
                .foregroundStyle(dark ? Color.white : Color(red: 0.047, green: 0.039, blue: 0.035))
                .frame(width: size / 2, height: size / 2)
                .frame(width: size, height: size)
                .background {
                    RoundedRectangle(cornerRadius: size / 4, style: .continuous)
                        .fill(LinearGradient(
                            colors: dark
                                ? [Color(red: 0.06, green: 0.11, blue: 0.24), Color(red: 0.008, green: 0.024, blue: 0.09)]
                                : [Color(red: 0.945, green: 0.961, blue: 0.976), Color(red: 0.973, green: 0.980, blue: 0.988)],
                            startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: size / 6, y: size / 12)
                }
                .contentShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(dark ? L10n.t("Switch to light mode") : L10n.t("Switch to dark mode"))
        .accessibilityLabel(dark ? L10n.t("Switch to light mode") : L10n.t("Switch to dark mode"))
    }
}

/// The icon, drawn on an 18-unit grid: a disc at the centre and six rays a
/// radius of 8 out from it.
struct SunMoon: View {
    let dark: Bool

    var body: some View {
        GeometryReader { proxy in
            let u = proxy.size.width / 18
            ZStack {
                Circle()
                    .frame(width: (dark ? 16 : 10) * u, height: (dark ? 16 : 10) * u)
                    .position(x: 9 * u, y: 9 * u)
                    .mask {
                        ZStack {
                            Rectangle()
                            Circle()
                                .frame(width: 16 * u, height: 16 * u)
                                .position(x: (dark ? 10 : 25) * u, y: 2 * u)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) * .pi / 3
                    Circle()
                        .frame(width: 3 * u, height: 3 * u)
                        .scaleEffect(dark ? 0.01 : 1)
                        .position(x: (9 + 8 * cos(angle)) * u, y: (9 + 8 * sin(angle)) * u)
                        // One after another on the way in; all at once out.
                        .animation(dark
                                   ? .easeIn(duration: 0.15)
                                   : .spring(response: 0.28, dampingFraction: 0.55).delay(0.2 + Double(index) * 0.05),
                                   value: dark)
                }
            }
            .rotationEffect(.degrees(dark ? 40 : 90))
        }
        .accessibilityHidden(true)
    }
}

/// Puts an appearance on the window a view is in: Settings follows the
/// light/dark switch, and AppKit's own controls in it — menus, popovers,
/// segmented pickers — resolve against the window, not the SwiftUI scheme.
struct WindowAppearance: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView { Setter(appearance: appearance) }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Setter)?.appearance = appearance
        view.window?.appearance = appearance
    }

    private final class Setter: NSView {
        init(appearance: NSAppearance?) {
            super.init(frame: .zero)
            self.appearance = appearance
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.appearance = appearance
        }
    }
}

/// Light, dark or System as one icon, like the power button beside it: it
/// shows the appearance in use, and a click moves to the next — Light, Dark,
/// System, round again.
struct ThemeChooser: View {
    @Binding var choice: AppearanceChoice
    var size: CGFloat = 28

    private var next: AppearanceChoice {
        let all = AppearanceChoice.allCases
        return all[(all.firstIndex(of: choice)! + 1) % all.count]
    }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { choice = next }
        } label: {
            Image(systemName: choice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Appearance: \(choice.title) — click for \(next.title)"))
        .accessibilityLabel(L10n.t("Appearance"))
        .accessibilityValue(choice.title)
        .accessibilityHint(L10n.t("Switches to \(next.title)"))
    }
}
