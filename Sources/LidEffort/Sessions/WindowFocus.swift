import AppKit
import ApplicationServices

/// The session's own window, for hosts with no way to name a tab: the
/// editors (VS Code, Cursor, Windsurf, Zed, JetBrains), Warp, and any
/// terminal whose scripting answered nothing. Their windows are titled after
/// the folder or the project open in them, so the one window whose title
/// names the session's folder is raised through Accessibility. That only
/// ever reaches a window already open; the editors' own command lines
/// (`code <folder>`, `cursor <folder>`) open a new window when the folder is
/// not open in one, and with `-r` swap the last window's folder for it.
enum WindowFocus {
    /// The one title that names a hint; nil when none does, or more than
    /// one window could be meant.
    static func choose(titles: [String?], hints: [String]) -> Int? {
        let usable = hints.map { $0.lowercased() }.filter { $0.count >= 3 }
        guard !usable.isEmpty else { return nil }
        let matching = titles.indices.filter { index in
            guard let title = titles[index]?.lowercased(), !title.isEmpty else { return false }
            return usable.contains { title.contains($0) }
        }
        return matching.count == 1 ? matching.first : nil
    }

    /// Raises the app's window that names the session. Needs Accessibility;
    /// false when it is off or no single window is the one.
    @discardableResult
    static func raise(appPID: pid_t, hints: [String]) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(appPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.count > 1 else { return false }
        let titles = windows.map { window -> String? in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return title as? String
        }
        guard let index = choose(titles: titles, hints: hints) else { return false }
        let window = windows[index]
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    /// The folder a session works in, and the repository that folder is
    /// in: an editor's window is titled after the folder it opened, which
    /// is more often the repository than the subfolder a terminal is in.
    static func folderHints(cwd: String?, fileManager: FileManager = .default) -> [String] {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return [] }
        var hints = [(cwd as NSString).lastPathComponent]
        let home = fileManager.homeDirectoryForCurrentUser.path
        var folder = cwd
        for _ in 0..<24 {
            if fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) {
                let name = (folder as NSString).lastPathComponent
                if !hints.contains(name) { hints.append(name) }
                break
            }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent == "/" || folder == home { break }
            folder = parent
        }
        return hints
    }
}

extension PasteTarget {
    /// Editors whose window holds files as well as terminals: ⌘V lands in
    /// whatever has the keyboard there, which may be a source file.
    static func isEditor(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if bundleID.hasPrefix("com.jetbrains.") || bundleID.hasPrefix("dev.zed.") { return true }
        return editorBundleIDs.contains(bundleID)
    }

    static let editorBundleIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92",     // Cursor
        "com.exafunction.windsurf", "com.google.antigravity", "com.trae.app",
        "com.google.android.studio", "com.sublimetext.4", "com.apple.dt.Xcode",
    ]

    /// Whether what has the keyboard in the app reads as a terminal: the
    /// focused element or one of its parents says "terminal" (VS Code and
    /// its kin label their terminal so for screen readers) or is xterm.js's.
    static func focusIsTerminal(appPID: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(appPID)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let start = focused, CFGetTypeID(start) == AXUIElementGetTypeID() else { return false }
        var element = start as! AXUIElement
        for _ in 0..<8 {
            if describesTerminal(labels(of: element)) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            element = next as! AXUIElement
        }
        return false
    }

    static func describesTerminal(_ labels: [String]) -> Bool {
        labels.contains { label in
            let lower = label.lowercased()
            return lower.contains("terminal") || lower.contains("xterm")
        }
    }

    private static func labels(of element: AXUIElement) -> [String] {
        var labels: [String] = []
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String { labels.append(text) }
        }
        var classes: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &classes) == .success,
           let list = classes as? [String] { labels.append(contentsOf: list) }
        return labels
    }
}
