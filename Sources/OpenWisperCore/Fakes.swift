import Foundation

// Scaffold stand-ins. They let the spine, tests, and demos run before the real
// components land, and remain useful for unit tests afterwards.

public struct FakeTranscriber: Transcriber {
    public let name = "fake"
    public var canned: String

    public init(canned: String = "um so this is like a fake transcript you know from the scaffold") {
        self.canned = canned
    }

    public func transcribe(_ clip: AudioClip) async throws -> String {
        try await Task.sleep(nanoseconds: 300_000_000)
        return canned
    }
}

public struct PassthroughCleaner: TranscriptCleaner {
    public let name = "passthrough"
    public init() {}
    public func clean(_ raw: String) async throws -> String { raw }
}

@MainActor
public final class PrintInserter: TextInserter {
    public init() {}
    public func insert(_ text: String) async throws {
        print("[PrintInserter] would insert: \(text)")
    }
}

/// An inserter that inserts nothing and remembers everything — for tests that
/// need to know what was handed to the real inserter, in what order, and what
/// happens when insertion fails.
///
/// `beforeInsert` runs before anything else in `insert(_:)`, which is how a
/// decorator's ordering can be observed from the outside: whatever it did on
/// the way in has already happened by the time the hook fires.
@MainActor
public final class SpyInserter: TextInserter {
    public private(set) var inserted: [String] = []
    /// When set, `insert(_:)` throws it *after* `beforeInsert` — the shape of a
    /// paste that reaches the frontmost app and is refused.
    public var failure: Error?
    public var beforeInsert: (() -> Void)?

    public init(failure: Error? = nil) {
        self.failure = failure
    }

    public func insert(_ text: String) async throws {
        beforeInsert?()
        if let failure { throw failure }
        inserted.append(text)
    }
}

@MainActor
public final class NoopIndicator: RecordingIndicator {
    public var onCancel: (() -> Void)?
    public init() {}
    public func show(_ state: PillState) {}
    public func updateLevel(_ level: Float) {}
    public func hide(after seconds: TimeInterval) {}
}
