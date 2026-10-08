import AppKit
import SwiftUI

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
        .help(L10n.t("Appearance: \(choice.title) (click for \(next.title))"))
        .accessibilityLabel(L10n.t("Appearance"))
        .accessibilityValue(choice.title)
        .accessibilityHint(L10n.t("Switches to \(next.title)"))
    }
}
