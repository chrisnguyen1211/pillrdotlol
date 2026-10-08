import AppKit
import SwiftUI

/// Hosts the settings sheet in its own window.
///
/// A real window rather than a panel attached to the notch: settings are a place
/// you go, not something you glance at, and a floating panel that follows the
/// notch would be one more thing hovering over the screen edge.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// The tab a sheet not yet built should open on.
    private var pendingSection: SettingsSection?
    private let preferences: Preferences
    /// A closure, not a snapshot. Read once at launch, the account shown here
    /// went stale the moment someone switched account in Cursor — and stayed
    /// stale until the app was restarted.
    private let providers: () -> [ProviderSummary]
    private let signOut: (String) -> Void
    private let signIn: (String) -> Bool
    private let switchAccount: (String) -> Bool
    private let retry: (String) -> Void
    private let updater: Updater
    private let ollamaRelay: OllamaActivityRelay?
    private let lmstudioMetrics: LMStudioMetrics?
    private let usageStore: UsageStore?
    private let resetPosition: () -> Void
    private let quit: () -> Void
    private let previewResetAlert: (() -> Void)?
    private let previewSessionLimitAlert: (() -> Void)?
    private let previewWeeklyLimitAlert: (() -> Void)?
    /// The lid module, asked for when the sheet is built: it starts later.
    var effort: () -> EffortController? = { nil }
    /// Opens the setup assistant, from General.
    var openSetup: () -> Void = {}
    /// Starts the intro tour, from General.
    var openTour: () -> Void = {}

    init(preferences: Preferences,
         providers: @escaping () -> [ProviderSummary],
         updater: Updater,
         signOut: @escaping (String) -> Void,
         signIn: @escaping (String) -> Bool,
         switchAccount: @escaping (String) -> Bool,
         retry: @escaping (String) -> Void,
         resetPosition: @escaping () -> Void,
         quit: @escaping () -> Void,
         previewResetAlert: (() -> Void)? = nil,
         previewSessionLimitAlert: (() -> Void)? = nil,
         previewWeeklyLimitAlert: (() -> Void)? = nil,
         usageStore: UsageStore? = nil,
         ollamaRelay: OllamaActivityRelay? = nil,
         lmstudioMetrics: LMStudioMetrics? = nil) {
        self.ollamaRelay = ollamaRelay
        self.lmstudioMetrics = lmstudioMetrics
        self.usageStore = usageStore
        self.resetPosition = resetPosition
        self.quit = quit
        self.previewResetAlert = previewResetAlert
        self.previewSessionLimitAlert = previewSessionLimitAlert
        self.previewWeeklyLimitAlert = previewWeeklyLimitAlert
        self.switchAccount = switchAccount
        self.retry = retry
        self.updater = updater
        self.preferences = preferences
        self.providers = providers
        self.signOut = signOut
        self.signIn = signIn
    }

    /// Bring the window to the front from an accessory app.
    ///
    /// `makeKeyAndOrderFront` plus `activate` alone were not enough here: an
    /// accessory app — anything but `AppPresence.dock` — is restricted by
    /// macOS from properly activating and compositing its own windows, so the
    /// window could be created, "visible" by `NSWindow`'s own bookkeeping, and
    /// still never actually drawn on screen (its `occlusionState` missing
    /// `.visible` is what gave this away). A `.regular` app has no such
    /// restriction, so this promotes to one for as long as the window is
    /// open and restores whatever `AppPresence` actually chose once it
    /// closes — settings staying open is the one moment the Dock is allowed
    /// to gain an icon it did not ask for.
    private func surface(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(preferences.appPresence.activationPolicy)
    }

    /// Sit the traffic lights in the middle of the panel's header band.
    ///
    /// Their default place is a title bar's worth from the top, which on a
    /// `fullSizeContentView` window leaves them crowded into the corner of
    /// the sidebar card rather than centred in the row the card's toggle and
    /// the pane's title share. AppKit puts them back on some window events,
    /// so this runs again whenever the window comes forward rather than only
    /// at creation.
    private func layoutTrafficLights(in window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton,
                       .miniaturizeButton,
                       .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }

        for (index, button) in buttons.enumerated() {
            var frame = button.frame
            frame.origin.x = Self.firstLightCentreX
                + CGFloat(index) * Self.lightSpacing - frame.width / 2
            // Flipped: AppKit measures a window's content from the bottom.
            frame.origin.y = container.bounds.height
                - SettingsView.headerHeight / 2 - frame.height / 2
            button.frame = frame
        }
    }

    /// Centre of the close button, in from the window's left edge, and the
    /// centre-to-centre step to the next one — both measured off the design
    /// this panel is matching.
    private static let firstLightCentreX: CGFloat = 26
    private static let lightSpacing: CGFloat = 22.5

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        layoutTrafficLights(in: window)
    }

    /// Put the window away if it is already in front, otherwise bring it up.
    ///
    /// Only the notch's own gear calls this. A menu item reading "Settings…"
    /// and the first-launch introduction both `show()` instead, because a
    /// command that names a destination should go there rather than toggle.
    ///
    /// The condition is *key*, not merely visible. Clicking the gear while the
    /// window is open but behind something else should fetch it forward — the
    /// intent there is plainly "show me that", and closing it would be the one
    /// thing the click could not have meant.
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            // `isReleasedWhenClosed` is false, so this hides it and keeps the
            // window itself for the next `show()`.
            window.close()
            return
        }
        show()
    }

    /// Put it away — for the tour, which needs the screen it points at.
    func close() { window?.close() }

    /// Opens the sheet on one tab.
    func show(section: SettingsSection) {
        let existed = window != nil
        pendingSection = section
        show()
        if existed { NotificationCenter.default.post(name: SettingsView.openSection, object: section.rawValue) }
    }

    func show() {
        if let window {
            // Re-centered every time, not only at creation: a window is
            // positioned once and then just re-surfaced from here on, so if
            // it ever ended up off any connected screen — a display that was
            // reconfigured or disconnected since — every later click would
            // silently bring forward a window that isn't anywhere visible.
            if !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                window.center()
            }
            surface(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: SettingsView.width, height: SettingsView.height),
            // `fullSizeContentView` runs the sidebar flush up under the traffic
            // lights, with no separate title strip above it. This reserved a
            // tall blank band once before, but that band was
            // `NavigationSplitView`'s own toolbar — the sidebar is a plain
            // `HStack` now, so there is no toolbar left to reserve for.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Kept for the Window menu and Mission Control; hidden from the bar
        // itself, where the sidebar already names what you are looking at.
        window.title = L10n.t("pillr Settings")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A floating rounded panel rather than a square window. The rounded
        // shape is drawn by the content (see `SettingsView.body`), so the
        // window has to stop painting its own square one behind it — hence
        // the clear background, which also lets the corners cut through
        // instead of showing black wedges outside the curve.
        window.isOpaque = false
        window.backgroundColor = .clear
        // The light/dark switch decides, not the Mac; `WindowAppearance`
        // keeps it in step when the switch is flipped.
        window.appearance = preferences.interfaceMode.appearance
        window.hasShadow = true
        window.delegate = self
        window.contentView = SettingsHostingView(
            rootView: SettingsView(preferences: preferences,
                                   providers: providers,
                                   signOut: signOut,
                                   signIn: signIn,
                                   switchAccount: switchAccount,
                                   retry: retry,
                                   resetPosition: resetPosition,
                                   quit: quit,
                                   updater: updater,
                                   ollamaRelay: ollamaRelay, lmstudioMetrics: lmstudioMetrics,
                                   usageStore: usageStore,
                                   previewResetAlert: previewResetAlert,
                                   previewSessionLimitAlert: previewSessionLimitAlert,
                                   previewWeeklyLimitAlert: previewWeeklyLimitAlert,
                                   effort: effort,
                                   openSetup: { [weak self] in self?.openSetup() },
                                   openTour: { [weak self] in self?.openTour() },
                                   startSection: pendingSection ?? .lid)
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        layoutTrafficLights(in: window)
        surface(window)
    }
}

/// The settings sheet's host. Its top bar sits where a title bar would, so
/// nothing under it is allowed to move the window — the bar's empty stretch
/// does that itself (`WindowDragHandle`), and a press on a control there is
/// only ever a press.
final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Empty space that moves the window when dragged — the settings bar's
/// stretch between its name and its controls.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Handle: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
