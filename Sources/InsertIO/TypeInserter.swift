import AppKit
import CoreGraphics
import Foundation
import OpenWisperCore

/// Alternative insertion path: synthesise the text as unicode keystrokes.
///
/// Slower than pasting and it can trip up apps that do their own input
/// handling, but the *insertion* never depends on the clipboard. With
/// `copyTranscriptToClipboard` (the `insert.copyToClipboard` default) the
/// transcript is additionally placed on the clipboard after typing, as the
/// same safety net the paste path provides.
@MainActor
public final class TypeInserter: TextInserter {
    /// Max UTF-16 units per synthesised event. Long unicode payloads get
    /// dropped or truncated by some receivers, so the text is fed in small
    /// chunks. Chunks are cut on `Character` boundaries, so surrogate pairs and
    /// combining sequences are never split.
    nonisolated static let maxChunkUTF16 = 20
    /// Pause between chunks so the receiving app's input queue keeps up.
    private static let interChunkNanos: UInt64 = 8_000_000   // 8 ms

    public let copyTranscriptToClipboard: Bool

    public init(copyTranscriptToClipboard: Bool = true) {
        self.copyTranscriptToClipboard = copyTranscriptToClipboard
    }

    public func insert(_ text: String) async throws {
        guard Permissions.accessibility else { throw OWError.accessibilityNotGranted }
        guard !text.isEmpty else { return }

        if copyTranscriptToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            _ = pasteboard.setString(text, forType: .string)
        }

        let source = try SyntheticKeyboard.makeSource()

        // Newlines have to be real Return keystrokes: a "\n" in a unicode
        // payload is ignored or inserted literally depending on the app.
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                let newline = try SyntheticKeyboard.makePair(SyntheticKeyboard.keyReturn, source: source)
                SyntheticKeyboard.post(newline.down)
                SyntheticKeyboard.post(newline.up)
                await SyntheticKeyboard.settle(nanoseconds: Self.interChunkNanos)
            }
            for chunk in Self.chunks(of: line) {
                try Self.type(chunk, source: source)
                await SyntheticKeyboard.settle(nanoseconds: Self.interChunkNanos)
            }
        }

        Log.insert.debug("typed \(text.count, privacy: .public) characters")
    }

    // MARK: Chunking / event synthesis

    /// Splits a line into UTF-16 chunks of at most `maxChunkUTF16` units,
    /// cutting only between `Character`s. A single character wider than the
    /// limit (a long emoji sequence, say) is emitted whole in its own chunk
    /// rather than being broken.
    nonisolated static func chunks(of line: String, limit: Int = maxChunkUTF16) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in line {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > limit {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func type(_ units: [UniChar], source: CGEventSource) throws {
        let keys = try SyntheticKeyboard.makePair(SyntheticKeyboard.keyNone, source: source)
        units.withUnsafeBufferPointer { buffer in
            keys.down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            keys.up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        SyntheticKeyboard.post(keys.down)
        SyntheticKeyboard.post(keys.up)
    }
}
