// whisper-smoke — offline end-to-end check of the local transcription engine.
//
//   swift run -c release whisper-smoke [modelPath] [wavPath]
//
// Defaults to ~/Library/Application Support/OpenWisper/models/ggml-tiny.en.bin
// and Resources/samples/jfk.wav (both produced by `make model` / `make deps`).
// Loads the wav with AVFoundation, resamples it to the 16 kHz mono Float32 that
// whisper.cpp expects, runs it through LocalWhisperTranscriber, and prints the
// transcript with load/inference timings. Exit 0 on success, non-zero with a
// one-line reason on failure.
import AVFoundation
import Foundation
import OpenWisperCore
import WhisperLocal

// MARK: - Helpers

// Progress should be visible even when this is piped into a log file, and the
// first Metal run spends several seconds compiling the embedded shader library
// before anything else happens.
setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("whisper-smoke: \(message)\n".utf8))
    exit(1)
}

func secs(_ value: TimeInterval) -> String { String(format: "%.2fs", value) }

/// Package root, resolved from this source file's compile-time location, so the
/// default sample path works no matter what directory the binary is run from.
func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // Sources/whisper-smoke/main.swift
        .deletingLastPathComponent()         // Sources/whisper-smoke
        .deletingLastPathComponent()         // Sources
        .deletingLastPathComponent()         // <package root>
}

func firstExisting(_ candidates: [URL]) -> URL? {
    candidates.first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Decodes any AVFoundation-readable audio file into whisper's native format:
/// 16 kHz, mono, non-interleaved Float32.
func loadClip(at url: URL) throws -> AudioClip {
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat

    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Defaults.sampleRate),
        channels: 1,
        interleaved: false
    ) else {
        throw OWError.transcriptionFailed("could not build the 16 kHz mono output format")
    }

    // Fast path: the bundled jfk.wav is already 16 kHz mono, and AVAudioFile's
    // processingFormat is always deinterleaved Float32, so no conversion is needed.
    if inputFormat.sampleRate == outputFormat.sampleRate, inputFormat.channelCount == 1 {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(max(file.length, 1))
        ) else {
            throw OWError.transcriptionFailed("could not allocate a \(file.length)-frame read buffer")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw OWError.transcriptionFailed("decoded audio is not Float32")
        }
        return AudioClip(samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw OWError.transcriptionFailed(
            "no converter from \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch to 16 kHz mono"
        )
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * outputFormat.sampleRate / inputFormat.sampleRate) + 1)

    var readError: Error?
    var atEnd = false

    let feed: AVAudioConverterInputBlock = { framesWanted, status in
        if atEnd {
            status.pointee = .endOfStream
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: max(framesWanted, 1)) else {
            atEnd = true
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer, frameCount: max(framesWanted, 1))
        } catch {
            readError = error
            atEnd = true
            status.pointee = .endOfStream
            return nil
        }
        if buffer.frameLength == 0 {
            atEnd = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }

    // Pull until the converter reports the stream is drained.
    while true {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
            throw OWError.transcriptionFailed("could not allocate the conversion output buffer")
        }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError, withInputFrom: feed)

        if let channel = output.floatChannelData?[0], output.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status != .haveData { break }
    }

    return AudioClip(samples: samples)
}

// MARK: - Inputs

let arguments = Array(CommandLine.arguments.dropFirst())

let modelURL: URL = {
    if let path = arguments.first, !path.isEmpty {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    return AppPaths.modelsDir.appendingPathComponent("ggml-tiny.en.bin")
}()

let wavURL: URL = {
    if arguments.count > 1, !arguments[1].isEmpty {
        return URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent("Resources/samples/jfk.wav"),
        packageRoot().appendingPathComponent("Resources/samples/jfk.wav"),
    ]
    return firstExisting(candidates) ?? candidates[0]
}()

guard FileManager.default.fileExists(atPath: modelURL.path) else {
    fail("""
    model not found at \(modelURL.path)
                  run: bash scripts/download_model.sh tiny.en
    """)
}
guard FileManager.default.fileExists(atPath: wavURL.path) else {
    fail("""
    sample audio not found at \(wavURL.path)
                  run: bash scripts/fetch_whisper.sh   (it copies samples/jfk.wav)
    """)
}

// MARK: - Run

print("whisper-smoke")
print("  model : \(modelURL.path)")
print("  audio : \(wavURL.path)")

do {
    let clip = try loadClip(at: wavURL)
    guard !clip.samples.isEmpty else { fail("decoded 0 samples from \(wavURL.lastPathComponent)") }
    print("  clip  : \(clip.samples.count) samples @ \(clip.sampleRate) Hz (\(secs(clip.duration)))")

    let transcriber = LocalWhisperTranscriber(modelURL: modelURL, language: "en")

    // Load explicitly so the two phases are timed separately — the whole point
    // of the resident context is that only the first one pays the load cost.
    // On a Metal build the first load also compiles the embedded shader
    // library, which takes a few seconds.
    print("  loading model (first Metal run compiles shaders, ~10s)...")
    let loadSeconds = try await transcriber.preload()
    print("  transcribing...")
    let result = try await transcriber.transcribeDetailed(clip)

    print("")
    print("  transcript: \(result.text)")
    print("")
    print("  model load    : \(secs(loadSeconds))")
    print("  inference     : \(secs(result.inferenceSeconds))")
    print("  audio duration: \(secs(result.audioSeconds))")
    print("  realtime factor: \(String(format: "%.2fx", result.realtimeFactor)) (lower is faster)")

    guard !result.text.isEmpty else { fail("transcript was empty — the model produced no segments") }

    // A second pass proves the context really is resident and reusable — this is
    // the utterance-to-utterance cost the dictation loop actually pays.
    let second = try await transcriber.transcribeDetailed(clip)
    let reloaded = second.modelLoadSeconds != nil
    print("  2nd inference : \(secs(second.inferenceSeconds)) "
        + "(model \(reloaded ? "WAS RELOADED — context is not resident!" : "stayed resident"))")
    guard !reloaded else { fail("the whisper context was not reused between utterances") }

    // unload() + reload is the runtime engine-switch path, and it is also what
    // frees the GPU before the app quits.
    transcriber.unload()
    let third = try await transcriber.transcribeDetailed(clip)
    guard let reloadSeconds = third.modelLoadSeconds else {
        fail("unload() did not release the model — the next transcription reused it")
    }
    guard third.text == result.text else {
        fail("transcript changed after unload/reload:\n    before: \(result.text)\n    after:  \(third.text)")
    }
    print("  after unload  : reloaded in \(secs(reloadSeconds)), same transcript")

    print("")
    print("whisper-smoke: OK")
    // NB: exits with the context still resident on purpose — that is how the app
    // behaves, and WhisperLocal's atexit net has to free it before ggml's own
    // globals are torn down or the process aborts on the way out.
    exit(0)
} catch let error as OWError {
    fail(error.errorDescription ?? String(describing: error))
} catch {
    fail(String(describing: error))
}
