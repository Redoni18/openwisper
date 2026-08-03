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

/// A parsed hotkey spec (one entry of `HotkeyConfig.effectiveKeys`).
struct ResolvedHotkey {
    let keyCode: CGKeyCode
    /// Non-nil for modifier-class keys, which arrive as `flagsChanged` rather
    /// than `keyDown`/`keyUp`.
    let modifier: ModifierMatch?

    var isModifier: Bool { modifier != nil }
}

/// Collapses the physical state of several bound hotkeys into the single
/// down/up signal `DictationController` expects: down on the first key pressed,
/// up when the last one is released, and nothing in between. Pure value type so
/// the transition rules are testable without an event tap.
struct HotkeyPressAggregator {
    enum Transition { case down, up }

    private(set) var downKeys: Set<CGKeyCode> = []

    var isAnyDown: Bool { !downKeys.isEmpty }

    /// Records one key's new physical state and reports the transition it caused
    /// for the group as a whole, or nil when the group's state did not change
    /// (a second key going down while another is held, a repeat of a state we
    /// already have, an up for a key that was never down).
    mutating func set(_ keyCode: CGKeyCode, down: Bool) -> Transition? {
        let wasAnyDown = isAnyDown
        if down {
            downKeys.insert(keyCode)
        } else {
            downKeys.remove(keyCode)
        }
        guard isAnyDown != wasAnyDown else { return nil }
        return isAnyDown ? .down : .up
    }

    /// Forgets every key. Returns whether anything was down, which is what tells
    /// a teardown mid-hold that it still owes the delegate a cancel.
    @discardableResult
    mutating func reset() -> Bool {
        let wasAnyDown = isAnyDown
        downKeys.removeAll()
        return wasAnyDown
    }
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

    /// What the listener actually ended up bound to, in config order. Backs the
    /// start-up log line and keeps `init`'s resolve-and-dedupe testable.
    var boundKeyCodes: [CGKeyCode] { hotkeys.map(\.keyCode) }

    // MARK: Private state

    /// Every bound key, deduped by keycode. Any one of them drives dictation.
    private let hotkeys: [ResolvedHotkey]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Physical state of the bound keys, tracked so repeated `flagsChanged`
    /// events — and a second bound key pressed while the first is held — can't
    /// produce duplicate down/up callbacks.
    private var pressed = HotkeyPressAggregator()

    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    // MARK: Lifecycle

    public init(config: HotkeyConfig) {
        // Two specs can name the same physical key ("fn"/"globe",
        // "rightCommand"/"keycode:54"); binding it twice would be harmless for
        // the aggregator but would make the log lie, so dedupe by keycode.
        var seen = Set<CGKeyCode>()
        var resolved: [ResolvedHotkey] = []
        for spec in config.effectiveKeys {
            let hotkey = HotkeyListener.resolve(spec)
            if seen.insert(hotkey.keyCode).inserted { resolved.append(hotkey) }
        }
        // `effectiveKeys` is never empty and `resolve` never fails, so this is
        // belt-and-braces: the listener must never end up bound to nothing.
        self.hotkeys = resolved.isEmpty ? [HotkeyListener.resolve("fn")] : resolved
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
        self.pressed.reset()

        let codes = boundKeyCodes.map(String.init).joined(separator: ", ")
        Log.hotkey.info("Hotkey listener started (keycodes \(codes, privacy: .public))")
    }

    public func stop() {
        teardown(notifyDelegate: true)
    }

    private func teardown(notifyDelegate: Bool) {
        // True if *any* bound key was still held.
        let wasDown = pressed.reset()

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
            // Each bound modifier carries its own match rule, so ask the one
            // whose keycode this event names. Arrow and function keys also carry
            // maskSecondaryFn, but they arrive as keyDown/keyUp; matching
            // flagsChanged *and* keycode 63 isolates the physical fn key.
            guard let hotkey = modifierHotkey(matching: keyCode(of: event)),
                  let modifier = hotkey.modifier
            else { return }
            setHotkeyDown(hotkey.keyCode, modifier.isDown(event.flags))

        case .keyDown:
            let code = keyCode(of: event)
            if code == Int64(KeyCode.escape) {
                if pressed.isAnyDown || isSessionActive {
                    Log.hotkey.debug("Esc during a live hotkey session — cancelling")
                    emit(.canceled)
                }
                return
            }
            guard let hotkey = plainHotkey(matching: code) else { return }
            // Key repeat would otherwise look like a second press.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            setHotkeyDown(hotkey.keyCode, true)

        case .keyUp:
            guard let hotkey = plainHotkey(matching: keyCode(of: event)) else { return }
            setHotkeyDown(hotkey.keyCode, false)

        default:
            return
        }
    }

    private func keyCode(of event: CGEvent) -> Int64 {
        event.getIntegerValueField(.keyboardEventKeycode)
    }

    /// The bound modifier-class key with this keycode, if any. Keycodes are
    /// unique across `hotkeys`, so at most one can match.
    private func modifierHotkey(matching code: Int64) -> ResolvedHotkey? {
        hotkeys.first { $0.isModifier && code == Int64($0.keyCode) }
    }

    /// The bound keyDown/keyUp-class key with this keycode, if any.
    private func plainHotkey(matching code: Int64) -> ResolvedHotkey? {
        hotkeys.first { !$0.isModifier && code == Int64($0.keyCode) }
    }

    private func setHotkeyDown(_ keyCode: CGKeyCode, _ down: Bool) {
        guard let transition = pressed.set(keyCode, down: down) else { return }
        emit(transition == .down ? .down : .up)
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

    /// Parses one hotkey spec (`HotkeyConfig.key`, or an entry of
    /// `HotkeyConfig.keys`). Unknown names fall back to fn.
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
