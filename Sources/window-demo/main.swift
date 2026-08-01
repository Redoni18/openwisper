// window-demo — offscreen snapshots of the app window's three pages.
//
//   swift run window-demo [output-dir]     (default: the current directory)
//
// Renders History / Model / Permissions with canned injected state — each page
// in both appearances (aqua and dark aqua), six PNGs in all — and exits 0.
// Headless by construction: no TCC prompt, no
// model file, no key, no window that ever lands on a screen, nothing to click.
// It is the visual half of `swift test` — the pages are pure functions of
// `MainWindowModel`, so a snapshot with canned closures is the same code path
// the running app takes.
//
// One known artefact: controls whose fill is an accent-coloured material (the
// switches) come out of the layer render untinted. Their *state* still reads
// correctly from the knob position; only the colour is missing.
//
// It also demonstrates the integration contract, which is the whole of it:
//
//     let store = TranscriptHistoryStore(fileURL: …)
//     let model = MainWindowModel(store: store, actions: MainWindowActions(…))
//     window.contentView = NSHostingView(rootView: MainWindowRootView(model: model))
//
// Deliberately does not depend on WhisperLocal: nothing here should be able to
// load a model, touch Metal, or meet ggml's exit-abort hazard.
import AppKit
import MainWindowUI
import OpenWisperCore
import SwiftUI

// MARK: - Offscreen window

/// AppKit normally drags a window back onto a screen when it is placed. This
/// one stays exactly where it is put, which is how the demo renders a real
/// window without one ever appearing.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Demo

@MainActor
final class WindowDemo: NSObject, NSApplicationDelegate {

    /// Big enough that every page shows its full layout without scrolling —
    /// a snapshot that needed scrolling would hide exactly what it is for.
    private static let snapshotSize = NSSize(width: 1000, height: 1000)
    /// Time given to SwiftUI to lay out and draw before the shutter.
    private static let settleSeconds: TimeInterval = 1.2

    private let outputDir: URL
    private let historyURL: URL
    private let store: TranscriptHistoryStore

    /// The two appearances every page is rendered in. The theme's colors are
    /// all light/dark pairs, so a snapshot set that skipped one appearance
    /// would be blind to half the palette.
    private static let variants: [(suffix: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua),
        ("dark", .darkAqua),
    ]

    private var models: [MainWindowModel] = []
    private var windows: [(name: String, window: NSWindow)] = []

    init(outputDir: URL) {
        self.outputDir = outputDir
        // A throwaway file in /tmp, never the user's real history.
        self.historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwisper-window-demo-\(UUID().uuidString).json")
        Self.writeCannedHistory(to: historyURL)
        // Loading the canned file through the real store is deliberate: it
        // exercises the on-disk format the app actually writes.
        self.store = TranscriptHistoryStore(fileURL: historyURL, isEnabled: true, maxEntries: 200)
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("window-demo — rendering the three pages offscreen (≈1.5 s, exits 0)")
        print("  output: \(outputDir.path)")
        print("  history: \(store.entries.count) canned entries from \(historyURL.lastPathComponent)")

        let actions = Self.cannedActions()
        for page in MainWindowPage.allCases {
            for variant in Self.variants {
                let model = MainWindowModel(store: store, actions: actions, page: page)
                models.append(model)
                windows.append((
                    "window-\(page.rawValue)-\(variant.suffix)",
                    makeWindow(for: model, appearance: variant.appearance)
                ))
            }
        }

        let timer = Timer(timeInterval: Self.settleSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { self.captureAndExit() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func makeWindow(for model: MainWindowModel, appearance: NSAppearance.Name) -> NSWindow {
        // Plain titled chrome, not the real window's full-size-content style:
        // rendering the layer tree of a `.fullSizeContentView` window offscreen
        // comes out scaled and cropped (the titlebar container distorts the
        // geometry). The pages themselves are identical either way; only the
        // 46 pt brand padding reads as a title strip here.
        let window = OffscreenWindow(
            contentRect: NSRect(origin: .zero, size: Self.snapshotSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Defaults.appName
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowRootView(model: model))
        // Parked far outside every display. The window is still ordered in so
        // the hosting view runs a real layout and draw pass; nothing appears
        // because nothing is on a screen.
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
        window.orderFront(nil)
        return window
    }

    // MARK: Capture

    private func captureAndExit() {
        var written: [String] = []
        var failures: [String] = []

        for (name, window) in windows {
            let url = outputDir.appendingPathComponent("\(name).png")
            switch snapshot(window) {
            case .success(let data):
                do {
                    try data.write(to: url, options: .atomic)
                    written.append(url.path)
                } catch {
                    failures.append("\(name): could not write \(url.path) — \(error.localizedDescription)")
                }
            case .failure(let reason):
                failures.append("\(name): \(reason)")
            }
            window.orderOut(nil)
        }

        try? FileManager.default.removeItem(at: historyURL)

        for path in written { print("wrote \(path)") }
        for failure in failures { FileHandle.standardError.write(Data("error: \(failure)\n".utf8)) }

        guard failures.isEmpty else {
            print("window-demo — \(failures.count) page(s) failed to render")
            exit(1)
        }
        print("window-demo — \(written.count) page(s) rendered, exit 0")
        exit(0)
    }

    private enum SnapshotResult {
        case success(Data)
        case failure(String)
    }

    /// Renders the window's content straight out of its **layer tree**, over
    /// the window's own background colour.
    ///
    /// `NSView.cacheDisplay(in:to:)` is the obvious tool here and it is the
    /// wrong one: it walks the `draw(_:)` path, which catches SwiftUI content
    /// that AppKit hosts in real views (a `List`'s table rows, a `Form`'s
    /// scroll view) but misses everything SwiftUI draws into the hosting view's
    /// own layer — page titles, the search field, the footer bar. Those came
    /// out as untouched bitmap. `CALayer.render(in:)` walks the layer tree
    /// instead and gets all of it.
    ///
    /// No screen capture is involved either way, so no Screen Recording
    /// permission is ever requested.
    private func snapshot(_ window: NSWindow) -> SnapshotResult {
        guard let view = window.contentView else { return .failure("no content view") }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let layer = view.layer else { return .failure("content view is not layer-backed") }

        let size = view.bounds.size
        // An offscreen window reports no screen of its own; render at the
        // main display's scale so the snapshots are as crisp as the real thing.
        let scale = window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return .failure("could not allocate a \(size) bitmap") }
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else {
            return .failure("could not build a drawing context")
        }
        NSGraphicsContext.current = context

        // The window background is not part of the content view's drawing, so
        // anything that does not paint its own (the page header, the History
        // footer bar) needs it laid down first or its white-on-dark text reads
        // as white-on-nothing. Dynamic system colours resolve against whichever
        // appearance is drawing, not the window's, hence the wrapper.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }

        let cg = context.cgContext
        cg.saveGState()
        // No explicit scale: `canvas.size = size` already maps points to the
        // retina pixel grid, and the SwiftUI layer tree bakes its own
        // contentsScale into what it renders — adding `scaleBy(scale)` on top
        // drew everything double-sized (visible as a blown-up bottom-left
        // quadrant when this demo first rendered the pure-SwiftUI pages).
        // Layer geometry is y-down; the bitmap context is y-up.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        layer.render(in: cg)
        cg.restoreGState()
        context.flushGraphics()

        guard let data = canvas.representation(using: .png, properties: [:]) else {
            return .failure("could not encode PNG")
        }
        // A window that never rendered produces a valid but nearly empty PNG,
        // which would quietly turn this demo into a no-op. Refuse to call that
        // a pass.
        guard data.count > 4_096 else {
            return .failure("rendered \(data.count) bytes — the page did not draw")
        }
        return .success(data)
    }

    // MARK: Canned state

    /// A dozen entries of varying age, length and engine, written in the store's
    /// own on-disk format so the real loader parses them.
    private static func writeCannedHistory(to url: URL) {
        let now = Date()
        let samples: [(minutesAgo: Double, engine: String, text: String)] = [
            (0.5, "local", "Let's ship the window in Wave D and keep the menu bar exactly as it is."),
            (4, "local", "Sounds good, I'll take a look after lunch."),
            (22, "groq", "Can you pull the quarterly numbers into the deck before the review? I want the retention chart on slide four, and if there's time a one-liner on why churn moved."),
            (61, "local", "Rebase onto main and force-push."),
            (95, "local", "The transcript history is capped at two hundred entries by default, dropping the oldest, and the whole thing lives in a single JSON file you can delete at any time."),
            (180, "openai", "Merci, je regarde ça demain matin."),
            (310, "local", "TODO: check whether the event tap survives a display sleep."),
            (1_440, "local", "Hey — quick one. Do we still need the fallback path for machines without a notch, or has that been folded into the floating pill already?"),
            (1_610, "groq", "Approved."),
            (2_880, "local", "Draft reply: thanks for flagging this, I've reproduced it locally and the fix is small. I'll have a patch up this afternoon and will ping you when it's ready for review."),
            (4_320, "local", "make deps, make model, make install — that's the whole setup."),
            (12_960, "openai", "Remember to renew the domain before the end of the month."),
        ]

        let entries = samples.map { sample in
            TranscriptEntry(
                text: sample.text,
                date: now.addingTimeInterval(-sample.minutesAgo * 60),
                engine: sample.engine
            )
        }

        // Stock `.iso8601`, i.e. *without* the fractional seconds the store
        // writes — so loading this also exercises its fallback date parser,
        // the one that makes a hand-edited history.json still readable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Mixed on purpose: a permission granted, one denied and one never asked;
    /// two of three keys present; a local model that exists. One snapshot set
    /// should show every kind of row the pages can draw.
    private static func cannedActions() -> MainWindowActions {
        MainWindowActions(
            currentEngine: { .local },
            setEngine: { print("  [demo] setEngine(\($0.rawValue))") },
            engineDetail: { "Local · ggml-small.en" },
            localModel: { LocalModelInfo(fileName: "ggml-small.en.bin", byteSize: 487_601_967) },
            apiKeys: { APIKeyPresence(groq: true, openai: false, anthropic: true) },
            isCleanupEnabled: { true },
            setCleanupEnabled: { print("  [demo] setCleanupEnabled(\($0))") },
            cleanupDetail: { "Groq · llama-3.1-8b-instant" },
            isHistoryEnabled: { true },
            setHistoryEnabled: { print("  [demo] setHistoryEnabled(\($0))") },
            permissions: {
                PermissionsSnapshot(
                    microphone: .granted,
                    inputMonitoring: .denied,
                    accessibility: .undetermined
                )
            },
            requestPermission: { print("  [demo] requestPermission(\($0.rawValue))") },
            openConfigFile: { print("  [demo] openConfigFile()") },
            openAppSupportFolder: { print("  [demo] openAppSupportFolder()") },
            openModelsFolder: { print("  [demo] openModelsFolder()") },
            reloadConfig: { print("  [demo] reloadConfig()") }
        )
    }
}

// MARK: - Entry point

/// argv[1], or the working directory. Resolved to an absolute path so the
/// printed lines can be pasted straight into `open`.
private func resolveOutputDir() -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    guard let argument = CommandLine.arguments.dropFirst().first else { return cwd }
    let url = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath, relativeTo: cwd)
    return url.standardizedFileURL
}

let outputDir = resolveOutputDir()
do {
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(
        Data("error: could not create \(outputDir.path) — \(error.localizedDescription)\n".utf8)
    )
    exit(2)
}

// `.accessory`: no Dock icon, never becomes the active app — the same policy the
// shipping app uses, and the reason none of this steals focus.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let demo = MainActor.assumeIsolated { WindowDemo(outputDir: outputDir) }
app.delegate = demo
app.run()
