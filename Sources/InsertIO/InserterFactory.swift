import OpenWisperCore

/// Builds the inserter the config asks for.
///
/// Both inserters require Accessibility permission; neither checks it here, so
/// this is safe to call during startup before the user has granted anything.
/// The permission is enforced on every `insert(_:)` call instead.
@MainActor
public func makeInserter(_ cfg: InsertConfig) -> TextInserter {
    switch cfg.mode {
    case .paste:
        return PasteboardInserter(
            restoreDelayMs: cfg.restoreClipboardDelayMs,
            keepTranscriptOnClipboard: cfg.copyToClipboard
        )
    case .type:
        return TypeInserter(copyTranscriptToClipboard: cfg.copyToClipboard)
    }
}
