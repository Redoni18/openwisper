import Foundation

// Local transcript history: the record of what OpenWisper actually inserted,
// so a paste that landed nowhere (no focused text field, wrong app in front,
// an insertion that threw) is recoverable instead of lost.
//
// This is the one place in OpenWisper that writes user speech to disk, so the
// rules around it are deliberately narrow: a single JSON file under the user's
// own Application Support directory, owner-readable only, capped, switchable
// off in one place, and never sent anywhere. Nothing here logs transcript text.

/// One inserted transcript, exactly as it went into the focused app.
///
/// `id` exists so SwiftUI lists have stable identity across a reload from disk;
/// two entries with identical text and timestamps are still separate rows.
public struct TranscriptEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let date: Date
    /// Short engine name — `"local"`, `"groq"`, `"openai"`. Free-form on
    /// purpose: history outlives any particular `EngineKind` case list, and an
    /// entry recorded by a build that knew about an engine this one does not
    /// should still display.
    public let engine: String

    public init(id: UUID = UUID(), text: String, date: Date = Date(), engine: String) {
        self.id = id
        self.text = text
        self.date = date
        self.engine = engine
    }
}

/// The transcript history, backed by one JSON file.
///
/// Main-actor because the window reads `entries` straight out of it and because
/// `onChange` drives SwiftUI; the writes it performs are small (a few hundred
/// short strings) and happen once per utterance, so write-on-mutate is cheaper
/// in practice than the bookkeeping a debounced writer would need.
///
/// The file URL is injectable so tests — and the window demo — never touch the
/// real user's history.
@MainActor
public final class TranscriptHistoryStore {

    /// Bounds on `maxEntries`. The lower bound keeps "history on" meaningful;
    /// the upper bound keeps a hand-edited config from turning a synchronous
    /// per-utterance write into something you can feel.
    public static let maxEntriesRange = 1...10_000

    /// Where the history lives. Fixed for the lifetime of the store.
    public let fileURL: URL

    /// Newest first — the order the History page displays, and the order the
    /// file is written in, so the file reads the same way.
    public private(set) var entries: [TranscriptEntry] = []

    /// When false, `append` does nothing. Existing entries are left alone:
    /// turning history off is not the same as deleting what is already there
    /// (that is `clear()`).
    public var isEnabled: Bool

    /// Cap on stored entries; anything past it is dropped oldest-first.
    /// Assigning a value outside `maxEntriesRange` clamps it, and lowering the
    /// cap trims the existing entries immediately rather than waiting for the
    /// next utterance.
    public var maxEntries: Int {
        didSet {
            let clamped = Self.clamp(maxEntries)
            guard clamped == maxEntries else {
                // Re-enters this observer exactly once, with a value that is
                // already in range, which is the branch that does the trimming.
                maxEntries = clamped
                return
            }
            guard trimToCap() else { return }
            persist()
            onChange?()
        }
    }

    /// Fired on the main actor after every mutation (append, delete, clear, or
    /// a cap change that dropped something), so an open window can re-read
    /// `entries`. One observer: the main window installs itself here.
    public var onChange: (() -> Void)?

    public init(
        fileURL: URL = AppPaths.historyURL,
        isEnabled: Bool = true,
        maxEntries: Int = HistoryConfig().maxEntries
    ) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
        // Property observers do not run for assignments made inside `init`, so
        // the clamp and the initial trim are done by hand here.
        self.maxEntries = Self.clamp(maxEntries)
        self.entries = Self.load(from: fileURL)
        _ = trimToCap()
    }

    // MARK: - Mutation

    /// Records an inserted transcript. No-op when history is off or the text is
    /// blank — a whitespace-only "transcript" is not worth a row.
    ///
    /// Called *before* the text is handed to the real inserter (see
    /// `HistoryRecordingInserter`), which is the whole point: the entry has to
    /// survive an insertion that throws.
    public func append(text: String, engine: String) {
        guard isEnabled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        entries.insert(TranscriptEntry(text: text, engine: engine), at: 0)
        _ = trimToCap()
        persist()
        onChange?()
    }

    public func delete(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        persist()
        onChange?()
    }

    /// Empties the history and rewrites the file. Deliberately unconditional:
    /// it is also the repair path for a file that failed to parse, where
    /// `entries` is already empty but the bad bytes are still on disk.
    public func clear() {
        entries.removeAll()
        persist()
        onChange?()
    }

    // MARK: - Persistence

    /// Pretty-printed with sorted keys: the file is documented in the README as
    /// somewhere the user can go and look, so it should be readable when they
    /// do. Date handling is in `HistoryDate` below.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(HistoryDate.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = HistoryDate.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an ISO-8601 date"
                )
            }
            return date
        }
        return decoder
    }()

    /// Missing file → empty. Unreadable or corrupt file → empty, one log line,
    /// and the next mutation overwrites it. History is a convenience; it must
    /// never be a reason the app fails to start.
    private static func load(from url: URL) -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try decoder.decode([TranscriptEntry].self, from: Data(contentsOf: url))
        } catch {
            Log.app.error(
                "Could not read transcript history at \(url.path) — starting empty: \(String(describing: error))"
            )
            return []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
            // An atomic write replaces the file, so the mode has to be re-applied
            // every time. This file is a verbatim record of everything dictated
            // on this Mac; nobody else on the machine needs to read it.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            Log.app.error(
                "Could not write transcript history to \(self.fileURL.path): \(String(describing: error))"
            )
        }
    }

    // MARK: - Helpers

    private static func clamp(_ value: Int) -> Int {
        min(max(value, maxEntriesRange.lowerBound), maxEntriesRange.upperBound)
    }

    /// Drops the oldest entries past the cap. Returns whether anything went.
    @discardableResult
    private func trimToCap() -> Bool {
        guard entries.count > maxEntries else { return false }
        entries.removeLast(entries.count - maxEntries)
        return true
    }
}

// MARK: - Date format

/// How a timestamp is written into `history.json`.
///
/// Lives outside `TranscriptHistoryStore` because the coding strategies that
/// use it are `@Sendable` closures, and a main-actor-isolated static cannot be
/// touched from one. Formatters are held rather than rebuilt per date: a
/// two-hundred-entry save would otherwise construct four hundred of them.
private enum HistoryDate {
    /// Fractional seconds are included because `JSONEncoder`'s stock `.iso8601`
    /// truncates to whole seconds, which would collapse the ordering of two
    /// utterances dictated back to back. Millisecond resolution is as fine as
    /// the format goes, and far finer than anything the UI shows.
    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The same format without fractional seconds — what a hand-edited file, or
    /// one written by something else, is likely to contain.
    static let isoWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        iso.string(from: date)
    }

    static func date(from text: String) -> Date? {
        iso.date(from: text) ?? isoWithoutFraction.date(from: text)
    }
}

// MARK: - Inserter decorator

/// A `TextInserter` that records the transcript to history and then hands it to
/// the inserter it wraps.
///
/// The order is the contract: history is written **first**, so a paste that
/// lands nowhere — or an `insert` that throws outright — still leaves the words
/// somewhere the user can get at them. It also keeps `DictationController` out
/// of it entirely; history is a property of insertion, not of the state machine.
@MainActor
public final class HistoryRecordingInserter: TextInserter {
    private let wrapped: TextInserter
    private let store: TranscriptHistoryStore
    /// Read per insertion rather than captured: the engine can change under a
    /// running app (menu bar, window, config reload) and the entry should say
    /// which one actually produced these words.
    private let engineName: () -> String

    public init(
        wrapping wrapped: TextInserter,
        store: TranscriptHistoryStore,
        engineName: @escaping () -> String
    ) {
        self.wrapped = wrapped
        self.store = store
        self.engineName = engineName
    }

    public func insert(_ text: String) async throws {
        store.append(text: text, engine: engineName())
        try await wrapped.insert(text)
    }
}
