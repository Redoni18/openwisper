import Foundation
import OpenWisperCore

/// Cloud speech-to-text against an OpenAI-compatible `audio/transcriptions`
/// endpoint — Groq (`whisper-large-v3-turbo`) or OpenAI (`whisper-1`).
///
/// The clip is encoded as 16-bit PCM WAV in memory and posted as
/// `multipart/form-data`; audio never touches disk.
public struct CloudTranscriber: Transcriber {
    /// `.groq` or `.openai` only — enforced in `init`.
    public let kind: EngineKind
    public let model: String
    /// ISO 639-1 code, or "auto" to let the service detect the language.
    public let language: String

    private let apiKey: String
    private let session: URLSession

    public var name: String { kind == .groq ? "groq-whisper" : "openai-whisper" }

    public init(kind: EngineKind, apiKey: String, model: String, language: String) {
        self.init(kind: kind, apiKey: apiKey, model: model, language: language, session: .shared)
    }

    /// Seam for tests / callers that want their own session; production goes
    /// through `URLSession.shared` (per-request `timeoutInterval` is what caps
    /// the call, so no bespoke configuration is needed).
    init(kind: EngineKind, apiKey: String, model: String, language: String, session: URLSession) {
        precondition(
            kind == .groq || kind == .openai,
            "CloudTranscriber only supports .groq and .openai — got .\(kind.rawValue)"
        )
        self.kind = kind
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.session = session
    }

    // MARK: Transcriber

    public func transcribe(_ clip: AudioClip) async throws -> String {
        // An empty clip would be rejected by the service with an opaque 400;
        // fail locally with the error the UI already knows how to present.
        guard !clip.samples.isEmpty else { throw OWError.emptyRecording }

        let wav = WavEncoder.wav16(from: clip)
        let request = try Self.buildRequest(
            kind: kind,
            apiKey: apiKey,
            model: model,
            language: language,
            wav: wav,
            boundary: MultipartBuilder.randomBoundary()
        )

        Log.stt.debug(
            "cloud STT \(self.name, privacy: .public): \(clip.duration, privacy: .public)s, \(wav.count, privacy: .public) bytes"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if CloudHTTP.isCancellation(error) { throw CancellationError() }
            throw OWError.network(CloudHTTP.shortReason(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw OWError.transcriptionFailed("no HTTP response")
        }
        guard CloudHTTP.okStatusCodes.contains(http.statusCode) else {
            Log.stt.error("cloud STT HTTP \(http.statusCode, privacy: .public)")
            throw OWError.transcriptionFailed("HTTP \(http.statusCode): \(CloudHTTP.bodySnippet(data))")
        }

        return try Self.parseTranscript(data)
    }

    // MARK: Request / response (pure, unit-tested)

    static func endpoint(for kind: EngineKind) -> String {
        kind == .groq ? Defaults.groqSTTURL : Defaults.openaiSTTURL
    }

    /// Builds the multipart request. Field order is fixed (`file`, `model`,
    /// `temperature`, `response_format`, then `language`) so the payload is
    /// reproducible; `language` is omitted entirely when set to "auto".
    static func buildRequest(
        kind: EngineKind,
        apiKey: String,
        model: String,
        language: String,
        wav: Data,
        boundary: String
    ) throws -> URLRequest {
        let endpoint = endpoint(for: kind)
        guard let url = URL(string: endpoint) else {
            throw OWError.transcriptionFailed("invalid endpoint URL \(endpoint)")
        }

        var multipart = MultipartBuilder(boundary: boundary)
        multipart.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        multipart.addField(name: "model", value: model)
        multipart.addField(name: "temperature", value: "0")
        multipart.addField(name: "response_format", value: "json")
        if language != "auto" {
            multipart.addField(name: "language", value: language)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Defaults.sttTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.finished()
        return request
    }

    /// `{"text": "…"}` — the `response_format=json` shape both services return.
    static func parseTranscript(_ data: Data) throws -> String {
        guard let payload = try? JSONDecoder().decode(STTResponse.self, from: data),
              let text = payload.text
        else {
            throw OWError.transcriptionFailed("unexpected response: \(CloudHTTP.bodySnippet(data))")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct STTResponse: Decodable {
    let text: String?
}
