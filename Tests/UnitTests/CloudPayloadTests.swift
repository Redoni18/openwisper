import Foundation
import Testing

@testable import CloudAI
import OpenWisperCore

/// Everything about the cloud clients that can be checked without a network:
/// provider selection, exact request payloads, and response parsing. The HTTP
/// round trip itself is left to manual/integration verification — no API keys
/// exist in CI and these tests must stay offline.
@Suite("Cloud payloads")
struct CloudPayloadTests {

    private let allKeys = Env(values: [
        "GROQ_API_KEY": "gsk-groq",
        "OPENAI_API_KEY": "sk-openai",
        "ANTHROPIC_API_KEY": "sk-ant",
    ])

    // MARK: - Cleanup provider resolution

    @Test("`auto` prefers Groq, then OpenAI, then Anthropic")
    func autoPrefersGroqThenOpenAIThenAnthropic() throws {
        let auto = CleanupConfig(provider: .auto)

        let first = try #require(LLMCleaner.resolveProvider(auto, env: allKeys))
        #expect(first.provider == .groq)
        #expect(first.apiKey == "gsk-groq")

        let withoutGroq = Env(values: ["OPENAI_API_KEY": "sk-openai", "ANTHROPIC_API_KEY": "sk-ant"])
        let second = try #require(LLMCleaner.resolveProvider(auto, env: withoutGroq))
        #expect(second.provider == .openai)
        #expect(second.apiKey == "sk-openai")

        let anthropicOnly = Env(values: ["ANTHROPIC_API_KEY": "sk-ant"])
        let third = try #require(LLMCleaner.resolveProvider(auto, env: anthropicOnly))
        #expect(third.provider == .anthropic)
        #expect(third.apiKey == "sk-ant")
    }

    @Test("`auto` with no key at all resolves to nil")
    func autoWithoutAnyKeyResolvesToNil() {
        #expect(LLMCleaner.resolveProvider(CleanupConfig(provider: .auto), env: Env(values: [:])) == nil)
        // Unrelated keys present, but none of the three providers'.
        let irrelevant = Env(values: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        #expect(LLMCleaner.resolveProvider(CleanupConfig(provider: .auto), env: irrelevant) == nil)
    }

    @Test("An explicit provider never borrows another provider's key")
    func explicitProviderWithoutItsKeyResolvesToNil() {
        let onlyOpenAI = Env(values: ["OPENAI_API_KEY": "sk-openai"])
        #expect(
            LLMCleaner.resolveProvider(CleanupConfig(provider: .groq), env: onlyOpenAI) == nil,
            "an explicit provider never falls back to another provider's key"
        )
        #expect(LLMCleaner.resolveProvider(CleanupConfig(provider: .anthropic), env: onlyOpenAI) == nil)
        #expect(LLMCleaner.resolveProvider(CleanupConfig(provider: .openai), env: onlyOpenAI) != nil)
    }

    @Test("An explicit provider uses its own key")
    func explicitProviderUsesItsOwnKey() throws {
        let resolved = try #require(
            LLMCleaner.resolveProvider(CleanupConfig(provider: .anthropic), env: allKeys)
        )
        #expect(resolved.provider == .anthropic)
        #expect(resolved.apiKey == "sk-ant")
    }

    @Test("A blank key counts as missing")
    func blankKeyCountsAsMissing() {
        // Env's subscript already treats whitespace-only values as absent; make
        // sure resolution inherits that instead of building a broken client.
        let blank = Env(values: ["GROQ_API_KEY": "   "])
        #expect(LLMCleaner.resolveProvider(CleanupConfig(provider: .groq), env: blank) == nil)
        #expect(LLMCleaner.resolveProvider(CleanupConfig(provider: .auto), env: blank) == nil)
    }

    // MARK: - Cleaner construction

    @Test("`make` uses the resolved provider and its default model")
    func makeUsesResolvedProviderAndDefaultModel() throws {
        let cleaner = try #require(LLMCleaner.make(config: CleanupConfig(provider: .auto), env: allKeys))
        #expect(cleaner.provider == .groq)
        #expect(cleaner.model == Defaults.groqLLMModel)
        #expect(cleaner.name == "groq-cleanup")
        #expect(cleaner.timeoutSeconds == CleanupConfig().timeoutSeconds)
    }

    @Test("`make` honours an explicit model and timeout")
    func makeHonoursExplicitModelAndTimeout() throws {
        let config = CleanupConfig(provider: .openai, model: "gpt-4.1-mini", timeoutSeconds: 2.5)
        let cleaner = try #require(LLMCleaner.make(config: config, env: allKeys))
        #expect(cleaner.provider == .openai)
        #expect(cleaner.model == "gpt-4.1-mini")
        #expect(cleaner.timeoutSeconds == 2.5)
        #expect(cleaner.name == "openai-cleanup")
    }

    @Test("`make` returns nil when cleanup is disabled or keyless")
    func makeReturnsNilWhenDisabledOrKeyless() {
        #expect(LLMCleaner.make(config: CleanupConfig(enabled: false), env: allKeys) == nil)
        #expect(LLMCleaner.make(config: CleanupConfig(provider: .auto), env: Env(values: [:])) == nil)
    }

    @Test("Each provider has the documented default model")
    func defaultModelPerProvider() {
        #expect(LLMCleaner.model(for: .groq, override: nil) == Defaults.groqLLMModel)
        #expect(LLMCleaner.model(for: .openai, override: nil) == Defaults.openaiLLMModel)
        #expect(LLMCleaner.model(for: .anthropic, override: nil) == Defaults.anthropicLLMModel)
        #expect(LLMCleaner.model(for: .groq, override: "   ") == Defaults.groqLLMModel, "blank override ignored")
        #expect(LLMCleaner.model(for: .groq, override: " custom ") == "custom", "override is trimmed")
    }

    // MARK: - Multipart transcription payload

    /// Full byte-for-byte payload. Field order and CRLF placement are what the
    /// endpoints actually parse, so this is asserted exactly rather than by
    /// substring.
    @Test("The multipart body is byte-for-byte what the endpoints expect")
    func multipartBodyExactBytes() throws {
        let request = try CloudTranscriber.buildRequest(
            kind: .openai,
            apiKey: "sk-test",
            model: "whisper-1",
            language: "en",
            wav: Data("WAVBYTES".utf8),
            boundary: "TESTBOUNDARY"
        )

        let expected = [
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n",
            "Content-Type: audio/wav\r\n",
            "\r\n",
            "WAVBYTES\r\n",
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"model\"\r\n",
            "\r\n",
            "whisper-1\r\n",
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"temperature\"\r\n",
            "\r\n",
            "0\r\n",
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"response_format\"\r\n",
            "\r\n",
            "json\r\n",
            "--TESTBOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"language\"\r\n",
            "\r\n",
            "en\r\n",
            "--TESTBOUNDARY--\r\n",
        ].joined()

        #expect(request.httpBody == Data(expected.utf8))
        #expect(request.httpBody?.count == 437)
    }

    @Test("`language: auto` is omitted from the payload entirely")
    func multipartOmitsLanguageWhenAuto() throws {
        let request = try CloudTranscriber.buildRequest(
            kind: .groq,
            apiKey: "gsk-test",
            model: Defaults.groqSTTModel,
            language: "auto",
            wav: Data("W".utf8),
            boundary: "B"
        )
        let bodyData = try #require(request.httpBody)
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(!body.contains("name=\"language\""), "\"auto\" means let the service detect")
        #expect(body.contains("name=\"model\"\r\n\r\n\(Defaults.groqSTTModel)\r\n"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test("Transcription requests carry the right headers and endpoints")
    func multipartRequestHeadersAndEndpoints() throws {
        let groq = try CloudTranscriber.buildRequest(
            kind: .groq, apiKey: "gsk-test", model: "m", language: "en",
            wav: Data(), boundary: "BOUND"
        )
        #expect(groq.url?.absoluteString == Defaults.groqSTTURL)
        #expect(groq.httpMethod == "POST")
        #expect(groq.timeoutInterval == Defaults.sttTimeoutSeconds)
        #expect(groq.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-test")
        #expect(groq.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND")

        let openai = try CloudTranscriber.buildRequest(
            kind: .openai, apiKey: "sk-test", model: "m", language: "en",
            wav: Data(), boundary: "BOUND"
        )
        #expect(openai.url?.absoluteString == Defaults.openaiSTTURL)
        #expect(openai.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test("The WAV bytes are embedded unmodified")
    func multipartCarriesTheWavBytesVerbatim() throws {
        let clip = AudioClip(samples: [0, 0.5, -0.5, 1], sampleRate: 16000)
        let wav = WavEncoder.wav16(from: clip)
        let request = try CloudTranscriber.buildRequest(
            kind: .groq, apiKey: "k", model: "m", language: "en", wav: wav, boundary: "BOUND"
        )
        let body = try #require(request.httpBody)
        #expect(body.range(of: wav) != nil, "the WAV must be embedded unmodified")
        #expect(body.count > wav.count)
    }

    @Test("Transcriber names and endpoints match the provider")
    func transcriberNamesAndEndpoints() {
        #expect(CloudTranscriber(kind: .groq, apiKey: "k", model: "m", language: "en").name == "groq-whisper")
        #expect(CloudTranscriber(kind: .openai, apiKey: "k", model: "m", language: "en").name == "openai-whisper")
        #expect(CloudTranscriber.endpoint(for: .groq) == Defaults.groqSTTURL)
        #expect(CloudTranscriber.endpoint(for: .openai) == Defaults.openaiSTTURL)
    }

    @Test("Multipart boundaries are unique and namespaced")
    func randomBoundariesAreUnique() {
        let a = MultipartBuilder.randomBoundary()
        let b = MultipartBuilder.randomBoundary()
        #expect(a != b)
        #expect(a.hasPrefix("----OpenWisper"))
    }

    // MARK: - Cleanup request payloads

    @Test("The chat/completions body has the OpenAI-compatible shape")
    func chatCompletionsBodyShape() throws {
        let raw = "um so like this is the raw transcript"
        let body = try LLMCleaner.chatBody(model: "gpt-4o-mini", raw: raw)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(object["model"] as? String == "gpt-4o-mini")
        #expect(object["temperature"] as? Int == 0)
        #expect(object["system"] == nil, "the system prompt goes in messages for OpenAI-compatible APIs")

        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == Defaults.cleanupSystemPrompt)
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == raw)

        // Temperature must serialise as a bare 0, not "0" or 0.0000001.
        #expect(String(decoding: body, as: UTF8.self).contains("\"temperature\":0"))
    }

    @Test("The Anthropic body puts the system prompt at the top level")
    func anthropicBodyShape() throws {
        let raw = "um so like this is the raw transcript"
        let body = try LLMCleaner.anthropicBody(model: Defaults.anthropicLLMModel, raw: raw)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(object["model"] as? String == Defaults.anthropicLLMModel)
        #expect(object["max_tokens"] as? Int == 4096)
        #expect(object["system"] as? String == Defaults.cleanupSystemPrompt)
        #expect(object["temperature"] == nil)

        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 1, "the system prompt is a top-level field, not a message")
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == raw)
    }

    @Test("Cleanup requests carry the right auth header per provider")
    func cleanupRequestHeadersPerProvider() throws {
        let groq = try LLMCleaner.buildRequest(
            provider: .groq, apiKey: "gsk-key", model: "m", raw: "hi", timeoutSeconds: 6
        )
        #expect(groq.url?.absoluteString == Defaults.groqChatURL)
        #expect(groq.httpMethod == "POST")
        #expect(groq.timeoutInterval == 6)
        #expect(groq.value(forHTTPHeaderField: "Authorization") == "Bearer gsk-key")
        #expect(groq.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(groq.value(forHTTPHeaderField: "x-api-key") == nil)

        let openai = try LLMCleaner.buildRequest(
            provider: .openai, apiKey: "sk-key", model: "m", raw: "hi", timeoutSeconds: 3
        )
        #expect(openai.url?.absoluteString == Defaults.openaiChatURL)
        #expect(openai.value(forHTTPHeaderField: "Authorization") == "Bearer sk-key")
        #expect(openai.timeoutInterval == 3)

        let anthropic = try LLMCleaner.buildRequest(
            provider: .anthropic, apiKey: "sk-ant-key", model: "m", raw: "hi", timeoutSeconds: 6
        )
        #expect(anthropic.url?.absoluteString == Defaults.anthropicMessagesURL)
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "sk-ant-key")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == Defaults.anthropicAPIVersion)
        #expect(anthropic.value(forHTTPHeaderField: "Authorization") == nil, "Anthropic uses x-api-key")
    }

    @Test("Cleanup request bodies match their provider's shape")
    func cleanupRequestBodyMatchesProviderShape() throws {
        let groq = try LLMCleaner.buildRequest(
            provider: .groq, apiKey: "k", model: "m", raw: "hi", timeoutSeconds: 6
        )
        let groqData = try #require(groq.httpBody)
        let groqBody = try #require(JSONSerialization.jsonObject(with: groqData) as? [String: Any])
        #expect(groqBody["temperature"] != nil)
        #expect(groqBody["max_tokens"] == nil)

        let anthropic = try LLMCleaner.buildRequest(
            provider: .anthropic, apiKey: "k", model: "m", raw: "hi", timeoutSeconds: 6
        )
        let anthropicData = try #require(anthropic.httpBody)
        let anthropicBody = try #require(JSONSerialization.jsonObject(with: anthropicData) as? [String: Any])
        #expect(anthropicBody["max_tokens"] != nil)
        #expect(anthropicBody["system"] != nil)
    }

    // MARK: - Response parsing

    @Test("A transcript is trimmed on the way out")
    func parseTranscriptTrimsText() throws {
        let data = Data(#"{"text":"  hello there \n"}"#.utf8)
        #expect(try CloudTranscriber.parseTranscript(data) == "hello there")
    }

    @Test("Unexpected transcription payloads throw .transcriptionFailed")
    func parseTranscriptRejectsUnexpectedPayloads() throws {
        for payload in [#"{"error":{"message":"bad key"}}"#, "not json at all", "{}"] {
            let thrown = #expect(throws: OWError.self) {
                try CloudTranscriber.parseTranscript(Data(payload.utf8))
            }
            guard case .transcriptionFailed(let message) = try #require(thrown) else {
                Issue.record("expected .transcriptionFailed for \(payload), got \(String(describing: thrown))")
                continue
            }
            #expect(message.hasPrefix("unexpected response:"), "\(message)")
        }
    }

    @Test("choices[0].message.content is what gets used")
    func parseChatResponse() throws {
        let data = Data(#"{"choices":[{"message":{"role":"assistant","content":" Hello there. "}}]}"#.utf8)
        #expect(try LLMCleaner.parseChatResponse(data) == "Hello there.")
    }

    @Test("Empty choices throw .cleanupFailed")
    func parseChatResponseRejectsEmptyChoices() throws {
        let thrown = #expect(throws: OWError.self) {
            try LLMCleaner.parseChatResponse(Data(#"{"choices":[]}"#.utf8))
        }
        guard case .cleanupFailed = try #require(thrown) else {
            Issue.record("expected .cleanupFailed, got \(String(describing: thrown))")
            return
        }
    }

    @Test("content[0].text is what gets used")
    func parseAnthropicResponse() throws {
        let data = Data(#"{"content":[{"type":"text","text":" Hello there. "}]}"#.utf8)
        #expect(try LLMCleaner.parseAnthropicResponse(data) == "Hello there.")
    }

    @Test("A leading non-text block is skipped")
    func parseAnthropicResponseSkipsNonTextBlocks() throws {
        let data = Data(#"{"content":[{"type":"thinking","thinking":"…"},{"type":"text","text":"Hello."}]}"#.utf8)
        #expect(try LLMCleaner.parseAnthropicResponse(data) == "Hello.")
    }

    @Test("Empty Anthropic content throws .cleanupFailed")
    func parseAnthropicResponseRejectsEmptyContent() throws {
        let thrown = #expect(throws: OWError.self) {
            try LLMCleaner.parseAnthropicResponse(Data(#"{"content":[]}"#.utf8))
        }
        guard case .cleanupFailed = try #require(thrown) else {
            Issue.record("expected .cleanupFailed, got \(String(describing: thrown))")
            return
        }
    }

    // MARK: - Error-message plumbing

    @Test("Body snippets are capped and single-line")
    func bodySnippetIsCappedAndSingleLine() {
        let long = Data(String(repeating: "x", count: 500).utf8)
        #expect(CloudHTTP.bodySnippet(long).count == 200)
        #expect(CloudHTTP.bodySnippet(long, limit: 10).count == 10)

        let multiline = Data("{\n\"error\": \"nope\"\n}".utf8)
        let snippet = CloudHTTP.bodySnippet(multiline)
        #expect(!snippet.contains("\n"))
        #expect(snippet.contains("\"error\": \"nope\""))
    }

    @Test("Transport errors get short, presentable reasons")
    func shortReasonForTransportErrors() {
        #expect(CloudHTTP.shortReason(URLError(.timedOut)) == "request timed out")
        #expect(CloudHTTP.shortReason(URLError(.notConnectedToInternet)) == "no internet connection")
        #expect(!CloudHTTP.shortReason(URLError(.badURL)).isEmpty)
    }

    @Test("Cancellation is recognised and never reported as a network failure")
    func cancellationIsRecognised() {
        #expect(CloudHTTP.isCancellation(CancellationError()))
        #expect(CloudHTTP.isCancellation(URLError(.cancelled)))
        #expect(!CloudHTTP.isCancellation(URLError(.timedOut)))
        #expect(!CloudHTTP.isCancellation(OWError.emptyRecording))
    }
}
