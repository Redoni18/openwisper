// MainWindowController — the one real window OpenWisper has.
//
// Deliberately an NSWindow built by hand rather than a SwiftUI `Window` scene:
// the app is `LSUIElement` and its lifecycle is owned by an AppDelegate, so a
// scene-based app would fight both. AppKit owns the window; SwiftUI owns its
// contents.
import AppKit
import OpenWisperCore
import SwiftUI

@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {

    /// Opening size on a machine that has never seen the window. Wide enough
    /// that a history row shows two lines of transcript plus the Copy button
    /// without wrapping.
    private static let defaultSize = NSSize(width: 880, height: 580)
    /// Below this the sidebar starts eating the Model page's form rows.
    private static let minSize = NSSize(width: 720, height: 460)
    private static let frameAutosaveName = "OpenWisperMainWindow"

    private let model: MainWindowModel
    private let window: NSWindow

    public init(store: TranscriptHistoryStore, actions: MainWindowActions) {
        let model = MainWindowModel(store: store, actions: actions)
        self.model = model
        self.window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = Defaults.appName
        window.minSize = Self.minSize
        // No visible title bar: the sidebar runs the full height of the window
        // and the traffic lights float over it (the sidebar pads itself clear).
        // The title string stays set for Mission Control and accessibility.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // With the title bar gone, the sidebar and page headers are the only
        // drag surfaces left.
        window.isMovableByWindowBackground = true
        // Matches what SwiftUI paints, so the strip a live resize exposes for a
        // frame is warm paper rather than system gray.
        window.backgroundColor = OWTheme.nsWindowBackground
        // The app outlives the window. Closing it (⌘W, red button) must not
        // deallocate it out from under this controller — `show(page:)` brings
        // the same window back, with the frame and page the user left it at.
        window.isReleasedWhenClosed = false
        // One window, no tabs: "Show Tab Bar" on a single-window app is noise.
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainWindowRootView(model: model))

        // Set after the content view so nothing the hosting view does on
        // insertion can resize the frame we just restored.
        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored { window.center() }
    }

    /// Brings the window to the given page and to the front.
    ///
    /// `NSApp.activate()` is not optional here: an `LSUIElement` app is never
    /// the active app, so without it `makeKeyAndOrderFront` puts the window
    /// *behind* whatever the user was typing into.
    public func show(page: MainWindowPage) {
        model.page = page
        model.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public var isVisible: Bool { window.isVisible }

    // MARK: NSWindowDelegate

    /// Everything on all three pages is polled, never pushed, so re-reading on
    /// activation is what keeps the window honest after the user has been off
    /// granting a permission or editing config.json.
    public func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }
}
