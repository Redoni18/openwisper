import CoreGraphics
import Foundation
import Testing

import OpenWisperCore
import Spine

// ============================================================================
// Test doubles. All file-private and prefixed so they can't collide with the
// doubles other task's test files bring into the same test module.
// ============================================================================

/// Scripted recorder: no AVAudioEngine, no microphone, no permissions.
private final class SpineFakeRecorder: AudioRecorder {
    var levelHandler: ((Float) -> Void)?
    var capReachedHandler: (() -> Void)?
    private(set) var isRecording = false

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0

    /// Handed back by `stop()`. Two seconds of quiet tone by default.
    var clip = AudioClip(samples: [Float](repeating: 0.05, count: Defaults.sampleRate * 2))
    var startError: Error?

    func start() throws {
        startCount += 1
        if let startError = startError { throw startError }
        isRecording = true
    }

    func stop() -> AudioClip {
        stopCount += 1
        isRecording = false
        return clip
    }

    func cancel() {
        cancelCount += 1
        isRecording = false
    }

    /// Stands in for the render thread hitting the `maxSeconds` cap. The real
    /// `Recorder` fires this from an arbitrary queue and the controller's handler
    /// hops to the main actor either way, so calling it inline is faithful.
    func fireCapReached() {
        capReachedHandler?()
    }
}

private struct SpineStubTranscriber: Transcriber {
    let name = "stub-transcriber"
    var text: String
    var error: Error? = nil

    func transcribe(_ clip: AudioClip) async throws -> String {
        await Task.yield()
        if let error = error { throw error }
        return text
    }
}

/// Slow enough that a second utterance can start while it is still running —
/// used to prove overlapping utterances still work.
private struct SpineSlowTranscriber: Transcriber {
    let name = "slow-transcriber"
    var text: String
    var seconds: Double

    func transcribe(_ clip: AudioClip) async throws -> String {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return text
    }
}

private struct SpineStubCleaner: TranscriptCleaner {
    let name = "stub-cleaner"
    var cleaned: String
    var error: Error? = nil

    func clean(_ raw: String) async throws -> String {
        await Task.yield()
        if let error = error { throw error }
        return cleaned
    }
}

/// Never returns on its own — used to prove the cleanup timeout fires.
private struct SpineHangingCleaner: TranscriptCleaner {
    let name = "hanging-cleaner"

    func clean(_ raw: String) async throws -> String {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return "never delivered"
    }
}

@MainActor
private final class SpineSpyInserter: TextInserter {
    private(set) var inserted: [String] = []
    var error: Error?

    func insert(_ text: String) async throws {
        if let error = error { throw error }
        inserted.append(text)
    }
}

@MainActor
private final class SpineSpyIndicator: RecordingIndicator {
    private(set) var states: [PillState] = []
    private(set) var levels: [Float] = []
    private(set) var hideDelays: [TimeInterval] = []
    var onCancel: (() -> Void)?

    func show(_ state: PillState) { states.append(state) }
    func updateLevel(_ level: Float) { levels.append(level) }
    func hide(after seconds: TimeInterval) { hideDelays.append(seconds) }

    var errorMessages: [String] {
        states.compactMap { if case .error(let message) = $0 { return message } else { return nil } }
    }
}

// ============================================================================

@Suite("DictationController")
@MainActor
struct DictationControllerTests {

    private struct Harness {
        let controller: DictationController
        let recorder: SpineFakeRecorder
        let inserter: SpineSpyInserter
        let indicator: SpineSpyIndicator
    }

    private func makeHarness(
        mode: String = "hold",
        minHoldMs: Int = 0,
        doubleTapWindowMs: Int = 300,
        cleanupEnabled: Bool = true,
        cleanupTimeout: Double = 5,
        transcript: String = "  raw transcript  ",
        transcriberError: Error? = nil,
        transcriber: Transcriber? = nil,
        cleaner: TranscriptCleaner? = nil,
        clipSeconds: Double = 2,
        microphone: PermissionStatus = .granted
    ) -> Harness {
        var config = AppConfig()
        config.hotkey = HotkeyConfig(
            key: "fn", mode: mode, minHoldMs: minHoldMs, doubleTapWindowMs: doubleTapWindowMs
        )
        config.cleanup = CleanupConfig(
            enabled: cleanupEnabled, provider: .auto, model: nil, timeoutSeconds: cleanupTimeout
        )

        let recorder = SpineFakeRecorder()
        recorder.clip = AudioClip(
            samples: [Float](repeating: 0.05, count: Int(Double(Defaults.sampleRate) * clipSeconds))
        )
        let inserter = SpineSpyInserter()
        let indicator = SpineSpyIndicator()

        let controller = DictationController(
            config: config,
            recorder: recorder,
            transcriber: transcriber ?? SpineStubTranscriber(text: transcript, error: transcriberError),
            cleaner: cleaner,
            inserter: inserter,
            indicator: indicator
        )
        // Never touch real TCC from a unit test.
        controller.microphoneStatus = { microphone }
        controller.requestMicrophoneAccess = { completion in completion(false) }

        return Harness(controller: controller, recorder: recorder, inserter: inserter, indicator: indicator)
    }

    /// Polls on the main actor, letting the pipeline Task interleave.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Gives any pipeline Task a chance to run before asserting a negative.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// The flow-mode double tap: press/release below `minHoldMs`, then press and
    /// release again inside the double-tap window. Leaves the session locked
    /// hands-free with the original recording still running.
    private func doubleTapToLock(_ controller: DictationController) {
        controller.hotkeyDown()
        controller.hotkeyUp()
        controller.hotkeyDown()
        controller.hotkeyUp()
    }

    // MARK: (a) accidental taps

    @Test("A hold shorter than minHoldMs inserts nothing")
    func shortHoldInsertsNothing() async {
        let harness = makeHarness(minHoldMs: 500, clipSeconds: 2)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()   // released far sooner than 500 ms

        #expect(harness.recorder.startCount == 1)
        #expect(harness.recorder.stopCount == 1)

        await settle()
        #expect(harness.inserter.inserted.isEmpty, "a sub-minHold tap must insert nothing")
        #expect(
            !harness.indicator.states.contains(.processing),
            "an accidental tap must not reach the processing state"
        )
        #expect(harness.indicator.hideDelays.last == 0, "the pill hides immediately")
    }

    @Test("A clip below the minimum length inserts nothing even when held long enough")
    func tooShortClipInsertsNothingEvenWhenHeldLongEnough() async {
        // Held long enough, but the recorder only captured 0.1 s.
        let harness = makeHarness(minHoldMs: 0, clipSeconds: 0.1)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        await settle()
        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.indicator.states.contains(.processing))
    }

    // MARK: (b) happy path

    @Test("The happy path inserts the cleaned text")
    func happyPathInsertsCleanedText() async {
        let harness = makeHarness(cleaner: SpineStubCleaner(cleaned: "Raw transcript."))

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)
        #expect(harness.indicator.states.contains(.recording))

        harness.controller.hotkeyUp()
        #expect(!harness.controller.isRecording)

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted, "the pipeline should have inserted text")
        #expect(harness.inserter.inserted == ["Raw transcript."])

        #expect(harness.indicator.states.contains(.processing))
        let sawSuccess = await waitUntil { harness.indicator.states.contains(.success) }
        #expect(sawSuccess)
        #expect(harness.indicator.errorMessages.isEmpty)
    }

    @Test("Cleanup disabled inserts the raw transcript")
    func transcriptIsInsertedRawWhenCleanupIsDisabled() async {
        let harness = makeHarness(
            cleanupEnabled: false,
            cleaner: SpineStubCleaner(cleaned: "SHOULD NOT BE USED")
        )

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["raw transcript"], "raw text, trimmed")
    }

    // MARK: (c) cleanup must never lose the utterance

    @Test("A failing cleaner falls back to the raw transcript")
    func cleanerFailureFallsBackToRawTranscript() async {
        let harness = makeHarness(
            cleaner: SpineStubCleaner(cleaned: "SHOULD NOT BE USED", error: OWError.cleanupFailed("boom"))
        )

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted, "a failing cleaner must not swallow the utterance")
        #expect(harness.inserter.inserted == ["raw transcript"])
        #expect(harness.indicator.errorMessages.isEmpty, "cleanup failure is not a user-facing error")
    }

    @Test("A hung cleaner times out and falls back to the raw transcript")
    func cleanerTimeoutFallsBackToRawTranscript() async {
        let harness = makeHarness(cleanupTimeout: 0.15, cleaner: SpineHangingCleaner())

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted, "a hung cleaner must time out, not block dictation")
        #expect(harness.inserter.inserted == ["raw transcript"])
    }

    @Test("An empty transcript inserts nothing and says so")
    func emptyTranscriptInsertsNothingAndReportsIt() async {
        let harness = makeHarness(transcript: "   ")

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        let reported = await waitUntil { !harness.indicator.errorMessages.isEmpty }
        #expect(reported)
        #expect(harness.indicator.errorMessages == ["Heard nothing"])
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("A failing transcriber shows an error and inserts nothing")
    func transcriberFailureShowsAnErrorAndInsertsNothing() async {
        let harness = makeHarness(transcriberError: OWError.transcriptionFailed("model missing"))

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        let reported = await waitUntil { !harness.indicator.errorMessages.isEmpty }
        #expect(reported)
        #expect(harness.inserter.inserted.isEmpty)
        #expect(
            harness.indicator.errorMessages.first
                == OWError.transcriptionFailed("model missing").localizedDescription
        )
    }

    // MARK: (d) cancel

    @Test("Esc cancels and inserts nothing")
    func cancelInsertsNothing() async {
        let harness = makeHarness()

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyCanceled()
        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.cancelCount == 1)
        #expect(harness.recorder.stopCount == 0, "a cancelled clip is never collected")

        // The physical key release still arrives after esc; it must be a no-op.
        harness.controller.hotkeyUp()

        await settle()
        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.indicator.states.contains(.processing))
        #expect(harness.recorder.stopCount == 0)
    }

    @Test("Cancelling while idle is a no-op")
    func cancelWhileIdleIsANoOp() async {
        let harness = makeHarness()

        harness.controller.hotkeyCanceled()

        #expect(harness.recorder.cancelCount == 0)
        #expect(harness.indicator.states.isEmpty)
        #expect(harness.indicator.hideDelays.isEmpty)
    }

    // MARK: toggle mode

    @Test("Toggle mode starts and stops on successive presses")
    func toggleModeStartsAndStopsOnSuccessivePresses() async {
        let harness = makeHarness(mode: "toggle", cleaner: SpineStubCleaner(cleaned: "Toggled."))

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyUp()   // ignored in toggle mode
        #expect(harness.controller.isRecording)
        #expect(harness.recorder.stopCount == 0)

        harness.controller.hotkeyDown() // second press stops
        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.stopCount == 1)

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Toggled."])
    }

    @Test("Toggle mode stops on the second press even inside the double-tap window")
    func toggleModeSecondPressStopsRatherThanLocking() async {
        // The exact gesture that locks a flow session must remain a plain
        // start/stop in toggle mode.
        let harness = makeHarness(
            mode: "toggle", minHoldMs: 250, doubleTapWindowMs: 300,
            cleaner: SpineStubCleaner(cleaned: "Toggled.")
        )

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyDown()
        #expect(!harness.controller.isRecording, "the second press stops, it never locks")
        #expect(harness.recorder.stopCount == 1)
        #expect(harness.recorder.startCount == 1)

        harness.controller.hotkeyUp()
        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Toggled."])
        #expect(harness.recorder.startCount == 1, "the drained release must not re-arm")
    }

    // MARK: flow mode — double tap to lock

    @Test("Flow mode: a double tap locks hands-free and keeps one continuous recording")
    func flowDoubleTapLocksAndKeepsOneContinuousRecording() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120)

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording, "audio must capture from the very first press")
        #expect(harness.recorder.startCount == 1)

        harness.controller.hotkeyUp()   // a tap: below minHoldMs
        #expect(harness.controller.isRecording, "a tap keeps recording while the window is open")
        #expect(harness.recorder.stopCount == 0)
        #expect(harness.recorder.cancelCount == 0)

        harness.controller.hotkeyDown() // second tap inside the window → lock
        harness.controller.hotkeyUp()

        // Well past the 120 ms window: the lock must have cancelled its timer.
        await settle()
        #expect(harness.controller.isRecording, "a locked session records with no key held")
        #expect(harness.recorder.startCount == 1, "one clip, spanning from the first press")
        #expect(harness.recorder.stopCount == 0)
        #expect(harness.recorder.cancelCount == 0)
        #expect(harness.inserter.inserted.isEmpty, "nothing is processed until the user stops")
    }

    @Test("Flow mode: the locking tap's own release is ignored")
    func flowLockingTapReleaseIsIgnored() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        harness.controller.hotkeyDown()     // locks

        harness.controller.hotkeyUp()       // the locking tap's release
        #expect(harness.controller.isRecording, "the locking release must not stop the session")
        #expect(harness.recorder.stopCount == 0)
        #expect(harness.recorder.cancelCount == 0)

        // Extra releases (a repeat, a lost/duplicated event) change nothing.
        harness.controller.hotkeyUp()
        await settle()
        #expect(harness.controller.isRecording)
        #expect(harness.recorder.stopCount == 0)
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("Flow mode: a single tap that is never doubled is discarded unprocessed")
    func flowSingleTapExpiresAndDiscards() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 80)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(harness.controller.isRecording, "still recording while the window is open")

        let stopped = await waitUntil { !harness.controller.isRecording }
        #expect(stopped, "the window must expire on its own")
        #expect(harness.recorder.cancelCount == 1, "the audio is thrown away, not collected")
        #expect(harness.recorder.stopCount == 0)

        await settle()
        #expect(harness.inserter.inserted.isEmpty, "an accidental tap inserts nothing")
        #expect(
            !harness.indicator.states.contains(.processing),
            "an accidental tap must not reach the processing state"
        )
        #expect(harness.indicator.hideDelays.last == 0, "the pill hides immediately")
    }

    // MARK: flow mode — push to talk

    @Test("Flow mode: a hold of at least minHoldMs behaves exactly like hold mode")
    func flowHoldPastMinHoldProcessesLikeHoldMode() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 0, cleaner: SpineStubCleaner(cleaned: "Held.")
        )

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyUp()
        #expect(!harness.controller.isRecording, "a real hold ends on release")
        #expect(harness.recorder.stopCount == 1)
        #expect(harness.recorder.cancelCount == 0)
        #expect(harness.indicator.states.contains(.processing))

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Held."])
    }

    @Test("Flow mode: a clip below the minimum length is still discarded on a hold")
    func flowHoldWithATooShortClipInsertsNothing() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 0, clipSeconds: 0.1)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        await settle()
        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.indicator.states.contains(.processing))
    }

    // MARK: flow mode — stopping a locked session

    @Test("Flow mode: a press while locked stops and processes, and its release does not re-arm")
    func flowPressWhileLockedStopsAndItsReleaseDoesNotRearm() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120,
            cleaner: SpineStubCleaner(cleaned: "Locked.")
        )

        doubleTapToLock(harness.controller)
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyDown()  // stop
        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.stopCount == 1)
        #expect(harness.indicator.states.contains(.processing))

        harness.controller.hotkeyUp()    // drained
        #expect(!harness.controller.isRecording, "the drained release must not start a recording")
        #expect(harness.recorder.startCount == 1)

        // And it must not have opened a fresh tap-wait window either.
        await settle()
        #expect(harness.recorder.startCount == 1)
        #expect(harness.recorder.cancelCount == 0)
        #expect(harness.inserter.inserted == ["Locked."])

        // The machine is back at rest: a fresh press records again.
        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)
        #expect(harness.recorder.startCount == 2)
    }

    @Test("Flow mode: Esc cancels a locked session")
    func flowEscCancelsALockedSession() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120)

        doubleTapToLock(harness.controller)
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyCanceled()
        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.cancelCount == 1)
        #expect(harness.recorder.stopCount == 0, "a cancelled clip is never collected")

        await settle()
        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.indicator.states.contains(.processing))

        // Cancelling leaves the machine at rest, not half-locked.
        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)
        #expect(harness.recorder.startCount == 2)
    }

    @Test("Flow mode: Esc cancels during the tap-wait window")
    func flowEscCancelsDuringTheTapWaitWindow() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 5_000)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyCanceled()
        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.cancelCount == 1)

        // The pending window must have been cancelled with it: the next press is
        // a brand new recording, not a lock of the one just thrown away.
        harness.controller.hotkeyDown()
        #expect(harness.recorder.startCount == 2, "Esc must leave the machine at idle")
        #expect(harness.recorder.cancelCount == 1)

        harness.controller.hotkeyCanceled()
        await settle()
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("Flow mode: the session stays active from the first press to the stop")
    func flowSessionStaysActiveThroughTapWaitAndLock() async {
        // `recordingStateChanged` is what the integrator forwards to
        // `HotkeyListener.isSessionActive`, which is what makes Esc work when no
        // key is held. It must stay true across the whole locked session.
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120)
        var sessionStates: [Bool] = []
        harness.controller.recordingStateChanged = { sessionStates.append($0) }

        doubleTapToLock(harness.controller)
        await settle()
        #expect(sessionStates == [true], "one continuous session across tap, lock and release")

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(sessionStates == [true, false])
    }

    // MARK: flow mode — recording cap

    @Test("Flow mode: hitting the recording cap auto-stops and processes a locked session")
    func flowCapAutoStopsALockedSession() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120,
            cleaner: SpineStubCleaner(cleaned: "Capped.")
        )

        doubleTapToLock(harness.controller)
        #expect(harness.controller.isRecording)

        harness.recorder.fireCapReached()

        let stopped = await waitUntil { !harness.controller.isRecording }
        #expect(stopped, "a hands-free session must stop itself at the cap")
        #expect(harness.recorder.stopCount == 1, "stopped, not cancelled")
        #expect(harness.recorder.cancelCount == 0)

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted, "the capped audio is processed, exactly as a manual stop would be")
        #expect(harness.inserter.inserted == ["Capped."])
    }

    @Test("Flow mode: the recording cap does not end a push-to-talk hold")
    func flowCapDoesNotEndAPushToTalkHold() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 250, cleaner: SpineStubCleaner(cleaned: "Still held.")
        )

        harness.controller.hotkeyDown()
        harness.recorder.fireCapReached()

        await settle()
        #expect(harness.controller.isRecording, "the release still decides while the key is held")
        #expect(harness.recorder.stopCount == 0)

        // Settled for 300 ms, so this release is a hold, not a tap.
        harness.controller.hotkeyUp()
        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Still held."])
    }

    @Test("Toggle mode: hitting the recording cap auto-stops and processes the session")
    func toggleCapAutoStopsTheSession() async {
        let harness = makeHarness(mode: "toggle", cleaner: SpineStubCleaner(cleaned: "Capped toggle."))

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)

        harness.recorder.fireCapReached()

        let stopped = await waitUntil { !harness.controller.isRecording }
        #expect(stopped)
        #expect(harness.recorder.stopCount == 1)

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Capped toggle."])
    }

    @Test("Hold mode ignores the recording cap — the release still decides")
    func holdModeIgnoresTheRecordingCap() async {
        let harness = makeHarness(mode: "hold", cleaner: SpineStubCleaner(cleaned: "Held to the end."))

        harness.controller.hotkeyDown()
        harness.recorder.fireCapReached()

        await settle()
        #expect(harness.controller.isRecording, "hold mode is unchanged by the cap")
        #expect(harness.recorder.stopCount == 0)

        harness.controller.hotkeyUp()
        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Held to the end."])
    }

    // MARK: flow mode — invariants

    @Test("Flow mode: a locked session can stop while a previous utterance is still transcribing")
    func flowLockedSessionOverlapsAPreviousUtterance() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 100, doubleTapWindowMs: 120,
            transcriber: SpineSlowTranscriber(text: "overlapping", seconds: 0.6)
        )

        // Utterance 1: a plain hold, long enough to clear minHoldMs.
        harness.controller.hotkeyDown()
        try? await Task.sleep(nanoseconds: 150_000_000)
        harness.controller.hotkeyUp()
        #expect(harness.recorder.stopCount == 1)

        // Utterance 2 starts and locks while utterance 1 is still transcribing.
        #expect(harness.inserter.inserted.isEmpty, "utterance 1 is still in flight")
        doubleTapToLock(harness.controller)
        #expect(harness.controller.isRecording)

        harness.controller.hotkeyDown()   // stop the locked session
        harness.controller.hotkeyUp()
        #expect(harness.recorder.stopCount == 2)

        let both = await waitUntil { harness.inserter.inserted.count == 2 }
        #expect(both, "neither utterance may be lost")
        #expect(harness.inserter.inserted == ["overlapping", "overlapping"])
        #expect(harness.indicator.errorMessages.isEmpty)
    }

    @Test("Flow mode: disabling dictation mid-lock cancels and leaves nothing stranded")
    func flowDisablingMidLockCancels() async {
        let harness = makeHarness(mode: "flow", minHoldMs: 250, doubleTapWindowMs: 120)

        doubleTapToLock(harness.controller)
        #expect(harness.controller.isRecording)

        harness.controller.isEnabled = false
        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.cancelCount == 1)

        harness.controller.isEnabled = true
        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording, "re-enabling starts cleanly from idle")
        #expect(harness.recorder.startCount == 2)

        await settle()
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("An unknown hotkey.mode behaves like flow")
    func unknownHotkeyModeBehavesLikeFlow() async {
        let harness = makeHarness(
            mode: "wispr", minHoldMs: 250, doubleTapWindowMs: 120,
            cleaner: SpineStubCleaner(cleaned: "Fallback.")
        )

        doubleTapToLock(harness.controller)
        await settle()
        #expect(harness.controller.isRecording, "an unknown mode must lock like flow")
        #expect(harness.recorder.startCount == 1)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Fallback."])
    }

    @Test("The hotkey mode is re-read per event, so a config edit applies live")
    func hotkeyModeIsRereadPerEvent() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 250, doubleTapWindowMs: 80,
            cleaner: SpineStubCleaner(cleaned: "Switched.")
        )

        // A flow tap that nobody doubles: discarded.
        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        let discarded = await waitUntil { !harness.controller.isRecording }
        #expect(discarded)
        #expect(harness.recorder.cancelCount == 1)

        harness.controller.config.hotkey.mode = "toggle"

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(harness.controller.isRecording, "toggle now: the release is meaningless")

        harness.controller.hotkeyDown()
        #expect(!harness.controller.isRecording)

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted)
        #expect(harness.inserter.inserted == ["Switched."])
    }

    @Test("Switching out of flow mid-lock does not strand the session")
    func switchingOutOfFlowMidLockDoesNotStrandTheSession() async {
        let harness = makeHarness(
            mode: "flow", minHoldMs: 100, doubleTapWindowMs: 120,
            cleaner: SpineStubCleaner(cleaned: "Switched mid-lock.")
        )

        doubleTapToLock(harness.controller)
        #expect(harness.controller.isRecording)

        // Speaking hands-free for a while, then a config reload lands.
        try? await Task.sleep(nanoseconds: 150_000_000)
        harness.controller.config.hotkey.mode = "hold"

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording, "hold mode keeps the live recording going")
        #expect(harness.recorder.startCount == 1)

        harness.controller.hotkeyUp()
        #expect(!harness.controller.isRecording, "and ends it on the release, as hold mode does")
        #expect(harness.recorder.stopCount == 1)

        let inserted = await waitUntil { !harness.inserter.inserted.isEmpty }
        #expect(inserted, "the words spoken hands-free must not be lost to a mode switch")
        #expect(harness.inserter.inserted == ["Switched mid-lock."])
    }

    // MARK: hold mode regressions

    @Test("Hold mode: a double tap is two discarded taps, never a hands-free lock")
    func holdModeDoubleTapDoesNotLock() async {
        let harness = makeHarness(mode: "hold", minHoldMs: 500, doubleTapWindowMs: 300)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(!harness.controller.isRecording, "hold mode ends on release, always")
        #expect(harness.recorder.stopCount == 1)

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()
        #expect(!harness.controller.isRecording, "the second tap must not lock anything")
        #expect(harness.recorder.startCount == 2)
        #expect(harness.recorder.stopCount == 2)

        await settle()
        #expect(harness.inserter.inserted.isEmpty)
        #expect(!harness.indicator.states.contains(.processing))
    }

    // MARK: gates

    @Test("A disabled controller ignores the hotkey")
    func disabledControllerIgnoresTheHotkey() async {
        let harness = makeHarness()
        harness.controller.isEnabled = false

        harness.controller.hotkeyDown()
        harness.controller.hotkeyUp()

        #expect(harness.recorder.startCount == 0)
        await settle()
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("Disabling mid-recording cancels the recording")
    func disablingMidRecordingCancels() async {
        let harness = makeHarness()

        harness.controller.hotkeyDown()
        #expect(harness.controller.isRecording)

        harness.controller.isEnabled = false

        #expect(!harness.controller.isRecording)
        #expect(harness.recorder.cancelCount == 1)
        await settle()
        #expect(harness.inserter.inserted.isEmpty)
    }

    @Test("A denied microphone shows an error and never starts the recorder")
    func deniedMicrophoneShowsAnErrorAndNeverStartsTheRecorder() async {
        let harness = makeHarness(microphone: .denied)

        harness.controller.hotkeyDown()

        #expect(harness.recorder.startCount == 0)
        #expect(!harness.controller.isRecording)
        #expect(harness.indicator.errorMessages == [OWError.micPermissionDenied.localizedDescription])
    }

    @Test("An undetermined microphone is requested and the user is asked to retry")
    func undeterminedMicrophoneRequestsAccessAndAsksTheUserToRetry() async {
        let harness = makeHarness(microphone: .undetermined)
        var requested = false
        harness.controller.requestMicrophoneAccess = { completion in
            requested = true
            completion(false)
        }

        harness.controller.hotkeyDown()

        #expect(requested, "an undetermined mic permission must be requested")
        #expect(harness.recorder.startCount == 0)
        #expect(harness.indicator.errorMessages == ["Grant microphone access, then try again"])
    }

    @Test("A recorder that cannot start surfaces as an error pill")
    func recorderStartFailureSurfacesAsAnErrorPill() async {
        let harness = makeHarness()
        harness.recorder.startError = OWError.transcriptionFailed("No audio input device")

        harness.controller.hotkeyDown()

        #expect(!harness.controller.isRecording)
        #expect(
            harness.indicator.errorMessages.first
                == OWError.transcriptionFailed("No audio input device").localizedDescription
        )
        harness.controller.hotkeyUp()   // must not stop a recorder that never started
        #expect(harness.recorder.stopCount == 0)
    }

    // MARK: hotkey key-spec parsing

    @Test("Every documented hotkey spec resolves to the right key code")
    func hotkeyKeyCodeParsing() {
        let cases: [(spec: String, expected: CGKeyCode)] = [
            ("fn", 63),
            ("FN", 63),
            ("rightCommand", 54),
            ("leftCommand", 55),
            ("leftOption", 58),
            ("rightOption", 61),
            ("leftControl", 59),
            ("rightControl", 62),
            ("leftShift", 56),
            ("rightShift", 60),
            ("f13", 105),
            ("f14", 107),
            ("f15", 113),
            ("f16", 106),
            ("f17", 64),
            ("f18", 79),
            ("f19", 80),
            ("keycode:42", 42),
            (" keycode:42 ", 42),
            ("not-a-key", 63),        // unknown names fall back to fn
            ("keycode:banana", 63),   // as does an unparseable raw code
        ]
        for (spec, expected) in cases {
            #expect(HotkeyListener.resolvedKeyCode(for: spec) == expected)
        }
    }

    // MARK: ✕ / cancelActiveWork

    @Test("✕ during a live recording cancels it — nothing is processed")
    func cancelClickDuringRecording() async throws {
        let h = makeHarness(mode: "hold")
        h.controller.hotkeyDown()
        #expect(h.controller.isRecording)

        h.controller.cancelActiveWork()
        #expect(!h.controller.isRecording)
        #expect(h.recorder.cancelCount == 1)
        #expect(h.recorder.stopCount == 0)
        await settle()
        #expect(h.inserter.inserted.isEmpty)
    }

    @Test("✕ during transcription abandons the utterance — nothing is inserted")
    func cancelClickDuringProcessing() async throws {
        // The slow transcriber swallows the cancellation and returns text
        // anyway — the pipeline's own checkCancellation gate must still stop it.
        let h = makeHarness(
            mode: "hold",
            transcriber: SpineSlowTranscriber(text: "should never land", seconds: 0.5)
        )
        h.controller.hotkeyDown()
        h.controller.hotkeyUp()
        #expect(!h.controller.isRecording)

        h.controller.cancelActiveWork()
        _ = await waitUntil { h.indicator.hideDelays.contains(0) }
        try? await Task.sleep(nanoseconds: 800_000_000)   // let the slow transcribe drain
        #expect(h.inserter.inserted.isEmpty)
    }

    @Test("The pill's onCancel is wired straight to cancelActiveWork by init")
    func indicatorCancelIsWired() async throws {
        let h = makeHarness(mode: "hold")
        h.controller.hotkeyDown()
        #expect(h.controller.isRecording)

        h.indicator.onCancel?()
        #expect(!h.controller.isRecording)
        #expect(h.recorder.cancelCount == 1)
        await settle()
        #expect(h.inserter.inserted.isEmpty)
    }

    @Test("✕ with nothing in flight is a harmless no-op")
    func cancelClickWhenIdle() async throws {
        let h = makeHarness(mode: "hold")
        h.controller.cancelActiveWork()
        #expect(h.recorder.cancelCount == 0)
        #expect(h.indicator.hideDelays.isEmpty)
    }
}
