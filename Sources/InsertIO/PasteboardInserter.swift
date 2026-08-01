import AppKit
import CoreGraphics
import Foundation
import OpenWisperCore

/// One entry per `NSPasteboardItem`: every representation type it offered,
/// mapped to that representation's bytes.
typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

/// Default insertion path: put the transcript on the general pasteboard, send a
/// synthetic Cmd-V, then put the user's clipboard back.
///
/// Restoration is deliberately conservative. It runs on a detached task after
/// `restoreDelayMs` and only proceeds if `NSPasteboard.general.changeCount` is
/// still the value produced by our own write — if any app touched the clipboard
/// in the meantime we leave it alone rather than clobber newer content.
@MainActor
public final class PasteboardInserter: TextInserter {
    /// How long after Cmd-V the previous clipboard is put back.
    /// Only relevant when `keepTranscriptOnClipboard` is false.
    public let restoreDelayMs: Int

    /// When true (the default config), the transcript deliberately *stays* on
    /// the clipboard after the paste — the safety net for a paste that landed
    /// nowhere: the user can just ⌘V it themselves. No snapshot is taken and
    /// nothing is restored. When false, the original snapshot-and-restore
    /// behavior applies.
    public let keepTranscriptOnClipboard: Bool

    /// Let the pasteboard write propagate before the paste keystroke lands.
    /// The pasteboard is cross-process state; pasting immediately can race and
    /// make the target app read the previous contents.
    private static let pasteSettleNanos: UInt64 = 80_000_000   // 80 ms
    /// Cmd-V key-down hold. Some apps ignore a zero-length keypress.
    private static let keyHoldNanos: UInt64 = 20_000_000       // 20 ms

    public init(restoreDelayMs: Int, keepTranscriptOnClipboard: Bool = true) {
        self.restoreDelayMs = restoreDelayMs
        self.keepTranscriptOnClipboard = keepTranscriptOnClipboard
    }

    public func insert(_ text: String) async throws {
        // Checked first and unconditionally: without Accessibility the Cmd-V
        // silently does nothing, and we must not destroy the user's clipboard
        // for a paste that cannot happen.
        guard Permissions.accessibility else { throw OWError.accessibilityNotGranted }
        guard !text.isEmpty else { return }

        let source = try SyntheticKeyboard.makeSource()
        let pasteboard = NSPasteboard.general
        // In keep-mode the transcript replaces the clipboard on purpose, so
        // there is nothing to snapshot and nothing to restore.
        let snapshot = keepTranscriptOnClipboard ? [] : Self.snapshot(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // We already cleared it — put the user's clipboard back before
            // reporting the failure. Passing the live change count makes the
            // "untouched" check trivially true: we know we are the last writer.
            if !keepTranscriptOnClipboard {
                Self.restoreIfUntouched(snapshot, expectedChangeCount: pasteboard.changeCount)
            }
            throw OWError.insertionFailed("could not write the transcript to the pasteboard")
        }
        let writeChangeCount = pasteboard.changeCount

        await SyntheticKeyboard.settle(nanoseconds: Self.pasteSettleNanos)

        let keys = try SyntheticKeyboard.makePair(SyntheticKeyboard.keyV, source: source, flags: .maskCommand)
        SyntheticKeyboard.post(keys.down)
        await SyntheticKeyboard.settle(nanoseconds: Self.keyHoldNanos)
        SyntheticKeyboard.post(keys.up)

        Log.insert.debug("pasted \(text.count, privacy: .public) characters")

        // Contract: return as soon as the paste has been issued. In keep-mode
        // the transcript stays on the clipboard (that's the feature); otherwise
        // restoration outlives this call.
        if !keepTranscriptOnClipboard {
            Self.scheduleRestore(snapshot, expectedChangeCount: writeChangeCount, afterMs: restoreDelayMs)
        }
    }

    // MARK: Clipboard snapshot / restore

    /// Captures every item and every readable representation on the pasteboard.
    /// Lazily-promised representations (file promises and similar) return no
    /// data and are skipped — there is no way to snapshot those by value.
    static func snapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { representations[type] = data }
            }
            return representations
        }
    }

    static func scheduleRestore(
        _ snapshot: PasteboardSnapshot,
        expectedChangeCount: Int,
        afterMs: Int
    ) {
        let delayNanos = UInt64(max(0, afterMs)) * 1_000_000
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: delayNanos)
            await MainActor.run {
                restoreIfUntouched(snapshot, expectedChangeCount: expectedChangeCount)
            }
        }
    }

    /// Restores `snapshot` only if nothing has written to the pasteboard since
    /// our own write. Every write bumps `changeCount`, so an inequality here
    /// means another app owns the clipboard now — skip, never clobber.
    static func restoreIfUntouched(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == expectedChangeCount else {
            Log.insert.debug("clipboard changed since paste — skipping restore")
            return
        }

        // Clearing first also covers the "clipboard was empty before" case.
        pasteboard.clearContents()

        let items: [NSPasteboardItem] = snapshot.compactMap { representations in
            guard !representations.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }
}
