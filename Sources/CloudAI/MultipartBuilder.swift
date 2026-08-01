import Foundation

/// Minimal `multipart/form-data` writer (RFC 7578) — enough for the handful of
/// text fields plus one WAV part the transcription endpoints need.
///
/// The boundary is injectable so the produced payload can be asserted
/// byte-for-byte in unit tests; production callers use `randomBoundary()`.
struct MultipartBuilder {
    let boundary: String
    private var body = Data()

    init(boundary: String = MultipartBuilder.randomBoundary()) {
        self.boundary = boundary
    }

    /// Long and random enough that it cannot occur inside a WAV payload.
    static func randomBoundary() -> String {
        "----OpenWisper\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    /// Value for the request's `Content-Type` header.
    var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8(value)
        body.appendUTF8("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendUTF8("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.appendUTF8("\r\n")
    }

    /// The complete body, including the closing boundary. Non-mutating so a
    /// builder can be inspected without being consumed.
    func finished() -> Data {
        var out = body
        out.appendUTF8("--\(boundary)--\r\n")
        return out
    }
}
