import Foundation
import Testing

@testable import CloudAI
import OpenWisperCore

/// Byte-level checks on the RIFF/WAVE encoder. The cloud transcription
/// endpoints parse this header strictly, and there is no way to notice a
/// malformed one from the app — it just comes back as an opaque 400.
@Suite("WavEncoder")
struct WavEncoderTests {

    // MARK: Fixtures / little-endian readers

    private func encoded(_ samples: [Float], rate: Int = Defaults.sampleRate) -> [UInt8] {
        Array(WavEncoder.wav16(from: AudioClip(samples: samples, sampleRate: rate)))
    }

    private func tag(_ bytes: [UInt8], at offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private func u16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func u32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private func sample(_ bytes: [UInt8], index: Int) -> Int16 {
        Int16(bitPattern: u16(bytes, at: WavEncoder.headerByteCount + index * 2))
    }

    // MARK: Header

    @Test("Chunk tags and fmt fields are canonical")
    func headerChunkTagsAndFormatFields() {
        let bytes = encoded([0, 0.5, -0.5, 0])

        #expect(WavEncoder.headerByteCount == 44)
        #expect(tag(bytes, at: 0) == "RIFF")
        #expect(tag(bytes, at: 8) == "WAVE")
        #expect(tag(bytes, at: 12) == "fmt ")
        #expect(tag(bytes, at: 36) == "data")

        #expect(u32(bytes, at: 16) == 16, "PCM fmt chunks are 16 bytes")
        #expect(u16(bytes, at: 20) == 1, "audio format 1 = uncompressed PCM")
        #expect(u16(bytes, at: 22) == 1, "mono")
        #expect(u32(bytes, at: 24) == 16000, "sample rate")
        #expect(u32(bytes, at: 28) == 32000, "byte rate = rate * channels * 2")
        #expect(u16(bytes, at: 32) == 2, "block align = channels * 2")
        #expect(u16(bytes, at: 34) == 16, "bits per sample")
    }

    @Test("The sample rate comes from the clip, not a constant")
    func sampleRateIsTakenFromTheClip() {
        let bytes = encoded([0, 0], rate: 8000)
        #expect(u32(bytes, at: 24) == 8000)
        #expect(u32(bytes, at: 28) == 16000, "byte rate follows the clip's rate")
    }

    // MARK: Sizes

    @Test("Chunk sizes track the sample count")
    func chunkSizesTrackTheSampleCount() {
        for count in [0, 1, 8, 1024] {
            let bytes = encoded([Float](repeating: 0, count: count))
            let dataBytes = UInt32(count * 2)
            #expect(bytes.count == 44 + count * 2, "total size for \(count) samples")
            #expect(u32(bytes, at: 4) == 36 + dataBytes, "RIFF size counts everything after itself")
            #expect(u32(bytes, at: 40) == dataBytes, "data chunk size for \(count) samples")
        }
    }

    @Test("An empty clip produces a header and nothing else")
    func emptyClipProducesHeaderOnly() {
        let bytes = encoded([])
        #expect(bytes.count == WavEncoder.headerByteCount)
        #expect(u32(bytes, at: 4) == 36)
        #expect(u32(bytes, at: 40) == 0)
        #expect(WavEncoder.pcm16([]) == Data())
    }

    /// One second of 16 kHz mono audio is 32 000 bytes of PCM, so the header's
    /// byte-rate field must equal the data size for a one-second clip.
    @Test("Duration, byte rate and data size agree")
    func durationToByteMath() {
        let clip = AudioClip(samples: [Float](repeating: 0, count: 16000), sampleRate: 16000)
        #expect(abs(clip.duration - 1.0) < 0.0001)

        let bytes = Array(WavEncoder.wav16(from: clip))
        #expect(bytes.count == 32044)
        #expect(u32(bytes, at: 40) == 32000)
        #expect(u32(bytes, at: 28) == u32(bytes, at: 40), "byte rate == one second of data")
    }

    // MARK: Sample conversion

    @Test("Samples are scaled and clamped to the symmetric Int16 range")
    func sampleScalingAndClamping() {
        let samples: [Float] = [0, 1, -1, 2, -2, 0.5, -0.5, 0.1]
        let expected: [Int16] = [0, 32767, -32767, 32767, -32767, 16384, -16384, 3277]

        let bytes = encoded(samples)
        #expect(bytes.count == 44 + samples.count * 2)
        for (index, value) in expected.enumerated() {
            #expect(sample(bytes, index: index) == value, "sample \(index) (\(samples[index]))")
        }
    }

    @Test("Out-of-range input clamps rather than wrapping")
    func int16SampleClampsOutOfRangeInput() {
        #expect(WavEncoder.int16Sample(0) == 0)
        #expect(WavEncoder.int16Sample(1) == 32767)
        #expect(WavEncoder.int16Sample(-1) == -32767)
        #expect(WavEncoder.int16Sample(12.5) == 32767, "well past full scale clamps, never wraps")
        #expect(WavEncoder.int16Sample(-12.5) == -32767)
        #expect(WavEncoder.int16Sample(0.99999) == 32767)
    }

    @Test("Non-finite samples become silence")
    func nonFiniteSamplesBecomeSilence() {
        #expect(WavEncoder.int16Sample(.nan) == 0)
        #expect(WavEncoder.int16Sample(.infinity) == 0)
        #expect(WavEncoder.int16Sample(-.infinity) == 0)
    }

    @Test("Samples are written little-endian")
    func samplesAreLittleEndian() {
        // 1.0 → 32767 → 0xFF 0x7F when written low byte first.
        let bytes = encoded([1])
        #expect(bytes[WavEncoder.headerByteCount] == 0xFF)
        #expect(bytes[WavEncoder.headerByteCount + 1] == 0x7F)
    }
}
