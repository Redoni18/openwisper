import Foundation
import OpenWisperCore

/// A finished local transcription plus the timings the smoke test and the
/// status bar care about. `Transcriber.transcribe` returns just the text; use
/// `LocalWhisperTranscriber.transcribeDetailed` when you want the numbers.
public struct LocalTranscription: Sendable {
    /// Whitespace-trimmed concatenation of every whisper segment.
    public let text: String
    /// Non-nil only when this call was the one that loaded the model.
    public let modelLoadSeconds: TimeInterval?
    public let inferenceSeconds: TimeInterval
    public let audioSeconds: TimeInterval

    public init(
        text: String,
        modelLoadSeconds: TimeInterval?,
        inferenceSeconds: TimeInterval,
        audioSeconds: TimeInterval
    ) {
        self.text = text
        self.modelLoadSeconds = modelLoadSeconds
        self.inferenceSeconds = inferenceSeconds
        self.audioSeconds = audioSeconds
    }

    /// Inference time as a multiple of the audio duration. Below 1.0 is faster
    /// than real time; 0 when the clip had no duration.
    public var realtimeFactor: Double {
        audioSeconds > 0 ? inferenceSeconds / audioSeconds : 0
    }
}

/// Fully offline transcription through whisper.cpp.
///
/// The ggml model is loaded once — lazily, on the first `transcribe` (or eagerly
/// via `preload()`) — and stays resident for the lifetime of this object, which
/// is what makes back-to-back dictations fast. Inference is serialised
/// internally, so concurrent `transcribe` calls queue up rather than corrupting
/// the shared `whisper_context`.
///
/// Errors are mapped onto `OWError`:
///  - missing model file  → `.modelNotFound(path)`
///  - empty clip          → `.emptyRecording`
///  - load/inference fail → `.transcriptionFailed(reason)`
public final class LocalWhisperTranscriber: Transcriber {
    public let name = "whisper.cpp"

    /// Path to the ggml model this instance was built for.
    public let modelURL: URL
    /// ISO 639-1 code, or "auto" (or "") for whisper's language auto-detection.
    public let language: String

    private let context: WhisperContext

    public init(modelURL: URL, language: String) {
        self.modelURL = modelURL
        self.language = language
        self.context = WhisperContext(modelURL: modelURL, language: language)
    }

    /// True when the model file this transcriber points at exists on disk.
    /// Cheap enough to call from the menu bar; does not touch whisper.cpp.
    public var isModelAvailable: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    /// Loads the model now rather than on the first utterance, so the first
    /// dictation is not slower than the rest. Returns the load duration, or 0
    /// if the model was already resident. Safe to call more than once.
    @discardableResult
    public func preload() async throws -> TimeInterval {
        try await context.load()
    }

    /// Frees the resident model. A later `transcribe` reloads it.
    ///
    /// Releasing the transcriber does this automatically, and an `atexit` net
    /// catches the case where it is held for the whole process lifetime (see
    /// `WhisperContextRegistry`). Call this explicitly when switching engines at
    /// runtime, or from `applicationWillTerminate` to release the GPU early.
    ///
    /// Blocks until any in-flight transcription finishes.
    public func unload() {
        context.unload()
    }

    // MARK: Transcriber

    public func transcribe(_ clip: AudioClip) async throws -> String {
        try await transcribeDetailed(clip).text
    }

    /// `transcribe`, but keeping the timings.
    public func transcribeDetailed(_ clip: AudioClip) async throws -> LocalTranscription {
        try await context.transcribe(clip)
    }
}
