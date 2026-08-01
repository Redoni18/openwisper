import CoreGraphics
import Foundation
import OpenWisperCore

// ============================================================================
// Global hotkey listening via a listen-only CGEventTap.
//
// "Listen-only" matters: we never swallow or rewrite the user's keystrokes, so
// holding fn still behaves normally in every other app (and only Input
// Monitoring is required, not Accessibility). The trade-off is that the tap
// cannot suppress the key, which is why README asks the user to set
// System Settings → Keyboard → "Press 🌐 key to" = Do Nothing.
// ============================================================================

/// Virtual keycodes for every key OpenWisper accepts as a hotkey (`kVK_*` from
/// Carbon's `Events.h`; hard-coded so we don't link Carbon).
private enum KeyCode {
    static let fn: CGKeyCode = 63
    static let rightCommand: CGKeyCode = 54
    static let leftCommand: CGKeyCode = 55
    static let leftShift: CGKeyCode = 56
    static let leftOption: CGKeyCode = 58
    static let leftControl: CGKeyCode = 59
    static let rightShift: CGKeyCode = 60
    static let rightOption: CGKeyCode = 61
    static let rightControl: CGKeyCode = 62

    static let f13: CGKeyCode = 105
    static let f14: CGKeyCode = 107
    static let f15: CGKeyCode = 113
    static let f16: CGKeyCode = 106
    static let f17: CGKeyCode = 64
    static let f18: CGKeyCode = 79
    static let f19: CGKeyCode = 80

    static let escape: CGKeyCode = 53
}

/// Device-dependent modifier bits carried in `CGEventFlags` (`NX_DEVICE*KEYMASK`
/// from `IOKit/hidsystem/IOLLEvent.h`). The public `CGEventFlags` constants only
/// say *a* command key is down; these say *which one*, which is what lets
/// `rightCommand` work while `leftCommand` is also held.
private enum DeviceFlag {
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000

    static let shiftFamily = leftShift | rightShift
    static let controlFamily = leftControl | rightControl
    static let commandFamily = leftCommand | rightCommand
    static let optionFamily = leftOption | rightOption
}

/// How to tell "this hotkey is down" from a `flagsChanged` event.
struct ModifierMatch {
    /// Device bit for this exact physical key. 0 when the key has no sides (fn).
    let side: UInt64
    /// Device bits for both sides of the family. 0 when the key has no sides (fn).
    let family: UInt64
    /// The public `CGEventFlags` bit, set while *either* side is held.
    let generic: UInt64

    /// Modifier events report the post-change flag state, so "is my key down"
    /// is simply "is my bit set". Prefer the device-specific bit when the event
    /// carries any of them; fall back to the generic flag for synthetic or
    /// unusual events that only populate the public bits.
    func isDown(_ flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        if family != 0, raw & family != 0 { return raw & side != 0 }
        return raw & generic != 0
    }
}

/// A parsed `HotkeyConfig.key`.
struct ResolvedHotkey {
    let keyCode: CGKeyCode
    /// Non-nil for modifier-class keys, which arrive as `flagsChanged` rather
    /// than `keyDown`/`keyUp`.
    let modifier: ModifierMatch?

    var isModifier: Bool { modifier != nil }
}

/// Listen-only global hotkey listener. Delegate callbacks are raw physical
/// down/up plus an esc-cancel; hold-vs-toggle semantics live in
/// `DictationController`.
public final class HotkeyListener: HotkeyListening {

    // MARK: Public surface

    public weak var delegate: HotkeyListenerDelegate?

    public var isRunning: Bool { eventTap != nil }

    /// Set by the integrator (from `DictationController.recordingStateChanged`)
    /// so esc can cancel a live recording in *toggle* mode, where the hotkey is
    /// not physically held. In hold mode the listener already knows.
    public var isSessionActive: Bool = false

    /// Resolved keycode for a config key string. Exposed so the menu bar can
    /// show what is actually bound and so the mapping table stays unit-testable.
    public static func resolvedKeyCode(for spec: String) -> CGKeyCode {
        resolve(spec).keyCode
    }

    // MARK: Private state

    private let hotkey: ResolvedHotkey
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Physical state of the hotkey, tracked so repeated `flagsChanged` events
    /// for other keys can't produce duplicate down/up callbacks.
    private var isHotkeyDown = false

    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    // MARK: Lifecycle

    public init(config: HotkeyConfig) {
        self.hotkey = HotkeyListener.resolve(config.key)
    }

    deinit {
        // No delegate callbacks from deinit — the object is going away.
        teardown(notifyDelegate: false)
    }

    public func start() throws {
        guard eventTap == nil else { return }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: HotkeyListener.eventMask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.hotkey.error(
                "CGEvent.tapCreate returned nil (Input Monitoring status: \(String(describing: Permissions.inputMonitoring), privacy: .public))"
            )
            throw OWError.inputMonitoringNotGranted
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Log.hotkey.error("Could not create a run loop source for the event tap")
            throw OWError.inputMonitoringNotGranted
        }

        // Common modes so the hotkey keeps working while menus/panels are up.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isHotkeyDown = false
        Log.hotkey.info("Hotkey listener started (keycode \(self.hotkey.keyCode, privacy: .public))")
    }

    public func stop() {
        teardown(notifyDelegate: true)
    }

    private func teardown(notifyDelegate: Bool) {
        let wasDown = isHotkeyDown
        isHotkeyDown = false

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
            Log.hotkey.info("Hotkey listener stopped")
        }
        // Tearing down mid-hold (e.g. dictation disabled from the menu) must not
        // strand the controller in `recording`.
        if notifyDelegate, wasDown { emit(.canceled) }
    }

    // MARK: Event handling (runs on the main run loop)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables a tap whose callback ran long, and again on
            // some user-input events. Neither is fatal: just switch it back on.
            if let tap = eventTap {
                Log.hotkey.error("Event tap was disabled by the system — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        case .flagsChanged:
            guard let modifier = hotkey.modifier else { return }
            guard keyCode(of: event) == Int64(hotkey.keyCode) else { return }
            // Arrow and function keys also carry maskSecondaryFn, but they
            // arrive as keyDown/keyUp; matching flagsChanged *and* keycode 63
            // isolates the physical fn key.
            setHotkeyDown(modifier.isDown(event.flags))

        case .keyDown:
            let code = keyCode(of: event)
            if code == Int64(KeyCode.escape) {
                if isHotkeyDown || isSessionActive {
                    Log.hotkey.debug("Esc during a live hotkey session — cancelling")
                    emit(.canceled)
                }
                return
            }
            guard !hotkey.isModifier, code == Int64(hotkey.keyCode) else { return }
            // Key repeat would otherwise look like a second press.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            setHotkeyDown(true)

        case .keyUp:
            guard !hotkey.isModifier, keyCode(of: event) == Int64(hotkey.keyCode) else { return }
            setHotkeyDown(false)

        default:
            return
        }
    }

    private func keyCode(of event: CGEvent) -> Int64 {
        event.getIntegerValueField(.keyboardEventKeycode)
    }

    private func setHotkeyDown(_ down: Bool) {
        guard down != isHotkeyDown else { return }
        isHotkeyDown = down
        emit(down ? .down : .up)
    }

    // MARK: Delegate dispatch

    private enum DelegateEvent {
        case down, up, canceled
    }

    /// The tap callback already runs on the main run loop, so this is normally a
    /// direct call; the async path is insurance for any other caller (`stop()`
    /// from a background thread, say).
    private func emit(_ event: DelegateEvent) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.deliver(event) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(event) } }
        }
    }

    @MainActor
    private func deliver(_ event: DelegateEvent) {
        guard let delegate = delegate else { return }
        switch event {
        case .down: delegate.hotkeyDown()
        case .up: delegate.hotkeyUp()
        case .canceled: delegate.hotkeyCanceled()
        }
    }

    // MARK: Key spec parsing

    private static let table: [String: ResolvedHotkey] = {
        func mod(_ code: CGKeyCode, _ side: UInt64, _ family: UInt64, _ generic: CGEventFlags) -> ResolvedHotkey {
            ResolvedHotkey(
                keyCode: code,
                modifier: ModifierMatch(side: side, family: family, generic: generic.rawValue)
            )
        }
        func plain(_ code: CGKeyCode) -> ResolvedHotkey {
            ResolvedHotkey(keyCode: code, modifier: nil)
        }

        return [
            // fn is a single physical key: no left/right device bits exist for it.
            "fn": ResolvedHotkey(
                keyCode: KeyCode.fn,
                modifier: ModifierMatch(side: 0, family: 0, generic: CGEventFlags.maskSecondaryFn.rawValue)
            ),
            "globe": ResolvedHotkey(
                keyCode: KeyCode.fn,
                modifier: ModifierMatch(side: 0, family: 0, generic: CGEventFlags.maskSecondaryFn.rawValue)
            ),

            "leftcommand": mod(KeyCode.leftCommand, DeviceFlag.leftCommand, DeviceFlag.commandFamily, .maskCommand),
            "rightcommand": mod(KeyCode.rightCommand, DeviceFlag.rightCommand, DeviceFlag.commandFamily, .maskCommand),
            "leftoption": mod(KeyCode.leftOption, DeviceFlag.leftOption, DeviceFlag.optionFamily, .maskAlternate),
            "rightoption": mod(KeyCode.rightOption, DeviceFlag.rightOption, DeviceFlag.optionFamily, .maskAlternate),
            "leftcontrol": mod(KeyCode.leftControl, DeviceFlag.leftControl, DeviceFlag.controlFamily, .maskControl),
            "rightcontrol": mod(KeyCode.rightControl, DeviceFlag.rightControl, DeviceFlag.controlFamily, .maskControl),
            "leftshift": mod(KeyCode.leftShift, DeviceFlag.leftShift, DeviceFlag.shiftFamily, .maskShift),
            "rightshift": mod(KeyCode.rightShift, DeviceFlag.rightShift, DeviceFlag.shiftFamily, .maskShift),

            "f13": plain(KeyCode.f13),
            "f14": plain(KeyCode.f14),
            "f15": plain(KeyCode.f15),
            "f16": plain(KeyCode.f16),
            "f17": plain(KeyCode.f17),
            "f18": plain(KeyCode.f18),
            "f19": plain(KeyCode.f19),
        ]
    }()

    /// Parses a `HotkeyConfig.key` string. Unknown names fall back to fn.
    static func resolve(_ spec: String) -> ResolvedHotkey {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.lowercased()

        if let known = table[normalized] { return known }

        if normalized.hasPrefix("keycode:") {
            let digits = trimmed.dropFirst("keycode:".count).trimmingCharacters(in: .whitespaces)
            if let value = UInt16(digits) {
                let code = CGKeyCode(value)
                // A raw keycode that happens to name a modifier still has to be
                // matched through flagsChanged, so reuse the modifier entry.
                if let known = table.values.first(where: { $0.keyCode == code && $0.isModifier }) {
                    return known
                }
                return ResolvedHotkey(keyCode: code, modifier: nil)
            }
            Log.hotkey.error("Unparseable raw keycode in hotkey.key \"\(spec, privacy: .public)\" — falling back to fn")
            return table["fn"]!
        }

        Log.hotkey.error("Unknown hotkey.key \"\(spec, privacy: .public)\" — falling back to fn")
        return table["fn"]!
    }
}

/// C callback: no captures, so it converts to `@convention(c)`. `userInfo` is an
/// unretained pointer to the listener, which invalidates the tap in `deinit`.
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo = userInfo {
        Unmanaged<HotkeyListener>.fromOpaque(userInfo)
            .takeUnretainedValue()
            .handle(type: type, event: event)
    }
    // Listen-only: the return value is ignored, but pass the event through.
    return Unmanaged.passUnretained(event)
}
