// pill-demo — visual QA harness for the floating recording pill.
//
//   swift run pill-demo          (≈7 s, exits 0 on its own)
//
// Runs the real PillController through a full dictation cycle: recording with
// synthetic wandering levels, processing, success, then an error. The pill
// appears at the bottom of whichever screen the pointer is on, exactly as it
// will during real dictation.
//
// It doubles as the integration reference for Wave B — this is all the wiring a
// caller needs:
//
//     let pill = PillController()            // main actor
//     let indicator: RecordingIndicator = pill
//     indicator.show(.recording)
//     recorder.levelHandler = { level in     // arbitrary queue
//         Task { @MainActor in indicator.updateLevel(level) }
//     }
//     indicator.show(.processing)
//     indicator.show(.success); indicator.hide(after: 0.8)
import AppKit
import OpenWisperCore
import PillUI

@MainActor
final class PillDemo: NSObject, NSApplicationDelegate {
    private let pill = PillController()
    private let startedAt = Date()

    private var levelTimer: Timer?
    private var levelSamples = 0
    private var peakLevel: Float = 0

    // MARK: Script

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("pill-demo — cycling the pill through every state (≈7 s, exits 0)")
        print("  the pill appears at the bottom of the screen holding the pointer")
        print("  (or at your remembered spot); drag it to move — the position sticks.")
        print("  click the ✕ during recording/processing: the demo just logs it")

        pill.onCancel = { [weak self] in
            self?.log("✕ clicked — the real app cancels the utterance here")
        }

        // PILL_DEMO_NOTCH=1 forces the notch presentation on the first display
        // that has a cutout, so it can be inspected without dragging the
        // pointer onto the built-in screen.
        if ProcessInfo.processInfo.environment["PILL_DEMO_NOTCH"] == "1" {
            if let screen = NSScreen.screens.first(where: { NotchGeometry.notch(on: $0) != nil }) {
                pill.notchScreenOverride = screen
                // A previous scripted run may have persisted a detached state,
                // which would silently turn this into a floating run.
                pill.demoResetPlacement()
                log("PILL_DEMO_NOTCH=1 — docking to the notch on \(screen.localizedName)")
            } else {
                log("PILL_DEMO_NOTCH=1 but no display has a notch")
            }
        }

        // PILL_DEMO_PULL=1 (with NOTCH=1): scripted pull-out — grab the strip,
        // carry the pill down the screen, drop it. Replaces the normal state
        // cycle.
        if ProcessInfo.processInfo.environment["PILL_DEMO_PULL"] == "1" {
            runPullOutScript()
            return
        }

        log("recording — synthetic levels at 20 Hz for 2.5 s")
        pill.show(.recording)
        startLevelFeed()

        // Proof that the panel is inert: the demo never activates, so no window
        // of ours is key and the app the user was in keeps focus.
        at(0.5) { self.logFocusState() }

        at(2.5) {
            self.stopLevelFeed()
            self.log("processing — 1.2 s")
            self.pill.show(.processing)
        }

        at(3.7) {
            self.log("success — then fading out")
            self.pill.show(.success)
            self.pill.hide(after: 0.8)
        }

        at(5.2) {
            self.log("error — a widened pill with a one-line message")
            self.pill.show(.error("Model not found — run make model"))
            self.pill.hide(after: 1.4)
        }

        // Comfortably after the last hide has finished — the notch collapse
        // retracts for ~0.34 s before the window is ordered out.
        at(7.4) {
            // The last hide should have fully faded out and ordered the panel
            // out well before this point — nothing is left on screen.
            let stillVisible = NSApp.windows.first?.isVisible ?? false
            self.log("done — pill ordered out: \(!stillVisible) — exit 0")
            exit(0)
        }
    }

    // MARK: Pull-out script

    /// Grab the docked strip, carry the pill down the screen on a canned hand
    /// path, drop it — the scripted stand-in for the real drag.
    private func runPullOutScript() {
        log("pull-out script — grab the strip, drag the pill down, drop it")
        pill.show(.recording)
        startLevelFeed()

        // Where the pill starts (just under the cutout) and where it lands.
        let screen = pill.notchScreenOverride ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let startY = frame.maxY - 60.0
        let endY = frame.maxY - 380.0

        at(1.2) {
            self.pill.demoPullOutOfNotch()
            self.log("grabbed the strip — the pill is out")
        }

        // The "hand": moves down 320 pt over 2 s with a little sideways sway.
        let start = 1.3, duration = 2.0
        var tick = 0.0
        while tick <= duration {
            let t = tick
            at(start + t) {
                let progress = t / duration
                let y = startY + (endY - startY) * progress
                let x = frame.midX + 40 * sin(progress * .pi * 1.6)
                self.pill.demoMovePill(to: CGPoint(x: x, y: y))
            }
            tick += 1.0 / 30.0
        }

        at(3.6) {
            self.log("dropped — the pill stays where it was left")
            self.stopLevelFeed()
        }

        at(4.4) {
            self.pill.hide(after: 0)
        }

        at(5.2) {
            self.log("done — exit 0")
            exit(0)
        }
    }

    // MARK: Synthetic levels

    /// The recorder calls `updateLevel(_:)` at ≤ 20 Hz, so the demo does too.
    private func startLevelFeed() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let level = Self.syntheticLevel(at: self.elapsed)
                self.peakLevel = max(self.peakLevel, level)
                self.levelSamples += 1
                self.pill.updateLevel(level)
            }
        }
        // .common so the feed keeps running even if something starts tracking
        // the mouse over the demo's lifetime.
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelFeed() {
        levelTimer?.invalidate()
        levelTimer = nil
        log(String(format: "fed %d level samples, peak %.2f", levelSamples, peakLevel))
    }

    /// A plausible speech envelope: slow phrasing, syllable-rate modulation, a
    /// deliberate pause (so the smoothing's decay is visible) and a little noise.
    private static func syntheticLevel(at t: TimeInterval) -> Float {
        let envelope = 0.50 + 0.26 * sin(t * 1.15 + 0.4)
        let syllables = 0.22 * sin(t * 6.3) + 0.10 * sin(t * 11.7 + 1.1)
        let pause = (t > 1.30 && t < 1.70) ? -0.62 : 0.0
        let noise = Double.random(in: -0.04...0.04)
        return Float(min(max(envelope + syllables + pause + noise, 0), 1))
    }

    // MARK: Helpers

    private var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    private func at(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func log(_ message: String) {
        print(String(format: "[pill-demo %5.2fs] %@", elapsed, message))
    }

    private func logFocusState() {
        guard let panel = NSApp.windows.first else {
            log("focus check — no panel was created (unexpected)")
            return
        }
        log("focus check — app active: \(NSApp.isActive)"
            + ", key window: \(NSApp.keyWindow == nil ? "none" : "SOME — the pill stole focus!")"
            + ", windows: \(NSApp.windows.count)"
            + ", canBecomeKey: \(panel.canBecomeKey), canBecomeMain: \(panel.canBecomeMain)")
        log("placement  — visible: \(panel.isVisible), level: \(panel.level.rawValue)"
            + ", alpha: \(String(format: "%.2f", panel.alphaValue))"
            + ", frame: \(rect(panel.frame))"
            + ", screen visibleFrame: \(panel.screen.map { rect($0.visibleFrame) } ?? "none")")
    }

    private func rect(_ r: NSRect) -> String {
        String(format: "(%.0f, %.0f) %.0fx%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }
}

// `.accessory`: no Dock icon, no menu bar, and the app never becomes active —
// the same policy the shipping app uses.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Top-level code is not main-actor isolated (nothing here awaits), but it does
// run on the main thread — which is what NSApplication and the pill require.
// `delegate` is a weak reference, so the demo is held by this top-level `let`.
let demo = MainActor.assumeIsolated { PillDemo() }
app.delegate = demo
app.run()
