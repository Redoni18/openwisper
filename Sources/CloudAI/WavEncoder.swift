import Foundation
import OpenWisperCore

/// Encodes an `AudioClip` (16 kHz mono Float32, whisper's native format) as a
/// canonical 16-bit PCM RIFF/WAVE file — what the Groq / OpenAI
/// `audio/transcriptions` endpoints accept as the multipart `file` part.
///
/// Layout produced (44-byte header, no extra chunks):
///
///     "RIFF" | UInt32 36+dataBytes | "WAVE"
///     "fmt " | UInt32 16 | UInt16 1 (PCM) | UInt16 1 (mono)
///            | UInt32 sampleRate | UInt32 byteRate | UInt16 blockAlign | UInt16 16
///     "data" | UInt32 dataBytes | Int16 little-endian samples
public enum WavEncoder {
    /// Bytes in a canonical RIFF/WAVE header, i.e. the offset of the first sample.
    public static let headerByteCount = 44

    private static let channels: UInt16 = 1
    private static let bitsPerSample: UInt16 = 16
    private static let bytesPerSample = 2

    public static func wav16(from clip: AudioClip) -> Data {
        let sampleRate = UInt32(clamping: clip.sampleRate)
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataByteCount = UInt32(clamping: clip.samples.count * bytesPerSample)

        var out = Data(capacity: headerByteCount + clip.samples.count * bytesPerSample)

        // RIFF chunk descriptor. The size field counts everything after it.
        out.appendUTF8("RIFF")
        out.appendLittleEndian(UInt32(clamping: 36 + Int(dataByteCount)))
        out.appendUTF8("WAVE")

        // fmt sub-chunk (PCM, so exactly 16 bytes of payload).
        out.appendUTF8("fmt ")
        out.appendLittleEndian(UInt32(16))
        out.appendLittleEndian(UInt16(1))          // 1 = PCM, uncompressed
        out.appendLittleEndian(channels)
        out.appendLittleEndian(sampleRate)
        out.appendLittleEndian(byteRate)
        out.appendLittleEndian(blockAlign)
        out.appendLittleEndian(bitsPerSample)

        // data sub-chunk.
        out.appendUTF8("data")
        out.appendLittleEndian(dataByteCount)
        out.append(pcm16(clip.samples))

        return out
    }

    /// Float samples → little-endian Int16 PCM bytes.
    static func pcm16(_ samples: [Float]) -> Data {
        guard !samples.isEmpty else { return Data() }
        var encoded = [Int16]()
        encoded.reserveCapacity(samples.count)
        for sample in samples {
            encoded.append(int16Sample(sample).littleEndian)
        }
        return encoded.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Clamps to [-1, 1] and scales to the symmetric Int16 range. Non-finite
    /// samples (a NaN slipping out of a DSP path) become silence rather than
    /// trapping on the conversion.
    static func int16Sample(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        let clamped = Swift.min(Swift.max(sample, -1), 1)
        return Int16((clamped * 32767).rounded())
    }
}
