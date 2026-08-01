import AVFoundation
import Dispatch
import Foundation
import OpenWisperCore

/// Microphone capture for one utterance.
///
/// A **fresh `AVAudioEngine` per `start()`** is deliberate: an engine caches the
/// hardware format at construction time, so reusing one across utterances breaks
/// the moment the user plugs in AirPods or switches input device between
/// recordings. Building a new engine each time costs microseconds and is immune
/// to that entire class of bug.
///
/// The tap runs on AVAudioEngine's render thread: it resamples to whisper's
/// 16 kHz mono Float32 with a persistent `AVAudioConverter` (persistent because
/// a resampler carries filter state across buffers) and appends under a lock.
///
/// This type never asks for microphone permission — `DictationController` gates
/// on `Permissions.microphone` before it ever calls `start()`.
public final class Recorder: AudioRecorder {

    /// ≤ 20 Hz level callbacks, per the `AudioRecorder` contract.
    private static let levelIntervalNanos: UInt64 = 50_000_000

    /// Level curve: -50 dBFS reads as silence, 0 dBFS as full scale.
    private static let levelFloorDB: Float = 50

    // MARK: State

    /// Guards everything touched by both the render thread and the caller.
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _levelHandler: ((Float) -> Void)?
    private var _capReachedHandler: (() -> Void)?
    private var _isRecording = false
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var lastLevelSentAt: UInt64 = 0
    private var didReachCap = false

    /// Caller-thread only (start/stop/cancel are driven by the main actor).
    private var engine: AVAudioEngine?

    private let maxSamples: Int
    private let maxSeconds: Int
    private let targetFormat: AVAudioFormat?

    // MARK: Lifecycle

    public init(maxSeconds: Int) {
        self.maxSeconds = max(1, maxSeconds)
        self.maxSamples = self.maxSeconds * Defaults.sampleRate
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Defaults.sampleRate),
            channels: 1,
            interleaved: false
        )
    }

    deinit {
        teardown()
    }

    // MARK: AudioRecorder

    public var levelHandler: ((Float) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _levelHandler
        }
        set {
            lock.lock()
            _levelHandler = newValue
            lock.unlock()
        }
    }

    /// Fired once per recording from the **render thread**, per the
    /// `AudioRecorder` contract: the first buffer that fills the `maxSeconds`
    /// cap calls it outside the lock, and it is never called again until the
    /// next `start()`.
    public var capReachedHandler: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _capReachedHandler
        }
        set {
            lock.lock()
            _capReachedHandler = newValue
            lock.unlock()
        }
    }

    public var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRecording
    }

    public func start() throws {
        // Never leak a previous engine, even if stop() was skipped.
        teardown()

        guard targetFormat != nil else {
            throw OWError.transcriptionFailed("Could not create the 16 kHz mono capture format")
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        // Pre-allocate so the render thread doesn't have to grow the buffer for
        // the first half-minute of speech.
        samples.reserveCapacity(min(maxSamples, Defaults.sampleRate * 30))
        converter = nil
        converterInputFormat = nil
        lastLevelSentAt = 0
        didReachCap = false
        lock.unlock()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // This is what an absent (or TCC-blocked) input device looks like.
            self.engine = nil
            Log.audio.error(
                "Input node reports an unusable format (\(hardwareFormat.sampleRate, privacy: .public) Hz, \(hardwareFormat.channelCount, privacy: .public) ch)"
            )
            throw OWError.transcriptionFailed("No audio input device")
        }

        // `format: nil` means "whatever the bus actually produces". Passing a
        // separately-read format risks the (uncatchable) format-mismatch
        // exception if the hardware format changes between the read and the
        // install; the converter is built from the real buffer format anyway.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        // Armed before starting: the render thread drops buffers otherwise.
        setRecording(true)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            setRecording(false)
            input.removeTap(onBus: 0)
            self.engine = nil
            Log.audio.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            throw OWError.transcriptionFailed("Could not start audio capture: \(error.localizedDescription)")
        }

        Log.audio.debug(
            "Recording started (input \(hardwareFormat.sampleRate, privacy: .public) Hz × \(hardwareFormat.channelCount, privacy: .public) ch)"
        )
    }

    public func stop() -> AudioClip {
        teardown()

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        Log.audio.debug("Recording stopped (\(captured.count, privacy: .public) samples)")
        return AudioClip(samples: captured)
    }

    public func cancel() {
        teardown()

        lock.lock()
        let discarded = samples.count
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        if discarded > 0 {
            Log.audio.debug("Recording cancelled (\(discarded, privacy: .public) samples discarded)")
        }
    }

    // MARK: Engine teardown

    private func teardown() {
        // Disarm first so any buffer already in flight is ignored.
        setRecording(false)

        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            self.engine = nil
        }

        lock.lock()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    private func setRecording(_ value: Bool) {
        lock.lock()
        _isRecording = value
        lock.unlock()
    }

    // MARK: Render-thread path

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let target = targetFormat, buffer.frameLength > 0 else { return }
        guard let converter = resolveConverter(for: buffer.format, target: target) else { return }

        // Resampling is a pull API: the converter asks for input until it has
        // filled the output buffer or we tell it the input ran dry.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var didSupplyInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didSupplyInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupplyInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            Log.audio.error(
                "Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)"
            )
            return
        }

        let produced = Int(output.frameLength)
        guard produced > 0, let channel = output.floatChannelData?[0] else { return }

        let level = Recorder.level(of: channel, count: produced)

        var levelHandlerToCall: ((Float) -> Void)?
        var capHandlerToCall: (() -> Void)?
        var didJustReachCap = false

        lock.lock()
        if _isRecording {
            let room = maxSamples - samples.count
            let take = max(0, min(room, produced))
            if take > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: take))
            }
            // Reported the moment the buffer is full — not one buffer later,
            // when audio has already been dropped — so a hands-free session can
            // stop itself with nothing lost.
            if samples.count >= maxSamples, !didReachCap {
                didReachCap = true
                didJustReachCap = true
                capHandlerToCall = _capReachedHandler
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if let handler = _levelHandler, now &- lastLevelSentAt >= Recorder.levelIntervalNanos {
                lastLevelSentAt = now
                levelHandlerToCall = handler
            }
        }
        lock.unlock()

        if didJustReachCap {
            Log.audio.error("Utterance hit the \(self.maxSeconds, privacy: .public)s cap — dropping the rest")
        }
        // Called outside the lock: these handlers hop to the main actor and must
        // never be able to deadlock against a caller mutating them.
        levelHandlerToCall?(level)
        capHandlerToCall?()
    }

    /// Returns the cached converter, rebuilding it when the bus format changes
    /// mid-recording. Returns nil when the recorder is disarmed.
    private func resolveConverter(for inputFormat: AVAudioFormat, target: AVAudioFormat) -> AVAudioConverter? {
        lock.lock()
        guard _isRecording else {
            lock.unlock()
            return nil
        }
        if let cached = converter, let cachedFormat = converterInputFormat,
           cachedFormat.isEqual(inputFormat) {
            lock.unlock()
            return cached
        }
        guard let made = AVAudioConverter(from: inputFormat, to: target) else {
            lock.unlock()
            Log.audio.error("No converter from the input format to 16 kHz mono Float32")
            return nil
        }
        converter = made
        converterInputFormat = inputFormat
        lock.unlock()
        return made
    }

    /// RMS → 0...1 on the curve the pill expects.
    private static func level(of samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for index in 0..<count {
            let value = samples[index]
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + levelFloorDB) / levelFloorDB, 0), 1)
    }
}
