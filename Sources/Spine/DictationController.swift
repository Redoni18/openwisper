import Foundation
import OpenWisperCore

/// The dictation state machine: raw hotkey events in, inserted text out.
///
/// `HotkeyListener` reports nothing but physical down/up (plus an esc cancel);
/// all three `hotkey.mode` behaviours are decided here.
///
/// ```
/// hold    down ─▶ recording ─up─▶ processing ─▶ idle
///
/// toggle  down ─▶ recording          down ─▶ processing ─▶ idle
///
/// flow    down ─▶ recording ─┬─ up at/after minHoldMs ─▶ processing ─▶ idle
///                            │
///                            └─ up before minHoldMs ─▶ tapWait
///                                   ├─ 2nd down inside doubleTapWindowMs ─▶ locked
///                                   │      (same recording, hands-free; the next
///                                   │       down stops + processes it)
///                                   └─ window expires ─▶ discard (accidental tap)
///
/// esc     ─▶ idle, nothing inserted, from any of the above
/// ```
///
/// Everything here runs on the main actor. The blocking half of an utterance
/// (transcribe → clean → insert) lives in a `Task` that owns a snapshot of the
/// engine, cleaner and config it started with, so the user can begin the next
/// utterance — or switch engines from the menu bar — while the previous one is
/// still in flight.
@MainActor
public final class DictationController: HotkeyListenerDelegate {

    /// Clips shorter than this are accidental taps regardless of hold time.
    private static let minimumClipSeconds: TimeInterval = 0.4

    private static let successHideDelay: TimeInterval = 0.8
    private static let errorHideDelay: TimeInterval = 2.5
    private static let emptyHideDelay: TimeInterval = 1.5
    private static let permissionHideDelay: TimeInterval = 3.0

    /// Longest cleanup budget we will honour, so a nonsense config value can
    /// never wedge an utterance.
    private static let cleanupTimeoutBounds: ClosedRange<TimeInterval> = 0.1...120

    /// Bounds on `hotkey.doubleTapWindowMs`, for the same reason: the tap-wait
    /// window holds the microphone open, so a nonsense value must not be able to
    /// leave it open indefinitely. 0 is legal and simply disables the lock.
    private static let tapWaitWindowBounds: ClosedRange<Int> = 0...5_000

    // MARK: Live-rewirable state (menu bar / integrator)

    /// Master switch. Turning it off mid-recording cancels the recording.
    public var isEnabled: Bool = true {
        didSet {
            guard !isEnabled, isRecording else { return }
            Log.app.info("Dictation disabled mid-recording — cancelling")
            cancelRecording()
        }
    }

    /// Swapped when the user picks a different engine. The change takes effect
    /// from the next utterance; in-flight utterances keep the engine they began with.
    public var transcriber: Transcriber

    /// nil when no cleanup provider is configured (offline mode).
    public var cleaner: TranscriptCleaner?

    /// Re-read at the start of every utterance, so config edits apply live.
    public var config: AppConfig

    /// Fires on the main actor whenever recording starts or stops. The
    /// integrator forwards it to `HotkeyListener.isSessionActive` so esc can
    /// cancel in toggle mode.
    public var recordingStateChanged: ((Bool) -> Void)?

    // MARK: Permission seams

    /// Overridable so tests (and any integrator that owns its own onboarding
    /// flow) can drive the permission gate. Defaults to the live TCC status.
    public var microphoneStatus: () -> PermissionStatus = { Permissions.microphone }

    /// Overridable companion to `microphoneStatus`. The completion is delivered
    /// on the main thread.
    public var requestMicrophoneAccess: MicrophoneAccessRequest = { completion in
        Permissions.requestMicrophone(completion)
    }

    public typealias MicrophoneAccessRequest = (@escaping (Bool) -> Void) -> Void

    // MARK: Collaborators

    private let recorder: AudioRecorder
    private let inserter: TextInserter
    private let indicator: RecordingIndicator

    // MARK: Machine state

    public private(set) var isRecording = false

    private var recordingStartedAt: TimeInterval = 0
    private var isRequestingMicrophone = false

    /// Whoever most recently took over the pill owns it. Overlapping utterances
    /// each carry their token and silently skip pill updates once a newer
    /// recording or utterance has taken over — a finishing utterance must never
    /// hide the pill of the one being recorded right now.
    private var indicatorToken = 0

    /// The most recent utterance's pipeline, retained so the pill's ✕ can
    /// abandon it mid-transcription. Older overlapping utterances are not
    /// tracked — the ✕ always targets what the pill is showing.
    private var activePipeline: (token: Int, task: Task<Void, Never>)?

    // MARK: Hotkey mode

    private enum HotkeyMode: String {
        case flow, hold, toggle
    }

    /// The last unrecognised `hotkey.mode` string we complained about, so a live
    /// config reload gets one log line rather than one per keystroke.
    private var reportedUnknownMode: String?

    /// Re-read per event, so a config reload changes modes without a rebuild.
    /// Anything unrecognised is `flow` — the default — and says so once.
    private func resolvedMode() -> HotkeyMode {
        let raw = config.hotkey.mode.trimmingCharacters(in: .whitespaces).lowercased()
        if let mode = HotkeyMode(rawValue: raw) {
            reportedUnknownMode = nil
            return mode
        }
        if reportedUnknownMode != raw {
            reportedUnknownMode = raw
            let spec = config.hotkey.mode
            Log.hotkey.error("Unknown hotkey.mode \"\(spec, privacy: .public)\" — falling back to flow")
        }
        return .flow
    }

    // MARK: Flow-mode phase machine

    /// Where a `flow`-mode interaction currently is. Only `flow` uses it; `hold`
    /// and `toggle` leave it at `.idle` throughout.
    ///
    /// Every phase but `.idle` and `.drainUp` has a live recording behind it,
    /// and the recording spans the *whole* interaction — one continuous clip
    /// from the very first press, so locking never loses the words spoken
    /// between the first tap and the second.
    private enum FlowPhase {
        /// Nothing in progress.
        case idle
        /// The key is down and we do not yet know whether this is a hold or a tap.
        case pressed
        /// Released before `minHoldMs`: still recording, waiting out
        /// `doubleTapWindowMs` to see whether a second tap locks the session.
        case tapWait
        /// Locked hands-free, but the *locking* press is still physically down —
        /// its release must be swallowed rather than read as a hold-release.
        case lockedKeyDown
        /// Locked hands-free with no key held. The next down stops and processes.
        case locked
        /// The press that stopped a locked session is still down; its release
        /// must be swallowed and must not arm anything new.
        case drainUp
    }

    private var flowPhase: FlowPhase = .idle

    /// The pending tap-wait window. A `Task` rather than a `Timer` so it is
    /// cancelable, inherits this main actor, and needs no run loop.
    private var tapWaitTask: Task<Void, Never>?

    /// Bumped by every arm/cancel so a window that fired the instant it was
    /// cancelled cannot still act.
    private var tapWaitGeneration = 0

    // MARK: Init

    public init(
        config: AppConfig,
        recorder: AudioRecorder,
        transcriber: Transcriber,
        cleaner: TranscriptCleaner?,
        inserter: TextInserter,
        indicator: RecordingIndicator
    ) {
        self.config = config
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter
        self.indicator = indicator

        // The pill's ✕: same abandon semantics whether we are still recording
        // or already transcribing.
        indicator.onCancel = { [weak self] in
            self?.cancelActiveWork()
        }
    }

    // MARK: HotkeyListenerDelegate

    public func hotkeyDown() {
        guard isEnabled else { return }
        switch resolvedMode() {
        case .hold:
            // A no-op unless `hotkey.mode` was edited out of flow mid-session,
            // in which case a stale phase must not outlive the switch. Hold and
            // toggle behave identically either way.
            resetFlow()
            beginRecording()

        case .toggle:
            resetFlow()
            if isRecording {
                finishRecording(enforceMinimumHold: false)
            } else {
                beginRecording()
            }

        case .flow:
            flowHotkeyDown()
        }
    }

    public func hotkeyUp() {
        // Deliberately *not* gated on `isEnabled`: a release still has to be
        // accounted for, or disabling mid-press would strand the phase machine
        // waiting for an up that has already happened. Nothing here can start a
        // recording, and disabling already cancelled any live one.
        switch resolvedMode() {
        case .hold:
            guard isRecording else { return }
            finishRecording(enforceMinimumHold: true)

        case .toggle:
            // The release is meaningless; the next press stops us.
            return

        case .flow:
            flowHotkeyUp()
        }
    }

    public func hotkeyCanceled() {
        // Clear the hands-free bookkeeping first and unconditionally: an esc
        // that lands between a press and its release must not leave a phase
        // behind, even when there is no recording left to cancel.
        resetFlow()
        guard isRecording else { return }
        Log.app.debug("Dictation cancelled by the user")
        cancelRecording()
    }

    // MARK: Flow mode

    /// `flow` press. `.lockedKeyDown` and `.drainUp` are the two phases that owe
    /// us a release; if a press arrives instead, the release was lost (a listener
    /// restart mid-press is the realistic way) and we treat the phase as its
    /// key-up equivalent rather than stranding the machine.
    private func flowHotkeyDown() {
        switch flowPhase {
        case .idle, .drainUp:
            beginRecording()
            // A refused press (mic gate, recorder failure) must not arm a phase.
            flowPhase = isRecording ? .pressed : .idle

        case .tapWait:
            // Second tap inside the window: lock hands-free. The recording has
            // been running since the *first* press and simply keeps going.
            cancelTapWaitWindow()
            guard isRecording else {
                flowPhase = .idle
                return
            }
            flowPhase = .lockedKeyDown
            Log.hotkey.debug("Flow: double tap — locked hands-free")

        case .locked, .lockedKeyDown:
            // Stop the hands-free session. Its release is drained below so it
            // cannot start a new recording or open a new tap-wait window.
            flowPhase = .drainUp
            guard isRecording else { return }
            Log.hotkey.debug("Flow: press while locked — stopping")
            finishRecording(enforceMinimumHold: false)

        case .pressed:
            // Physically impossible from the listener (down/up strictly
            // alternate). Keep recording; the release still decides.
            Log.hotkey.debug("Flow: repeated press while already held — ignored")
        }
    }

    /// `flow` release.
    private func flowHotkeyUp() {
        switch flowPhase {
        case .pressed:
            guard isRecording else {
                flowPhase = .idle
                return
            }
            let heldMs = (Date.timeIntervalSinceReferenceDate - recordingStartedAt) * 1000
            if heldMs >= Double(config.hotkey.minHoldMs) {
                // Classic push-to-talk: identical to `hold` mode from here.
                flowPhase = .idle
                finishRecording(enforceMinimumHold: true)
            } else {
                flowPhase = .tapWait
                armTapWaitWindow()
            }

        case .lockedKeyDown:
            // The locking tap's own release: swallowed, recording continues.
            flowPhase = .locked

        case .drainUp:
            // The release of the press that stopped a locked session.
            flowPhase = .idle

        case .idle, .tapWait, .locked:
            // No key was down as far as this machine is concerned.
            return
        }
    }

    /// Starts (or restarts) the window in which a second tap locks the session.
    private func armTapWaitWindow() {
        tapWaitGeneration += 1
        let generation = tapWaitGeneration
        tapWaitTask?.cancel()

        let milliseconds = min(
            max(config.hotkey.doubleTapWindowMs, DictationController.tapWaitWindowBounds.lowerBound),
            DictationController.tapWaitWindowBounds.upperBound
        )
        Log.hotkey.debug("Flow: tap — \(milliseconds, privacy: .public)ms to double-tap for hands-free")

        // Created from the main actor, so the body runs on it too.
        tapWaitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.tapWaitWindowExpired(generation: generation)
        }
    }

    private func cancelTapWaitWindow() {
        tapWaitGeneration += 1
        tapWaitTask?.cancel()
        tapWaitTask = nil
    }

    /// No second tap arrived: an accidental single tap. Same outcome as a
    /// sub-`minHoldMs` press in `hold` mode — the audio is discarded unprocessed
    /// and the pill goes away immediately.
    private func tapWaitWindowExpired(generation: Int) {
        guard generation == tapWaitGeneration else { return }
        tapWaitTask = nil
        guard case .tapWait = flowPhase else { return }

        Log.app.debug("Flow: no second tap — discarding the accidental tap")
        cancelRecording()   // also resets the phase
    }

    /// Drops any pending window and returns the machine to rest.
    private func resetFlow() {
        cancelTapWaitWindow()
        flowPhase = .idle
    }

    // MARK: Recording

    private func beginRecording() {
        guard !isRecording else { return }
        guard hasMicrophoneAccess() else { return }

        // Wired before start() so the very first buffers already drive the pill.
        let token = takeIndicator()
        recorder.levelHandler = { [weak self] level in
            // Arbitrary queue per the AudioRecorder contract → hop to the pill.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self, self.isRecording, self.indicatorToken == token else { return }
                    self.indicator.updateLevel(level)
                }
            }
        }
        recorder.capReachedHandler = { [weak self] in
            // Arbitrary queue (the render thread) → hop to the state machine.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.recordingCapReached(token: token)
                }
            }
        }

        do {
            try recorder.start()
        } catch {
            detachRecorderHandlers()
            let message = DictationController.shortMessage(for: error)
            Log.audio.error("Could not start recording: \(message, privacy: .public)")
            present(.error(message), hideAfter: DictationController.errorHideDelay, token: token)
            return
        }

        isRecording = true
        recordingStartedAt = Date.timeIntervalSinceReferenceDate
        present(.recording, token: token)
        indicator.updateLevel(0)
        recordingStateChanged?(true)
    }

    private func finishRecording(enforceMinimumHold: Bool) {
        guard isRecording else { return }
        isRecording = false

        let heldSeconds = Date.timeIntervalSinceReferenceDate - recordingStartedAt
        detachRecorderHandlers()
        let clip = recorder.stop()
        recordingStateChanged?(false)

        let tooShortHold = enforceMinimumHold
            && heldSeconds * 1000 < Double(config.hotkey.minHoldMs)
        let tooShortClip = clip.duration < DictationController.minimumClipSeconds

        if tooShortHold || tooShortClip {
            Log.app.debug(
                "Discarding accidental tap (held \(Int(heldSeconds * 1000), privacy: .public)ms, clip \(clip.duration, privacy: .public)s)"
            )
            present(nil, hideAfter: 0, token: takeIndicator())
            return
        }

        let token = takeIndicator()
        present(.processing, token: token)
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runPipeline(clip: clip, token: token)
        }
        activePipeline = (token, task)
    }

    /// The pill's ✕ (also available to integrators): abandons whatever is in
    /// flight. A live recording is cancelled exactly like esc; an utterance
    /// already transcribing is cancelled so nothing gets inserted. Work that
    /// belongs to an *older* utterance than the pill shows is left alone.
    public func cancelActiveWork() {
        if isRecording {
            Log.app.debug("Pill cancel — abandoning the live recording")
            cancelRecording()
            return
        }
        guard let active = activePipeline, active.token == indicatorToken else { return }
        Log.app.debug("Pill cancel — abandoning the in-flight transcription")
        active.task.cancel()
        activePipeline = nil
        present(nil, hideAfter: 0, token: takeIndicator())
    }

    private func cancelRecording() {
        // Every abandon path funnels through here — esc, the master switch, and
        // an expired flow tap-wait window — so the phase machine is reset here
        // rather than at each call site.
        resetFlow()
        isRecording = false
        detachRecorderHandlers()
        recorder.cancel()
        recordingStateChanged?(false)
        present(nil, hideAfter: 0, token: takeIndicator())
    }

    private func detachRecorderHandlers() {
        recorder.levelHandler = nil
        recorder.capReachedHandler = nil
    }

    /// The recorder hit `transcription.maxSeconds`. A hands-free session — a
    /// locked `flow` session or a `toggle` session — has no key release coming,
    /// so it stops itself here, exactly as if the user had stopped it at this
    /// instant. `hold` (and a `flow` press that is still held or still inside its
    /// tap-wait window) is unchanged: the release still decides.
    private func recordingCapReached(token: Int) {
        // A stale callback from a recording that has already ended, or from one
        // a newer utterance has superseded, has nothing to stop.
        guard isRecording, indicatorToken == token else { return }

        switch resolvedMode() {
        case .hold:
            return

        case .toggle:
            Log.audio.info("Recording cap reached — stopping the toggle session")

        case .flow:
            switch flowPhase {
            case .locked:
                flowPhase = .idle
            case .lockedKeyDown:
                // The locking press is still held; its release still needs draining.
                flowPhase = .drainUp
            case .idle, .pressed, .tapWait, .drainUp:
                return
            }
            Log.audio.info("Recording cap reached — stopping the hands-free session")
        }

        finishRecording(enforceMinimumHold: false)
    }

    private func hasMicrophoneAccess() -> Bool {
        switch microphoneStatus() {
        case .granted:
            return true

        case .undetermined:
            // macOS shows its own prompt; the answer arrives too late for this
            // press, so tell the user to try again once they've granted it.
            if !isRequestingMicrophone {
                isRequestingMicrophone = true
                requestMicrophoneAccess { [weak self] granted in
                    MainActor.assumeIsolated {
                        self?.isRequestingMicrophone = false
                        Log.audio.info("Microphone access \(granted ? "granted" : "denied", privacy: .public)")
                    }
                }
            }
            present(
                .error("Grant microphone access, then try again"),
                hideAfter: DictationController.permissionHideDelay,
                token: takeIndicator()
            )
            return false

        case .denied:
            Log.audio.error("Microphone access denied")
            present(
                .error(OWError.micPermissionDenied.localizedDescription),
                hideAfter: DictationController.errorHideDelay,
                token: takeIndicator()
            )
            return false
        }
    }

    // MARK: Pipeline (one Task per utterance)

    private func runPipeline(clip: AudioClip, token: Int) async {
        // Snapshot up front, on the main actor, before the first suspension: a
        // live engine/cleanup swap must not change this utterance underneath us.
        let transcriber = self.transcriber
        let cleaner = self.cleaner
        let cleanupEnabled = config.cleanup.enabled
        let cleanupTimeout = config.cleanup.timeoutSeconds

        defer {
            if activePipeline?.token == token { activePipeline = nil }
        }

        do {
            let raw = try await transcriber.transcribe(clip)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The ✕ was clicked while we were transcribing: stop before cleanup.
            try Task.checkCancellation()

            var text = raw
            if cleanupEnabled, let cleaner = cleaner, !raw.isEmpty {
                text = await DictationController.cleanedOrRaw(
                    raw, using: cleaner, timeout: cleanupTimeout
                )
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !text.isEmpty else {
                Log.stt.info("Transcript was empty — nothing to insert")
                present(.error("Heard nothing"), hideAfter: DictationController.emptyHideDelay, token: token)
                return
            }

            // Last gate before anything reaches the user's document.
            try Task.checkCancellation()
            try await inserter.insert(text)
            present(.success, hideAfter: DictationController.successHideDelay, token: token)
        } catch is CancellationError {
            Log.app.info("Utterance cancelled — nothing inserted")
            present(nil, hideAfter: 0, token: token)
        } catch {
            let message = DictationController.shortMessage(for: error)
            Log.app.error("Dictation pipeline failed: \(message, privacy: .public)")
            present(.error(message), hideAfter: DictationController.errorHideDelay, token: token)
        }
    }

    /// Races cleanup against its timeout. Any failure, timeout or empty result
    /// falls back to the raw transcript — the utterance is never lost and never
    /// waits indefinitely.
    private static func cleanedOrRaw(
        _ raw: String,
        using cleaner: TranscriptCleaner,
        timeout: TimeInterval
    ) async -> String {
        let budget = min(max(timeout, cleanupTimeoutBounds.lowerBound), cleanupTimeoutBounds.upperBound)

        let winner = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask {
                do {
                    return try await cleaner.clean(raw)
                } catch {
                    Log.llm.error(
                        "Cleanup failed (\(String(describing: error), privacy: .public)) — using the raw transcript"
                    )
                    return nil
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    Log.llm.error(
                        "Cleanup timed out after \(budget, privacy: .public)s — using the raw transcript"
                    )
                } catch {
                    // Cancelled: the cleaner won the race.
                }
                return nil
            }
            // First finisher decides; cancelling the loser also cancels any
            // in-flight HTTP request.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let cleaned = winner,
              !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            if winner != nil {
                Log.llm.error("Cleanup returned empty text — using the raw transcript")
            }
            return raw
        }
        return cleaned
    }

    // MARK: Pill ownership

    /// Claims the pill for the caller and returns the token proving it.
    private func takeIndicator() -> Int {
        indicatorToken += 1
        return indicatorToken
    }

    /// Shows `state` (nil = hide only) unless a newer owner has taken the pill.
    private func present(_ state: PillState?, hideAfter: TimeInterval? = nil, token: Int) {
        guard token == indicatorToken else { return }
        if let state = state { indicator.show(state) }
        if let hideAfter = hideAfter { indicator.hide(after: hideAfter) }
    }

    // MARK: Errors

    /// One short line — the pill has room for a phrase, not a stack trace.
    static func shortMessage(for error: Error) -> String {
        let full: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            full = description
        } else {
            full = (error as NSError).localizedDescription
        }
        let oneLine = full
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "Something went wrong" }
        guard oneLine.count > 80 else { return oneLine }
        return String(oneLine.prefix(79)) + "…"
    }
}
