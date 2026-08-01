// PillController — the AppKit half of the floating pill.
//
// Owns a single borderless, non-activating NSPanel that hosts `PillView`, and
// implements the `RecordingIndicator` contract from OpenWisperCore.
//
// The one hard requirement is unchanged from day one: the pill must never
// disturb the app the user is dictating into. The panel cannot become key or
// main, and it is only ever ordered in with `orderFrontRegardless()`. Input on
// the panel (the ✕ and dragging) works *without* focus precisely because those
// interactions never need key status — see `PillHostView`.
//
// Placement: bottom-centre of the screen under the pointer by default. The
// user can drag the pill anywhere; the position (the pill's bottom-centre
// anchor, in global screen coordinates) is stored in UserDefaults and reused
// for every later show — including across relaunches. If the saved spot is no
// longer on any attached screen, the default placement quietly takes over.
import AppKit
import OpenWisperCore
import SwiftUI
import os

/// Borderless panel for the pill. `.nonactivatingPanel` plus these overrides
/// make it structurally impossible for the pill to steal focus.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit nudges windows out from under the menu bar. The notch-docked pill
    /// must sit flush with the screen's top edge, so opt out of that.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view that owns all pill input: a click on the ✕ cancels, a drag
/// anywhere else on the pill moves it. SwiftUI hit-testing is disabled entirely
/// (`allowsHitTesting(false)` on the root), so the geometry contract in
/// `PillMetrics`/`NotchMetrics` is the single source of truth for what is where.
final class PillHostView: NSHostingView<PillRootView> {
    /// Hit geometry in window coordinates, supplied by the controller — it
    /// differs between the floating and notch presentations. `nil` means the
    /// region does not exist in the current state.
    var cancelRect: () -> CGRect? = { nil }
    var dragRect: () -> CGRect? = { nil }
    var onCancelClick: () -> Void = {}

    /// The drag, run by the controller rather than by `performDrag` so the
    /// notch magnet can act on every frame. Works for both presentations: a
    /// drag that starts on the docked strip pops the pill out of the notch
    /// first. Once `mouseDown` claims the gesture, AppKit routes the whole
    /// sequence here even though the panel can never be key.
    var onDragBegan: () -> Void = {}
    var onDragMoved: () -> Void = {}
    var onDragEnded: () -> Void = {}
    private var isDragging = false

    /// With SwiftUI hit-testing off, `NSHostingView.hitTest` returns nil and
    /// mouse events would never reach this view at all (the original
    /// "✕ doesn't click" bug). Claim every point inside our bounds instead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    /// First click must act even though the panel is never key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let cancel = cancelRect(), cancel.contains(point) {
            onCancelClick()
            return
        }
        if let drag = dragRect(), drag.contains(point) {
            isDragging = true
            NSCursor.closedHand.set()
            onDragBegan()
            return
        }
        // Outside every region (the shadow margin): swallow silently.
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDragMoved()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDragEnded()
        NSCursor.openHand.set()
    }

    // MARK: Pointer tracking
    //
    // `.activeAlways` + `.mouseEnteredAndExited` is the one piece of AppKit
    // tracking that IS documented to work for an inactive app, which is what we
    // are. (`.cursorUpdate` is deliberately absent: Apple only supports it with
    // `.activeInKeyWindow`, and mixing it with `.activeAlways` breaks the whole
    // tracking area — that pairing was the earlier bug.) Cursor *rects* and
    // `cursorUpdate` are useless here for the same activation reason, so the
    // controller decides and sets the cursor; this just tells it to re-evaluate.

    var onPointerActivity: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onPointerActivity() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity() }
    override func mouseExited(with event: NSEvent) { onPointerActivity() }
}

@MainActor
public final class PillController: RecordingIndicator {
    // MARK: Tuning

    /// Per-push smoothing of the incoming level: instant attack, gentle release
    /// relative to the previous *sample* (history bars carry the decay tail).
    private static let levelDecay: Double = 0.72
    /// Silence floor so the newest bars keep a faint flicker while listening.
    private static let shimmerFloor: Double = 0.035
    private static let appearDuration: TimeInterval = 0.15
    private static let disappearDuration: TimeInterval = 0.20
    private static let restoreDuration: TimeInterval = 0.12
    private static let resizeDuration: TimeInterval = 0.16
    /// Matches the collapse spring in `NotchPillView` closely enough that the
    /// window is only removed once the shape is back inside the cutout.
    private static let notchCollapseDuration: TimeInterval = 0.34

    private static let anchorDefaultsKey = "pillAnchor"
    /// Remembers that the user pulled the pill off the notch, so it stays
    /// floating across launches until they drop it back.
    private static let detachedDefaultsKey = "pillDetached"

    // MARK: State

    private let model = PillModel()
    private var panel: PillPanel?
    private var moveObserver: NSObjectProtocol?

    /// Fired when the user clicks the pill's ✕ (RecordingIndicator contract).
    public var onCancel: (() -> Void)?

    /// Dock into the display's notch when the screen under the pointer has one
    /// (`ui.useNotch`). Falls back to the floating pill on notch-less displays.
    public var prefersNotch: Bool = true

    /// Dock to this screen's notch regardless of where the pointer is. Exists
    /// for the demo/QA harness, which has to exercise the docked presentation
    /// without moving the user's pointer onto the built-in display.
    public var notchScreenOverride: NSScreen?

    /// The notch the pill is currently docked in, if any. Decided at each
    /// appearance, since the pointer may be on a different display than before.
    private var dockedNotch: NotchInfo?

    /// The user pulled the pill off the notch; keep it floating until they drop
    /// it back on. Persisted.
    private lazy var isDetached: Bool = UserDefaults.standard.bool(forKey: Self.detachedDefaultsKey)

    private var pendingHide: DispatchWorkItem?
    private var fadeGeneration = 0
    private var isPresented = false
    private var lastLevel: Double = 0
    /// True while we are animating/setting the frame ourselves, so the
    /// `didMove` observer only records *user* drags.
    private var programmaticMove = false

    /// Which part of the pill the pointer is over. Drives both the cursor and
    /// the ✕'s hover highlight.
    private enum CursorRegion { case outside, body, cancel }
    private var cursorRegion: CursorRegion = .outside
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// The cursor currently pushed on the app's stack, if any. Kept so pushes
    /// stay balanced (exactly one outstanding at a time).
    private var pushedCursor: NSCursor?

    public init() {}

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    /// Builds the panel and runs one offscreen layout pass so the first real
    /// `show(_:)` doesn't pay window-creation + SwiftUI-graph cost (the "first
    /// open feels slow" fix). Call once at app launch; safe to call again.
    public func prewarm() {
        let panel = ensurePanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    // MARK: - RecordingIndicator

    public func show(_ state: PillState) {
        pendingHide?.cancel()
        pendingHide = nil
        fadeGeneration &+= 1

        let panel = ensurePanel()
        // `screen == nil` also covers "was visible on a display that has since
        // been disconnected" — that needs a fresh placement like a first show.
        let appearing = !panel.isVisible || panel.screen == nil

        // Placement is decided per appearance: the pointer may be on a
        // different display than last time.
        if appearing {
            dockedNotch = (prefersNotch && !isDetached)
                ? (notchScreenOverride.flatMap(NotchGeometry.notch(on:)) ?? NotchGeometry.notchUnderPointer())
                : nil
            model.isNotchDocked = dockedNotch != nil
            model.notchSize = dockedNotch.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        }

        let stateChanged = model.state != state
        if stateChanged {
            if case .recording = state {
                resetLevel()
                model.recordingStartedAt = Date()
            }
            model.state = state
        } else if appearing, case .recording = state {
            resetLevel()
            model.recordingStartedAt = Date()
        }

        isPresented = true
        model.isOnScreen = true

        if appearing {
            present(panel, for: state)
        } else {
            if stateChanged, dockedNotch == nil {
                resize(panel, for: state)
            }
            if panel.alphaValue < 1 {
                // Interrupted a fade-out: fade straight back to opaque.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.restoreDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        }

        // Cursor tracking only runs while the pill is on screen.
        startCursorTracking()
        updateCursorForPointer()
    }

    /// Feeds the live input level (0...1): shifts the scrolling history left and
    /// appends the newest sample. Called at ≤ 20 Hz, on the main actor.
    public func updateLevel(_ level: Float) {
        let clamped = level.isFinite ? Double(min(max(level, 0), 1)) : 0
        let smoothed = max(clamped, lastLevel * Self.levelDecay)
        lastLevel = smoothed

        // A whisper of noise on the floor keeps silent stretches alive without
        // ever reading as actual signal.
        let value = max(smoothed, Self.shimmerFloor + Double.random(in: 0...0.02))
        var levels = model.levels
        if !levels.isEmpty { levels.removeFirst() }
        levels.append(value)
        model.levels = levels
    }

    public func hide(after seconds: TimeInterval) {
        pendingHide?.cancel()
        pendingHide = nil
        guard isPresented, panel != nil else { return }

        guard seconds > 0 else {
            beginFadeOut()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.beginFadeOut()
            }
        }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: - Placement & persistence

    /// The pill's bottom-centre anchor for the current panel frame.
    private func anchor(of panel: PillPanel) -> CGPoint {
        CGPoint(x: panel.frame.midX, y: panel.frame.minY + PillMetrics.shadowPadding)
    }

    /// Panel frame that puts the pill's bottom-centre at `anchor`.
    private func frame(for state: PillState, anchoredAt anchor: CGPoint) -> NSRect {
        let size = PillMetrics.panelSize(for: state)
        return NSRect(
            x: (anchor.x - size.width / 2).rounded(),
            y: (anchor.y - PillMetrics.shadowPadding).rounded(),
            width: size.width,
            height: size.height
        )
    }

    /// Where to place the pill: the user's remembered spot when it is still on
    /// a connected screen, else bottom-centre of the screen under the pointer.
    private func resolvedAnchor() -> CGPoint {
        if let saved = savedAnchor() {
            let tolerant = NSScreen.screens.contains { screen in
                screen.visibleFrame.insetBy(dx: -24, dy: -24).contains(saved)
            }
            if tolerant { return saved }
            Log.ui.info("Pill: saved position is off every screen — using the default placement")
        }
        return defaultAnchor()
    }

    private func defaultAnchor() -> CGPoint {
        let screen = targetScreen()
        guard let visible = screen?.visibleFrame else { return CGPoint(x: 600, y: 60) }
        return CGPoint(x: visible.midX, y: visible.minY + PillMetrics.bottomMargin)
    }

    private func savedAnchor() -> CGPoint? {
        guard let stored = UserDefaults.standard.array(forKey: Self.anchorDefaultsKey) as? [Double],
              stored.count == 2, stored[0].isFinite, stored[1].isFinite
        else { return nil }
        return CGPoint(x: stored[0], y: stored[1])
    }

    private func saveAnchor(_ anchor: CGPoint) {
        UserDefaults.standard.set([Double(anchor.x), Double(anchor.y)], forKey: Self.anchorDefaultsKey)
    }

    private func saveDetached(_ detached: Bool) {
        UserDefaults.standard.set(detached, forKey: Self.detachedDefaultsKey)
    }

    // MARK: - Presentation

    private func present(_ panel: PillPanel, for state: PillState) {
        if let notch = dockedNotch {
            presentDocked(panel, in: notch)
            return
        }

        // A floating pill whose remembered spot is inside a notch's capture
        // zone belongs to that notch: presenting it there would hide it behind
        // the cutout. Convert to docked instead.
        if prefersNotch {
            let anchor = resolvedAnchor()
            let probe = CGRect(
                x: anchor.x - PillMetrics.standardWidth / 2,
                y: anchor.y,
                width: PillMetrics.standardWidth,
                height: PillMetrics.height
            )
            for screen in NSScreen.screens {
                if let notch = NotchGeometry.notch(on: screen),
                   captureZone(for: notch).intersects(probe) {
                    dockedNotch = notch
                    isDetached = false
                    saveDetached(false)
                    model.isNotchDocked = true
                    model.notchSize = CGSize(width: notch.width, height: notch.height)
                    presentDocked(panel, in: notch)
                    return
                }
            }
        }

        let endFrame = frame(for: state, anchoredAt: resolvedAnchor())
        var startFrame = endFrame
        startFrame.origin.y -= PillMetrics.riseOffset

        programmaticMove = true
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        // Never `makeKey…` — this is what keeps the dictated-into app focused.
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticMove = false }
        })
    }

    /// Docked presentation: the window is pinned over the notch, flush with the
    /// screen's top edge, and the *shape inside it* animates from the exact
    /// notch silhouette to the expanded strip. Nothing about the window moves,
    /// so the growth reads as the cutout itself opening.
    private func presentDocked(_ panel: PillPanel, in notch: NotchInfo) {
        let size = NotchMetrics.windowSize(notchHeight: notch.height)
        let frame = NSRect(
            x: (notch.centerX - size.width / 2).rounded(),
            y: (notch.screenFrame.maxY - size.height).rounded(),
            width: size.width,
            height: size.height
        )

        programmaticMove = true
        model.isExpanded = false          // start collapsed, exactly notch-shaped
        panel.alphaValue = 1
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        programmaticMove = false

        // Next runloop turn so SwiftUI renders the collapsed state first and
        // the spring actually has somewhere to travel from.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isPresented, self.dockedNotch != nil else { return }
                self.model.isExpanded = true
            }
        }
    }

    /// Animates the panel to the new state's size, keeping the pill anchored at
    /// its current bottom-centre (so an error widening in place stays where the
    /// user put it).
    private func resize(_ panel: PillPanel, for state: PillState) {
        let target = frame(for: state, anchoredAt: anchor(of: panel))
        guard target != panel.frame else { return }

        programmaticMove = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticMove = false }
        })
    }

    private func beginFadeOut() {
        pendingHide = nil
        guard let panel, isPresented else { return }

        isPresented = false
        fadeGeneration &+= 1
        let generation = fadeGeneration

        // Docked: retract into the cutout instead of fading — the shape shrinks
        // back to the notch silhouette and only then is the window removed.
        if dockedNotch != nil {
            model.isExpanded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.notchCollapseDuration) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.fadeGeneration == generation else { return }
                    self.panel?.orderOut(nil)
                    self.model.isOnScreen = false
                    self.resetLevel()
                    self.stopCursorTracking()
                }
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.disappearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.panel?.orderOut(nil)
                self.model.isOnScreen = false
                self.resetLevel()
                self.stopCursorTracking()
            }
        })
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: - Hit regions
    //
    // Window coordinates (bottom-left origin), and placement-dependent: the
    // floating pill fills a window that hugs it, while the docked pill's strip
    // hangs below the cutout inside a larger window.

    /// The ✕ zone, or nil in states that do not show it.
    private func currentCancelRect() -> CGRect? {
        guard PillMetrics.showsCancel(for: model.state) else { return nil }
        if let notch = dockedNotch, let panel {
            // Only clickable once the strip has actually grown out.
            guard model.isExpanded else { return nil }
            return NotchMetrics.cancelHitRect(windowSize: panel.frame.size, notchHeight: notch.height)
        }
        return PillMetrics.cancelHitRect(for: model.state)
    }

    /// The drag region. Floating: the capsule itself. Docked: the strip minus
    /// the ✕ — grabbing it yanks the pill out of the notch (see
    /// `beginDrag`).
    private func currentDragRect() -> CGRect? {
        guard let notch = dockedNotch, let panel else {
            return PillMetrics.pillRect(for: model.state)
        }
        guard model.isExpanded else { return nil }
        let content = NotchMetrics.contentRect(windowSize: panel.frame.size, notchHeight: notch.height)
        guard let cancel = currentCancelRect() else { return content }
        // Everything left of the ✕ zone.
        return CGRect(
            x: content.minX,
            y: content.minY,
            width: max(0, cancel.minX - content.minX),
            height: content.height
        )
    }


    /// The generous capture zone around a notch: drop (or park) the pill
    /// anywhere in here and it belongs to the notch. Rect-based rather than a
    /// centre-distance so a pill overlapping the cutout can never miss it —
    /// which previously let the pill hide *behind* the notch, and dragging it
    /// out again looked like dragging the notch itself.
    private func captureZone(for notch: NotchInfo) -> CGRect {
        notch.rect.insetBy(dx: -NotchMetrics.redockDistance, dy: 0)
            .union(notch.rect.offsetBy(dx: 0, dy: -NotchMetrics.redockDistance))
    }

    /// The pill's capsule rect in global screen coordinates.
    private func pillScreenRect(of panel: PillPanel) -> CGRect {
        let local = PillMetrics.pillRect(for: model.state)
        return CGRect(
            x: panel.frame.minX + local.minX,
            y: panel.frame.minY + local.minY,
            width: local.width,
            height: local.height
        )
    }

    /// The notch this panel should consider: the one on the screen the panel is
    /// actually on (falling back to the pointer's screen before the first show).
    private func relevantNotch(for panel: PillPanel) -> NotchInfo? {
        if let override = notchScreenOverride.flatMap(NotchGeometry.notch(on:)) { return override }
        if let screen = panel.screen, let notch = NotchGeometry.notch(on: screen) { return notch }
        return NotchGeometry.notchUnderPointer()
    }

    // MARK: Drag, with the notch magnet
    //
    // One gesture for both presentations. The pill is dragged by the controller
    // rather than by `performDrag`, so the notch can exert a pull on every
    // frame: get close and the pill is drawn in and docks on release, which is
    // what makes it impossible to park it behind the cutout, where there are no
    // pixels to draw it in.
    //
    // Grabbing the *docked* strip simply hands the pill over as the floating
    // capsule, right where the strip was, and the drag continues from there —
    // no tension, no threshold to fight, no animation to get in the way. It
    // comes out as soon as the hand moves, exactly like dragging any other
    // object.

    private var grabOffset: CGSize = .zero
    /// The notch that will claim the pill when the button comes up.
    private var pendingDock: NotchInfo?
    /// The magnet is off for a drag that just pulled the pill out of the notch,
    /// or it would drag it straight back in. It arms the moment the pointer
    /// clears the magnet's reach.
    private var magnetArmed = true
    /// A press on the docked strip that has not moved yet. The pill only leaves
    /// the notch once the hand actually goes somewhere, so a plain click on the
    /// strip never undocks it.
    private var dockedGrab: (notch: NotchInfo, mouse: CGPoint)?
    /// Movement before a press on the strip becomes a pull-out.
    private static let detachThreshold: CGFloat = 4

    /// Where the pill's centre sits when docked: just under the cutout.
    private func dockedCentre(for notch: NotchInfo) -> CGPoint {
        CGPoint(
            x: notch.centerX,
            y: notch.rect.minY - PillMetrics.height / 2 - 4
        )
    }

    private func beginDrag() {
        guard let panel else { return }
        pendingDock = nil
        if let notch = dockedNotch {
            dockedGrab = (notch, NSEvent.mouseLocation)
            magnetArmed = false
            return
        }
        dockedGrab = nil
        magnetArmed = true
        grabOffset = pointerOffset(in: panel, from: NSEvent.mouseLocation)
    }

    private func updateDrag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation

        if let grab = dockedGrab {
            guard hypot(mouse.x - grab.mouse.x, mouse.y - grab.mouse.y) >= Self.detachThreshold else { return }
            dockedGrab = nil
            detach(panel, from: grab.notch)
            // Measured from where the hand actually grabbed, so the pill does
            // not jump under the pointer on its way out.
            grabOffset = pointerOffset(in: panel, from: grab.mouse)
        }

        var centre = CGPoint(
            x: mouse.x + grabOffset.width,
            y: mouse.y + grabOffset.height
        )

        pendingDock = nil
        if prefersNotch, let (notch, home, distance) = nearestNotchHome(to: centre) {
            if !magnetArmed, distance > NotchMetrics.magnetRadius { magnetArmed = true }
            if magnetArmed, distance < NotchMetrics.magnetRadius {
                // Ease the attraction in so it grabs rather than teleports.
                let closeness = 1 - distance / NotchMetrics.magnetRadius
                let strength = NotchMetrics.magnetStrength * pow(closeness, 1.4)
                centre.x += (home.x - centre.x) * strength
                centre.y += (home.y - centre.y) * strength
                pendingDock = notch
            }
        }

        let anchor = CGPoint(x: centre.x, y: centre.y - PillMetrics.height / 2)
        programmaticMove = true
        panel.setFrame(frame(for: model.state, anchoredAt: anchor), display: true)
        programmaticMove = false
        if pendingDock == nil { saveAnchor(anchor) }
    }

    private func endDrag() {
        guard let panel else { return }
        // Pressed the strip and let go without moving: it stays docked.
        if dockedGrab != nil {
            dockedGrab = nil
            return
        }
        if let notch = pendingDock {
            pendingDock = nil
            dock(panel, into: notch)
            return
        }
        // A drag that pulled the pill out and never got clear of the notch
        // leaves it exactly where the user let go — snapping back would make
        // the notch feel like it never let go.
        guard magnetArmed else { return }
        redockIfNearNotch()
    }

    /// The notch whose docked position is closest to `centre`, with that
    /// position and the distance to it.
    private func nearestNotchHome(to centre: CGPoint) -> (NotchInfo, CGPoint, CGFloat)? {
        var best: (NotchInfo, CGPoint, CGFloat)?
        for screen in NSScreen.screens {
            guard let notch = notchScreenOverride.flatMap(NotchGeometry.notch(on:))
                ?? NotchGeometry.notch(on: screen) else { continue }
            let home = dockedCentre(for: notch)
            let distance = hypot(centre.x - home.x, centre.y - home.y)
            if best == nil || distance < best!.2 { best = (notch, home, distance) }
        }
        return best
    }

    /// Hands the docked pill over to the floating presentation, in place: the
    /// capsule appears immediately below the cutout, where the strip's own
    /// content already was.
    private func detach(_ panel: PillPanel, from notch: NotchInfo) {
        dockedNotch = nil
        isDetached = true
        saveDetached(true)
        model.isNotchDocked = false
        model.isExpanded = false

        let centre = dockedCentre(for: notch)
        let anchor = CGPoint(x: centre.x, y: centre.y - PillMetrics.height / 2)
        programmaticMove = true
        panel.setFrame(frame(for: model.state, anchoredAt: anchor), display: true)
        programmaticMove = false
        saveAnchor(anchor)
        Log.ui.info("Pill: pulled out of the notch")
    }

    /// The pointer's hold on the pill, clamped so the pointer always lands on
    /// the capsule: the docked strip is three times the pill's width, and
    /// grabbing its far edge would otherwise leave the pill dangling well off
    /// to one side.
    private func pointerOffset(in panel: PillPanel, from mouse: CGPoint) -> CGSize {
        let centre = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + PillMetrics.shadowPadding + PillMetrics.height / 2
        )
        return CGSize(
            width: clamp(centre.x - mouse.x, PillMetrics.pillWidth(for: model.state) / 2 - 12),
            height: clamp(centre.y - mouse.y, PillMetrics.height / 2 - 8)
        )
    }

    private func clamp(_ value: CGFloat, _ limit: CGFloat) -> CGFloat {
        min(max(value, -max(limit, 0)), max(limit, 0))
    }

    /// After a floating drag, re-dock if the user parked the pill in the
    /// notch's capture zone.
    private func redockIfNearNotch() {
        guard isDetached, prefersNotch, let panel else { return }
        guard let notch = relevantNotch(for: panel) else { return }
        guard captureZone(for: notch).intersects(pillScreenRect(of: panel)) else { return }
        dock(panel, into: notch)
    }

    private func dock(_ panel: PillPanel, into notch: NotchInfo) {
        isDetached = false
        saveDetached(false)
        Log.ui.info("Pill: absorbed by the notch — re-docking")

        // Re-present docked, from scratch, so the expansion animation runs.
        panel.orderOut(nil)
        dockedNotch = notch
        model.isNotchDocked = true
        model.notchSize = CGSize(width: notch.width, height: notch.height)
        presentDocked(panel, in: notch)
    }

    // MARK: QA harness hooks (pill-demo only)
    //
    // The demo cannot move the real pointer (that needs Accessibility), so it
    // drives placement directly — through the same calls the mouse path uses.

    /// Clears remembered placement (anchor + detached flag) so a scripted run
    /// starts from the default docked state regardless of previous runs.
    public func demoResetPlacement() {
        UserDefaults.standard.removeObject(forKey: Self.anchorDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.detachedDefaultsKey)
        isDetached = false
    }

    /// Pops the pill out of the notch exactly as grabbing the strip does.
    public func demoPullOutOfNotch() {
        guard let panel, let notch = dockedNotch else { return }
        detach(panel, from: notch)
        magnetArmed = false
    }

    /// Moves the floating pill's centre, in global screen coordinates — the
    /// scripted stand-in for a drag.
    public func demoMovePill(to centre: CGPoint) {
        guard let panel, dockedNotch == nil else { return }
        let anchor = CGPoint(x: centre.x, y: centre.y - PillMetrics.height / 2)
        programmaticMove = true
        panel.setFrame(frame(for: model.state, anchoredAt: anchor), display: true)
        programmaticMove = false
        saveAnchor(anchor)
    }

    // MARK: - Cursor
    //
    // AppKit's cursor machinery (cursor rects, `cursorUpdate`, mouse-moved
    // delivery) only runs for an *active* app with a *key* window. This app is
    // never active and this panel can never be key, so the cursor is driven
    // here instead, from event monitors that fire regardless of activation:
    // the global monitor sees moves delivered to other apps, the local one sees
    // moves delivered to us, and between them every move is covered.
    //
    // Strict rule: the cursor is only ever touched while the pointer is inside
    // our own panel, plus exactly one reset on the way out. Setting it anywhere
    // else would stomp on other apps' cursors (an I-beam over their text, say).

    private func startCursorTracking() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { _ in
            MainActor.assumeIsolated { PillController.refreshCursor(for: self) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { event in
            MainActor.assumeIsolated { PillController.refreshCursor(for: self) }
            return event
        }
    }

    private func stopCursorTracking() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        leaveCursorRegion()
    }

    /// Static shim so the monitor closures don't capture `self` strongly.
    private static func refreshCursor(for controller: PillController?) {
        controller?.updateCursorForPointer()
    }

    private func updateCursorForPointer() {
        guard let panel, panel.isVisible, panel.alphaValue > 0.05 else {
            leaveCursorRegion()
            return
        }

        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else {
            leaveCursorRegion()
            return
        }

        // Panel coordinates: borderless, so the content view's space is the
        // panel's own, bottom-left origin.
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)

        let region: CursorRegion
        if let cancel = currentCancelRect(), cancel.contains(local) {
            region = .cancel
        } else if let drag = currentDragRect(), drag.contains(local) {
            region = .body
        } else {
            region = .outside      // the shadow margin
        }

        if region != cursorRegion {
            cursorRegion = region
            let hovering = region == .cancel
            if model.hoveringCancel != hovering { model.hoveringCancel = hovering }
            Log.ui.info("Pill hover region: \(String(describing: region), privacy: .public)")
        }

        switch region {
        case .cancel:
            applyCursor(.pointingHand)
        case .body:
            // A button is held: this is a drag in progress.
            applyCursor(NSEvent.pressedMouseButtons != 0 ? .closedHand : .openHand)
        case .outside:
            applyCursor(nil)
        }
    }

    /// Installs `cursor` as the app's cursor, or clears it with `nil`.
    ///
    /// Both halves matter: `push()` puts it on the app's cursor stack (so it
    /// survives AppKit's own cursor bookkeeping), and `set()` re-asserts it on
    /// every move (a background app's cursor is otherwise reset constantly).
    /// Pushes are strictly balanced — one at a time, always popped on the way
    /// out — so the cursor can never get stuck.
    private func applyCursor(_ cursor: NSCursor?) {
        guard let cursor else {
            if pushedCursor != nil {
                NSCursor.pop()
                pushedCursor = nil
            }
            NSCursor.arrow.set()
            return
        }
        if pushedCursor !== cursor {
            if pushedCursor != nil { NSCursor.pop() }
            cursor.push()
            pushedCursor = cursor
        }
        cursor.set()
    }

    /// One reset as the pointer leaves the pill; never touches the cursor again
    /// until it comes back.
    private func leaveCursorRegion() {
        guard cursorRegion != .outside else { return }
        cursorRegion = .outside
        if model.hoveringCancel { model.hoveringCancel = false }
        applyCursor(nil)
    }

    private func resetLevel() {
        lastLevel = 0
        model.levels = Array(repeating: 0, count: PillMetrics.historyLength)
    }

    // MARK: - Panel

    private func ensurePanel() -> PillPanel {
        if let panel { return panel }

        let panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: PillMetrics.panelSize(for: .recording)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // Interactive since the redesign: ✕ cancels, dragging moves. Clicks on
        // it never activate OpenWisper (`.nonactivatingPanel`) and never focus
        // the panel (`canBecomeKey == false`) — the target app keeps its cursor.
        panel.ignoresMouseEvents = false
        // Needed for the cursor affordances: the tracking area's mouseMoved
        // events only flow to a non-key panel when this is on.
        panel.acceptsMouseMovedEvents = true
        // Dragging is routed manually in `PillHostView.mouseDown` so only the
        // capsule itself drags, not the transparent shadow margin.
        panel.isMovableByWindowBackground = false

        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // We manage the cursor by hand (see "Cursor"). Without this, AppKit
        // re-evaluates this window's cursor rects after every event and stomps
        // whatever we set — and for an inactive app those rects resolve to the
        // plain arrow, which is exactly the "cursor never changes" symptom.
        panel.disableCursorRects()
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.alphaValue = 0

        let host = PillHostView(rootView: PillRootView(model: model))
        host.cancelRect = { [weak self] in self?.currentCancelRect() }
        host.dragRect = { [weak self] in self?.currentDragRect() }
        host.onDragBegan = { [weak self] in self?.beginDrag() }
        host.onDragMoved = { [weak self] in self?.updateDrag() }
        host.onDragEnded = { [weak self] in self?.endDrag() }
        host.onCancelClick = { [weak self] in
            Log.ui.info("Pill: cancel clicked")
            self?.onCancel?()
        }
        host.onPointerActivity = { [weak self] in
            self?.updateCursorForPointer()
        }
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        // The panel's frame is driven from here; SwiftUI must never resize it.
        host.sizingOptions = []
        panel.contentView = host

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // Only user drags: our own animations set `programmaticMove`.
                guard !self.programmaticMove, panel.isVisible else { return }
                self.saveAnchor(self.anchor(of: panel))
            }
        }

        self.panel = panel
        return panel
    }
}
