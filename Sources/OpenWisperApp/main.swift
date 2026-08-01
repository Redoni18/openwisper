// OpenWisper — the shipping menu-bar app.
//
// This file only stands NSApplication up; every component is created and wired
// in AppDelegate.applicationDidFinishLaunching.
//
// Note the `MainActor.assumeIsolated`: top-level code runs on the main *thread*
// but is not main-actor *isolated*, so a `@MainActor` type cannot be
// constructed here without it. Same pattern as Sources/pill-demo/main.swift.
import AppKit

let app = NSApplication.shared

// `.accessory`: no Dock icon, no app menu, and the app never becomes active on
// its own — the app being dictated into keeps its focus and text cursor.
// (The bundle also sets LSUIElement; this covers the unbundled `make run` case.)
app.setActivationPolicy(.accessory)

// `NSApplication.delegate` is a weak reference, so this top-level binding is
// what keeps the delegate — and through it the whole object graph — alive.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate

app.run()
