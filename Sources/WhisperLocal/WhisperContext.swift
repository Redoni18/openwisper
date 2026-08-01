import CWhisper
import Foundation
import OpenWisperCore

/// Owns the resident `whisper_context` and serialises every call into whisper.cpp.
///
/// Why a resident context: creating one parses and uploads the whole model
/// (hundreds of ms for `tiny`, seconds for `small`/`medium`). A dictation app
/// cannot pay that per utterance, so the context is created once — lazily, on
/// the first transcription — and reused until this object is deallocated.
///
/// Why a serial `DispatchQueue` and not an actor: `whisper_full` blocks its
/// thread for the whole inference (seconds) and is not reentrant for a given
/// context. Blocking a Swift concurrency cooperative-pool thread that long
/// risks starving the pool, so inference gets its own thread instead, and the
/// async boundary is a continuation.
final class WhisperContext {
    private let modelURL: URL
    private let language: String
    private let queue = DispatchQueue(label: "com.openwisper.whisper.inference", qos: .userInitiated)

    /// `whisper_context *`. Only touched on `queue` (and in `deinit`, by which
    /// point no queued work can still be holding a reference to `self`).
    private var ctx: OpaquePointer?

    init(modelURL: URL, language: String) {
        self.modelURL = modelURL
        self.language = language
    }

    deinit {
        // Safe to touch `ctx` off-queue: deinit only runs once nothing holds a
        // reference to self, and every queued block captures self strongly.
        if let ctx {
            WhisperContextRegistry.unregister(ctx)
            whisper_free(ctx)
            Log.stt.debug("whisper context freed")
        }
    }

    /// Frees the resident model now; a later `transcribe` will reload it.
    ///
    /// Blocks until any in-flight inference finishes — `whisper_free` must not
    /// race `whisper_full`. Intended for `applicationWillTerminate` and for
    /// switching engines at runtime.
    func unload() {
        queue.sync {
            guard let ctx = self.ctx else { return }
            self.ctx = nil
            WhisperContextRegistry.unregister(ctx)
            whisper_free(ctx)
            Log.stt.debug("whisper context unloaded")
        }
    }

    // MARK: - Async entry points

    /// Loads the model if it is not resident yet. Returns how long the load
    /// took, or 0 when the model was already loaded.
    func load() async throws -> TimeInterval {
        try await onQueue { try self.loadIfNeeded() ?? 0 }
    }

    func transcribe(_ clip: AudioClip) async throws -> LocalTranscription {
        try await onQueue { try self.run(clip) }
    }

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-confined work

    /// Returns the load duration when this call did the loading, nil when the
    /// context was already resident. Caller must be on `queue`.
    private func loadIfNeeded() throws -> TimeInterval? {
        if ctx != nil { return nil }

        let path = modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw OWError.modelNotFound(path)
        }

        // Install before the first context is created so model-load chatter is
        // captured too.
        WhisperLogBridge.installOnce()

        var params = whisper_context_default_params()
        // Both are already whisper.cpp's defaults; set explicitly so a future
        // upstream change does not silently move us off the GPU. `use_gpu` is a
        // no-op when the vendored library was built with GGML_METAL=OFF.
        params.use_gpu = true
        params.flash_attn = true

        let started = DispatchTime.now()
        guard let created = path.withCString({ whisper_init_from_file_with_params($0, params) }) else {
            throw OWError.transcriptionFailed("could not load the whisper model at \(path)")
        }
        ctx = created
        WhisperContextRegistry.register(created)

        let elapsed = Self.seconds(since: started)
        Log.stt.info("whisper model loaded in \(Self.fmt(elapsed), privacy: .public)s: \(path, privacy: .public)")
        return elapsed
    }

    /// Caller must be on `queue`.
    private func run(_ clip: AudioClip) throws -> LocalTranscription {
        guard clip.sampleRate == Defaults.sampleRate else {
            // whisper_full has no sample-rate argument: it assumes 16 kHz. Feeding
            // it anything else produces silently garbled text, so fail loudly.
            throw OWError.transcriptionFailed(
                "expected \(Defaults.sampleRate) Hz mono audio, got \(clip.sampleRate) Hz"
            )
        }
        guard !clip.samples.isEmpty else { throw OWError.emptyRecording }

        let loadSeconds = try loadIfNeeded()
        guard let ctx else {
            throw OWError.transcriptionFailed("whisper context is unavailable")
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.threadCount)
        params.translate = false
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.suppress_blank = true
        // Each utterance is independent: without this the resident context would
        // prime the decoder with the *previous* dictation and echo it back.
        params.no_context = true
        params.detect_language = false

        let started = DispatchTime.now()
        let status = withLanguage { languagePointer -> Int32 in
            params.language = languagePointer
            return clip.samples.withUnsafeBufferPointer { samples in
                whisper_full(ctx, params, samples.baseAddress, Int32(samples.count))
            }
        }
        let inferenceSeconds = Self.seconds(since: started)

        guard status == 0 else {
            throw OWError.transcriptionFailed("whisper_full failed (code \(status))")
        }

        var text = ""
        text.reserveCapacity(256)
        for i in 0..<whisper_full_n_segments(ctx) {
            guard let segment = whisper_full_get_segment_text(ctx, i) else { continue }
            text += String(cString: segment)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.stt.info(
            """
            whisper transcribed \(Self.fmt(clip.duration), privacy: .public)s of audio in \
            \(Self.fmt(inferenceSeconds), privacy: .public)s (\(trimmed.count) chars)
            """
        )

        return LocalTranscription(
            text: trimmed,
            modelLoadSeconds: loadSeconds,
            inferenceSeconds: inferenceSeconds,
            audioSeconds: clip.duration
        )
    }

    // MARK: - Helpers

    /// Runs `body` with the C string for `whisper_full_params.language`.
    /// whisper.cpp documents NULL / "" / "auto" as "auto-detect"; we pass NULL.
    private func withLanguage<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        let normalized = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty, normalized != "auto" else { return body(nil) }
        return normalized.withCString { body($0) }
    }

    /// Leave a couple of cores for the audio engine and the UI, but never drop
    /// below 4 threads — whisper is the long pole in the dictation round trip.
    private static var threadCount: Int {
        max(4, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    private static func seconds(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
    }

    private static func fmt(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }
}

// MARK: - Exit-time safety net

/// Tracks live `whisper_context`s so none survive into process teardown.
///
/// ggml's Metal backend keeps its devices in a C++ global. When that global is
/// destroyed during `exit()` it asserts that no residency sets are still
/// registered:
///
///     ggml-metal-device.m: GGML_ASSERT([rsets->data count] == 0) failed
///
/// A context that is still alive at that point trips the assert and the process
/// `abort()`s *after* main has already returned — i.e. a crash report on every
/// clean quit. Callers should release the transcriber (or call `unload()`)
/// themselves, but a menu-bar app that keeps the engine resident for its whole
/// lifetime will not, so free whatever is left from an `atexit` handler.
///
/// Ordering works out: Darwin runs `atexit`/`__cxa_atexit` entries in reverse
/// registration order, and this handler is registered *after* the first context
/// exists — therefore after ggml's own global — so it runs before ggml's
/// teardown.
enum WhisperContextRegistry {
    private static let lock = NSLock()
    private static var live: [OpaquePointer] = []
    private static var handlerInstalled = false

    static func register(_ ctx: OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        live.append(ctx)
        guard !handlerInstalled else { return }
        handlerInstalled = true
        atexit { WhisperContextRegistry.freeAllAtExit() }
    }

    static func unregister(_ ctx: OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        live.removeAll { $0 == ctx }
    }

    /// Runs on the exiting thread. Frees directly rather than hopping onto each
    /// context's inference queue: at `exit()` a queue that is mid-inference may
    /// never drain, and blocking here would hang the quit instead of crashing
    /// it. Anything still running is about to be torn down with the process.
    private static func freeAllAtExit() {
        lock.lock()
        let remaining = live
        live.removeAll()
        lock.unlock()

        for ctx in remaining { whisper_free(ctx) }
    }
}

// MARK: - Logging

/// whisper.cpp and ggml write progress, backend probing and tensor dumps to
/// stderr by default, which is unacceptable noise for a menu-bar app. Redirect
/// all of it into the unified log (`Log.stt`). `whisper_log_set` forwards to
/// `ggml_log_set`, so this single call covers both libraries.
enum WhisperLogBridge {
    /// Set OPENWISPER_WHISPER_LOG=1 to also mirror whisper/ggml output to stderr.
    /// Read once, up front: the callback runs on ggml's threads and must not do
    /// anything that could block or allocate more than necessary.
    private static let mirrorToStderr =
        ProcessInfo.processInfo.environment["OPENWISPER_WHISPER_LOG"] == "1"

    private static let installed: Void = {
        // Touch the loggers before handing the callback to C so their lazy
        // initialisers do not run for the first time on a ggml worker thread.
        _ = Log.stt
        _ = mirrorToStderr

        whisper_log_set({ level, text, _ in
            guard let text else { return }
            if WhisperLogBridge.mirrorToStderr {
                fputs(String(cString: text), stderr)
            }
            let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            if level == GGML_LOG_LEVEL_ERROR {
                Log.stt.error("whisper: \(message, privacy: .public)")
            } else if level == GGML_LOG_LEVEL_WARN {
                Log.stt.warning("whisper: \(message, privacy: .public)")
            } else {
                Log.stt.debug("whisper: \(message, privacy: .public)")
            }
        }, nil)
    }()

    /// Idempotent and thread-safe: `static let` initialisers run exactly once.
    static func installOnce() { _ = installed }
}
