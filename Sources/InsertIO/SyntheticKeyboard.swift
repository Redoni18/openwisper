import CoreGraphics
import OpenWisperCore

/// The CGEvent keyboard synthesis both inserters share.
///
/// Events are built from a `.hidSystemState` source and posted to
/// `.cghidEventTap`, i.e. injected where a real HID keystroke enters the
/// system. That is what makes them reach the frontmost app no matter which
/// process owns the focus, and it is why Accessibility permission is required.
enum SyntheticKeyboard {
    /// ANSI virtual key codes. These are physical-position codes, so they stay
    /// correct for Cmd-V / Return across keyboard layouts.
    static let keyV: CGKeyCode = 9
    static let keyReturn: CGKeyCode = 36
    /// Unicode-payload events carry no meaningful key code.
    static let keyNone: CGKeyCode = 0

    static func makeSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw OWError.insertionFailed("could not create a keyboard event source")
        }
        return source
    }

    /// A matched key-down / key-up pair. Always post both — an unmatched
    /// key-down can leave a modifier stuck in the receiving app.
    static func makePair(
        _ keyCode: CGKeyCode,
        source: CGEventSource,
        flags: CGEventFlags = []
    ) throws -> (down: CGEvent, up: CGEvent) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw OWError.insertionFailed("could not create a synthetic keystroke")
        }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        return (down, up)
    }

    static func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    /// Sleeps without being a cancellation point. Insertion is a short, tightly
    /// ordered sequence of events; bailing out halfway would leave the target
    /// app (or the clipboard) in a worse state than simply finishing.
    static func settle(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
