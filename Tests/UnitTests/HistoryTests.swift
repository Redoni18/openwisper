import Foundation
import Testing

@testable import OpenWisperCore

// ============================================================================
// Local transcript history (Wave D): config decoding, the file-backed store,
// and the inserter decorator that feeds it.
//
// Every store here is pointed at a fresh directory under /tmp — nothing in this
// file may ever touch ~/Library/Application Support/OpenWisper/history.json.
// ============================================================================

/// Scratch directory for one test, removed when it goes out of scope.
private final class HistoryScratch {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("history.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwisper-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Ordered event log — how the decorator's "record first, then insert" is
/// observed from the outside.
@MainActor
private final class HistoryEventLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Entry-for-entry comparison that allows for the on-disk format's millisecond
/// resolution — the only thing a save/load round trip is allowed to change.
private func historyMatches(_ lhs: [TranscriptEntry], _ rhs: [TranscriptEntry]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { left, right in
        left.id == right.id
            && left.text == right.text
            && left.engine == right.engine
            && abs(left.date.timeIntervalSince(right.date)) < 0.001
    }
}

// MARK: - Config

@Suite("History config")
struct HistoryConfigTests {

    @Test("A config with no history section gets the defaults")
    func missingSection() throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(cfg.history.enabled)
        #expect(cfg.history.maxEntries == 200)
    }

    @Test("An empty history section gets the defaults")
    func emptySection() throws {
        let json = #"{"history": {}}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.history.enabled)
        #expect(cfg.history.maxEntries == 200)
    }

    @Test("Garbage values fall back to the defaults, key by key")
    func garbageValues() throws {
        let json = #"{"history": {"enabled": "yes", "maxEntries": "lots"}}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.history.enabled)
        #expect(cfg.history.maxEntries == 200)
    }

    @Test("A history section that is not even an object falls back to the defaults")
    func garbageSection() throws {
        let json = #"{"history": 42}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(cfg.history.enabled)
        #expect(cfg.history.maxEntries == 200)
    }

    @Test("One overridden key leaves its sibling — and every other section — alone")
    func partialSection() throws {
        let json = #"{"history": {"enabled": false}}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!cfg.history.enabled)
        #expect(cfg.history.maxEntries == 200, "sibling defaults must survive a partial history block")
        #expect(cfg.hotkey.key == "fn", "other sections must be untouched")
        #expect(cfg.cleanup.provider == .auto)
    }

    @Test("history survives an encode/decode round trip")
    func roundTrip() throws {
        var cfg = AppConfig()
        cfg.history = HistoryConfig(enabled: false, maxEntries: 25)
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        #expect(!back.history.enabled)
        #expect(back.history.maxEntries == 25)
    }
}

// MARK: - Store

@Suite("Transcript history store")
@MainActor
struct TranscriptHistoryStoreTests {

    @Test("append prepends, and what it wrote is what a second store reads back")
    func appendPrependsAndPersists() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)

        store.append(text: "first thing said", engine: "local")
        store.append(text: "second thing said", engine: "groq")

        #expect(store.entries.map(\.text) == ["second thing said", "first thing said"])
        #expect(store.entries.first?.engine == "groq")

        let reloaded = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(reloaded.entries.map(\.text) == store.entries.map(\.text))
        #expect(reloaded.entries.map(\.id) == store.entries.map(\.id), "ids must survive, or list identity churns")
        #expect(
            historyMatches(reloaded.entries, store.entries),
            "every field must round-trip through the file, timestamps included"
        )
    }

    @Test("The cap drops the oldest entries, and the trimmed list is what persists")
    func capDropsOldest() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL, maxEntries: 3)

        for index in 1...6 {
            store.append(text: "utterance \(index)", engine: "local")
        }

        #expect(store.entries.map(\.text) == ["utterance 6", "utterance 5", "utterance 4"])

        let reloaded = TranscriptHistoryStore(fileURL: scratch.fileURL, maxEntries: 3)
        #expect(reloaded.entries.map(\.text) == ["utterance 6", "utterance 5", "utterance 4"])
    }

    @Test("maxEntries is clamped to 1…10000")
    func maxEntriesIsClamped() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL, maxEntries: 0)
        #expect(store.maxEntries == 1)

        store.maxEntries = -50
        #expect(store.maxEntries == 1)

        store.maxEntries = 50_000
        #expect(store.maxEntries == 10_000)
    }

    @Test("Lowering maxEntries trims what is already stored")
    func loweringTheCapTrims() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL, maxEntries: 10)
        for index in 1...5 {
            store.append(text: "utterance \(index)", engine: "local")
        }

        store.maxEntries = 2

        #expect(store.entries.map(\.text) == ["utterance 5", "utterance 4"])
        let reloaded = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(reloaded.entries.count == 2, "the trim must reach the file, not just memory")
    }

    @Test("delete removes one entry and persists the rest")
    func deletePersists() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        store.append(text: "keep me", engine: "local")
        store.append(text: "delete me", engine: "local")

        let doomed = try #require(store.entries.first { $0.text == "delete me" })
        store.delete(id: doomed.id)

        #expect(store.entries.map(\.text) == ["keep me"])
        let reloaded = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(reloaded.entries.map(\.text) == ["keep me"])
    }

    @Test("Deleting an id that is not there changes nothing")
    func deleteUnknownIsANoOp() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        store.append(text: "still here", engine: "local")

        store.delete(id: UUID())

        #expect(store.entries.count == 1)
    }

    @Test("clear empties the store and the file")
    func clearPersists() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        store.append(text: "one", engine: "local")
        store.append(text: "two", engine: "local")

        store.clear()

        #expect(store.entries.isEmpty)
        let reloaded = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(reloaded.entries.isEmpty)
    }

    @Test("A disabled store ignores append and writes nothing")
    func disabledStoreIgnoresAppend() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL, isEnabled: false)

        store.append(text: "should not be recorded", engine: "local")

        #expect(store.entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: scratch.fileURL.path),
            "history off must not even create the file"
        )
    }

    @Test("Turning history back on resumes recording, and leaves earlier entries alone")
    func togglingEnabled() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        store.append(text: "before", engine: "local")

        store.isEnabled = false
        store.append(text: "during", engine: "local")
        #expect(store.entries.map(\.text) == ["before"], "turning it off must not delete anything")

        store.isEnabled = true
        store.append(text: "after", engine: "local")
        #expect(store.entries.map(\.text) == ["after", "before"])
    }

    @Test("Blank text is never recorded")
    func blankTextIsIgnored() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)

        store.append(text: "", engine: "local")
        store.append(text: "   \n\t ", engine: "local")

        #expect(store.entries.isEmpty)
    }

    @Test("A corrupt file loads as an empty store, and the next write repairs it")
    func corruptFileIsSurvivable() throws {
        let scratch = try HistoryScratch()
        try Data("{ this is not json at all".utf8).write(to: scratch.fileURL)

        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(store.entries.isEmpty)

        store.append(text: "written over the wreckage", engine: "local")
        let reloaded = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(reloaded.entries.map(\.text) == ["written over the wreckage"])
    }

    @Test("A missing file loads as an empty store")
    func missingFileIsEmpty() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(store.entries.isEmpty)
    }

    @Test("onChange fires once per mutation and never for a no-op")
    func onChangeFires() throws {
        let scratch = try HistoryScratch()
        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        var changes = 0
        store.onChange = { changes += 1 }

        store.append(text: "one", engine: "local")
        #expect(changes == 1)

        store.append(text: "  ", engine: "local")
        #expect(changes == 1, "a blank transcript is not a change")

        store.delete(id: UUID())
        #expect(changes == 1, "deleting nothing is not a change")

        let entry = try #require(store.entries.first)
        store.delete(id: entry.id)
        #expect(changes == 2)

        store.clear()
        #expect(changes == 3)
    }

    @Test("A hand-written file without fractional seconds still loads")
    func tolerantDateParsing() throws {
        let scratch = try HistoryScratch()
        let json = """
        [
          {
            "id": "8B2C4F1A-0000-4000-8000-000000000001",
            "text": "typed straight into the file",
            "date": "2026-03-04T09:15:00Z",
            "engine": "local"
          }
        ]
        """
        try Data(json.utf8).write(to: scratch.fileURL)

        let store = TranscriptHistoryStore(fileURL: scratch.fileURL)
        #expect(store.entries.map(\.text) == ["typed straight into the file"])
    }
}

// MARK: - Inserter decorator

@Suite("History recording inserter")
@MainActor
struct HistoryRecordingInserterTests {

    private func makeStore(_ scratch: HistoryScratch, enabled: Bool = true) -> TranscriptHistoryStore {
        TranscriptHistoryStore(fileURL: scratch.fileURL, isEnabled: enabled)
    }

    @Test("The transcript is recorded before it is handed on")
    func recordsThenDelegates() async throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let log = HistoryEventLog()
        let spy = SpyInserter()

        store.onChange = { log.record("history") }
        spy.beforeInsert = { log.record("insert") }

        let inserter = HistoryRecordingInserter(
            wrapping: spy, store: store, engineName: { "local" }
        )
        try await inserter.insert("the words that were said")

        #expect(log.events == ["history", "insert"], "history must be written before the paste is attempted")
        #expect(spy.inserted == ["the words that were said"])
        #expect(store.entries.map(\.text) == ["the words that were said"])
    }

    @Test("The transcript survives an insertion that throws, and the error still propagates")
    func recordsEvenWhenInsertionFails() async throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let spy = SpyInserter(failure: OWError.insertionFailed("nothing focused"))

        let inserter = HistoryRecordingInserter(
            wrapping: spy, store: store, engineName: { "groq" }
        )

        let thrown = await #expect(throws: OWError.self) {
            try await inserter.insert("do not lose this")
        }
        guard case .insertionFailed = try #require(thrown) else {
            Issue.record("expected .insertionFailed, got \(String(describing: thrown))")
            return
        }

        #expect(spy.inserted.isEmpty, "the paste never happened")
        #expect(store.entries.map(\.text) == ["do not lose this"], "…but the words are recoverable")
        #expect(store.entries.first?.engine == "groq")
    }

    @Test("A disabled store records nothing, and insertion is unaffected")
    func respectsADisabledStore() async throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch, enabled: false)
        let spy = SpyInserter()

        let inserter = HistoryRecordingInserter(
            wrapping: spy, store: store, engineName: { "local" }
        )
        try await inserter.insert("not recorded, still pasted")

        #expect(store.entries.isEmpty)
        #expect(spy.inserted == ["not recorded, still pasted"])
    }

    @Test("The engine name is read per insertion, not captured once")
    func engineNameIsReadEachTime() async throws {
        let scratch = try HistoryScratch()
        let store = makeStore(scratch)
        let spy = SpyInserter()
        var engine = "local"

        let inserter = HistoryRecordingInserter(
            wrapping: spy, store: store, engineName: { engine }
        )
        try await inserter.insert("spoken on the local engine")
        engine = "openai"
        try await inserter.insert("spoken after switching engines")

        #expect(store.entries.map(\.engine) == ["openai", "local"])
    }
}
