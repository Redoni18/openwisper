import CoreGraphics
import Foundation
import Testing

import OpenWisperCore
@testable import Spine

// ============================================================================
// Multi-key hotkey binding: `hotkey.keys` config decoding, the resolve/dedupe
// the listener does at init, and the down/up aggregation that turns several
// physical keys into one down/up signal for DictationController.
//
// Nothing here creates a CGEventTap — `HotkeyListener.init` only parses; the
// tap is created in `start()`, which these tests never call.
// ============================================================================

@Suite("Hotkey — multiple bound keys")
struct HotkeyMultiKeyTests {

    // MARK: Config decoding

    private func hotkey(_ json: String) throws -> HotkeyConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).hotkey
    }

    @Test("`keys` binds every listed key")
    func keysPresent() throws {
        let cfg = try hotkey(#"{"hotkey": {"keys": ["fn", "rightCommand"]}}"#)
        #expect(cfg.effectiveKeys == ["fn", "rightCommand"])
        #expect(cfg.key == "fn", "the single-key field keeps its default")
    }

    @Test("`keys` wins over `key` when both are present")
    func keysOverrideKey() throws {
        let cfg = try hotkey(#"{"hotkey": {"key": "f13", "keys": ["rightOption"]}}"#)
        #expect(cfg.effectiveKeys == ["rightOption"])
        #expect(cfg.key == "f13", "`key` is preserved verbatim for round-tripping")
    }

    @Test("No `keys` behaves exactly like before — just `key`")
    func keysAbsent() throws {
        #expect(try hotkey("{}").effectiveKeys == ["fn"])
        #expect(try hotkey(#"{"hotkey": {"key": "f13"}}"#).effectiveKeys == ["f13"])
        #expect(try hotkey("{}").keys == nil)
    }

    @Test("An empty or all-blank `keys` falls back to `key`")
    func keysEmpty() throws {
        #expect(try hotkey(#"{"hotkey": {"key": "f13", "keys": []}}"#).effectiveKeys == ["f13"])
        #expect(try hotkey(#"{"hotkey": {"key": "f13", "keys": ["", "  "]}}"#).effectiveKeys == ["f13"])
    }

    @Test("`keys` entries are trimmed and blanks dropped")
    func keysWhitespace() throws {
        let cfg = try hotkey(#"{"hotkey": {"keys": ["  fn ", "", "\trightCommand\n"]}}"#)
        #expect(cfg.effectiveKeys == ["fn", "rightCommand"])
    }

    @Test("A malformed `keys` degrades to `key` instead of failing the parse")
    func keysMalformed() throws {
        let cfg = try hotkey(#"{"hotkey": {"key": "f13", "keys": "rightCommand"}}"#)
        #expect(cfg.effectiveKeys == ["f13"])
        #expect(cfg.mode == "flow", "sibling defaults must survive a bad `keys`")
    }

    @Test("`keys` round-trips through encode/decode, and nil stays absent")
    func keysRoundTrip() throws {
        var cfg = AppConfig()
        cfg.hotkey.keys = ["fn", "rightCommand"]
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        #expect(back.hotkey.effectiveKeys == ["fn", "rightCommand"])

        let plain = try JSONEncoder().encode(AppConfig())
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"keys\""),
                "a config that never set `keys` must not grow the field on save")
    }

    // MARK: Listener binding (parse only — no event tap)

    @Test("The listener binds every configured key")
    func listenerBindsAllKeys() {
        let listener = HotkeyListener(config: HotkeyConfig(keys: ["fn", "rightCommand", "f13"]))
        #expect(listener.boundKeyCodes == [63, 54, 105])
        #expect(!listener.isRunning, "constructing a listener must not create a tap")
    }

    @Test("Keys that name the same physical key are bound once")
    func listenerDedupesKeys() {
        let listener = HotkeyListener(config: HotkeyConfig(keys: ["fn", "globe", "keycode:54", "rightCommand"]))
        #expect(listener.boundKeyCodes == [63, 54])
    }

    @Test("Unknown names still fall back to fn, and `key` still works alone")
    func listenerFallbacks() {
        #expect(HotkeyListener(config: HotkeyConfig(keys: ["not-a-key"])).boundKeyCodes == [63])
        #expect(HotkeyListener(config: HotkeyConfig(key: "f13")).boundKeyCodes == [105])
        #expect(HotkeyListener(config: HotkeyConfig(key: "f13", keys: [])).boundKeyCodes == [105])
        // Two unknown names collapse to a single fn binding.
        #expect(HotkeyListener(config: HotkeyConfig(keys: ["nope", "also-nope"])).boundKeyCodes == [63])
    }
}

@Suite("Hotkey — press aggregation across keys")
struct HotkeyPressAggregatorTests {

    private let fn: CGKeyCode = 63
    private let rightCommand: CGKeyCode = 54

    @Test("One key produces exactly one down and one up")
    func singleKey() {
        var agg = HotkeyPressAggregator()
        #expect(agg.set(fn, down: true) == .down)
        #expect(agg.set(fn, down: false) == .up)
        #expect(!agg.isAnyDown)
    }

    @Test("A repeated state for the same key emits nothing")
    func repeatedState() {
        var agg = HotkeyPressAggregator()
        #expect(agg.set(fn, down: true) == .down)
        #expect(agg.set(fn, down: true) == nil)
        #expect(agg.set(fn, down: false) == .up)
        #expect(agg.set(fn, down: false) == nil, "an up for a key already up is not a transition")
    }

    @Test("Overlapping keys emit one down on the first and one up on the last")
    func overlappingKeys() {
        var agg = HotkeyPressAggregator()
        #expect(agg.set(fn, down: true) == .down)
        #expect(agg.set(rightCommand, down: true) == nil, "the group is already down")
        #expect(agg.set(fn, down: false) == nil, "one key is still held")
        #expect(agg.isAnyDown)
        #expect(agg.set(rightCommand, down: false) == .up)
        #expect(!agg.isAnyDown)
    }

    @Test("Either bound key alone drives a full cycle")
    func eitherKeyAlone() {
        var agg = HotkeyPressAggregator()
        for code in [fn, rightCommand] {
            #expect(agg.set(code, down: true) == .down)
            #expect(agg.set(code, down: false) == .up)
            #expect(!agg.isAnyDown)
        }
    }

    @Test("An up for a key that was never down is not a transition")
    func strayUp() {
        var agg = HotkeyPressAggregator()
        #expect(agg.set(rightCommand, down: false) == nil)
        #expect(!agg.isAnyDown)
        #expect(agg.set(fn, down: true) == .down)
        #expect(agg.set(rightCommand, down: false) == nil, "fn is still held")
        #expect(agg.isAnyDown)
    }

    @Test("reset() reports whether anything was held, and clears it")
    func reset() {
        // `#expect` rewrites a bare call into a closure, which a mutating method
        // cannot be used in — hence the locals.
        var agg = HotkeyPressAggregator()
        let resetWhileIdle = agg.reset()
        #expect(!resetWhileIdle)

        _ = agg.set(fn, down: true)
        _ = agg.set(rightCommand, down: true)
        let resetWhileHeld = agg.reset()
        #expect(resetWhileHeld, "teardown mid-hold must still owe a cancel")
        #expect(!agg.isAnyDown)

        let resetAgain = agg.reset()
        #expect(!resetAgain)

        // After a reset the next press is a fresh down.
        #expect(agg.set(rightCommand, down: true) == .down)
    }
}
