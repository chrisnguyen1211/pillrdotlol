import AppKit

/// Hold fn to speak a reply, by the Mac's own dictation: the one the
/// keyboard uses, in the languages, on the servers and with the voice it has
/// learned that you set for it. pillr only turns it on in the reply field
/// while fn is held and off when it is let go; the words go into the field
/// as you speak, to be read over and sent. pillr hears nothing itself.
enum SystemDictation {
    /// Turns dictation on in the field that has the keyboard. macOS asks to
    /// switch Dictation on the first time if it is off.
    @MainActor @discardableResult
    static func start() -> Bool {
        NSApp.sendAction(NSSelectorFromString("startDictation:"), to: nil, from: nil)
    }

    @MainActor
    static func stop() {
        NSApp.sendAction(NSSelectorFromString("stopDictation:"), to: nil, from: nil)
    }

    /// The fn key (the 🌐 key).
    static let fnKeyCode: UInt16 = 63

    /// fn pressed (true) or let go (false), with nothing else held; nil for
    /// any other key.
    static func fnChange(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard keyCode == fnKeyCode else { return nil }
        let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard flags.intersection(others).isEmpty else { return false }
        return flags.contains(.function)
    }
}
