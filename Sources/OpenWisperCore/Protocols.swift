import Foundation

// ============================================================================
// FROZEN CONTRACTS — every Wave-A target codes against these. Do not edit
// during Wave A; propose changes in your task report instead (integration
// reconciles). See docs/TASKS.md.
// ============================================================================

/// Turns a finished recording into raw text. Implementations: LocalWhisperTranscriber
/// (WhisperLocal), CloudTranscriber (CloudAI), FakeTranscriber (Core).
public protocol Transcriber {
    var name: String { get }
    func transcribe(_ clip: AudioClip) async throws -> String
}

/// Cleans a raw transcript (fillers, punctuation, casing). Failures/timeouts are
/// caught by the caller, which falls back to the raw transcript — cleanup must
/// never block dictation for long or lose the utterance.
public protocol TranscriptCleaner {
    var name: String { get }
    func clean(_ raw: String) async throws -> String
}

/// Inserts final text into the frontmost app at the cursor.
/// Contract: returns shortly after the paste/typing has been issued. Clipboard
/// restoration (paste mode) happens asynchronously inside the implementation.
@MainActor
public protocol TextInserter {
    func insert(_ text: String) async throws
}

/// Visual states of the floating pill.
public enum PillState: Equatable {
    case recording
    case processing
    case success
    case error(String)
}

/// The floating pill (or a no-op stand-in). Main-actor: it drives AppKit windows.
@MainActor
public protocol RecordingIndicator: AnyObject {
    func show(_ state: PillState)
    /// Live input level in 0...1 while recording. Called at ≤ 20 Hz.
    func updateLevel(_ level: Float)
    func hide(after seconds: TimeInterval)
    /// Fired when the user clicks the pill's cancel (✕) control. The dictation
    /// controller uses it to abandon the current recording or in-flight
    /// transcription. Indicators without a cancel affordance may ignore it.
    var onCancel: (() -> Void)? { get set }
}

/// Delivered on the main thread by the hotkey listener.
@MainActor
public protocol HotkeyListenerDelegate: AnyObject {
    func hotkeyDown()
    func hotkeyUp()
    /// Esc pressed while the hotkey was held / recording was live.
    func hotkeyCanceled()
}

/// Global hotkey listener (CGEventTap). `start()` throws
/// `OWError.inputMonitoringNotGranted` when the tap cannot be created.
public protocol HotkeyListening: AnyObject {
    var delegate: HotkeyListenerDelegate? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

/// Microphone capture. `start()` begins buffering 16 kHz mono Float32;
/// `stop()` returns everything captured. `levelHandler` fires on an arbitrary
/// queue with a 0...1 level, throttled to ≤ 20 Hz.
public protocol AudioRecorder: AnyObject {
    var levelHandler: ((Float) -> Void)? { get set }
    /// Fires **exactly once per recording**, the moment the recorder's
    /// `maxSeconds` sample cap is reached and everything after it starts being
    /// dropped. Like `levelHandler` it is called on an **arbitrary queue** —
    /// `Recorder` calls it from the audio render thread — so hop to your own
    /// actor before doing anything, and keep the handler cheap. Hands-free
    /// sessions (no key release is coming) use it to stop themselves;
    /// push-to-talk callers ignore it.
    var capReachedHandler: (() -> Void)? { get set }
    var isRecording: Bool { get }
    func start() throws
    func stop() -> AudioClip
    func cancel()
}
