import Foundation

// Shared HTTP plumbing for the two cloud clients in this target
// (`CloudTranscriber`, `LLMCleaner`). Kept internal — nothing here is part of
// the public surface the app wires up.

enum CloudHTTP {
    static let jsonContentType = "application/json"

    /// Success range used by both clients.
    static let okStatusCodes = 200..<300

    /// Deterministic JSON for request bodies. `.sortedKeys` keeps the byte
    /// output stable so payload builders can be asserted in unit tests.
    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// A single-line, length-capped excerpt of a response body — short enough to
    /// put in an `OWError` message that ends up in the pill and the unified log.
    /// Newlines and tabs are collapsed to single spaces so multi-line provider
    /// error payloads stay readable.
    static func bodySnippet(_ data: Data, limit: Int = 200) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let collapsed = text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit))
    }

    /// Short, user-presentable reason for a transport failure. `URLError`'s own
    /// descriptions are full sentences; the common cases get terser wording
    /// because they are rendered inside "Network error: …".
    static func shortReason(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return (error as NSError).localizedDescription
        }
        switch urlError.code {
        case .timedOut: return "request timed out"
        case .notConnectedToInternet: return "no internet connection"
        case .cannotFindHost: return "cannot find host"
        case .cannotConnectToHost: return "cannot connect to host"
        case .networkConnectionLost: return "connection lost"
        case .dnsLookupFailed: return "DNS lookup failed"
        case .secureConnectionFailed: return "secure connection failed"
        case .cancelled: return "request cancelled"
        default: return urlError.localizedDescription
        }
    }

    /// True when the error means "the caller cancelled us", which must be
    /// propagated as cancellation rather than reported as a network failure —
    /// pressing Esc mid-dictation should not surface an error in the pill.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: Array(string.utf8))
    }

    /// Appends `value`'s little-endian byte representation (host-independent).
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        // Qualified: unqualified `withUnsafeBytes` would resolve to Data's own
        // instance method inside this extension.
        Swift.withUnsafeBytes(of: &little) { self.append(contentsOf: $0) }
    }
}
