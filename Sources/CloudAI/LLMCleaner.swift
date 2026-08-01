import Foundation
import OpenWisperCore

/// Cleans a raw transcript with a small, fast chat model — Groq or OpenAI
/// (`chat/completions`) or Anthropic (`messages`), driven by
/// `Defaults.cleanupSystemPrompt`.
///
/// Everything here is best-effort by design: the caller wraps `clean` and falls
/// back to the raw transcript on any throw, so this type fails fast and loudly
/// rather than retrying or degrading silently.
public struct LLMCleaner: TranscriptCleaner {
    /// Always a concrete provider — never `.auto` (resolved in `make`).
    public let provider: CleanupProvider
    public let model: String
    public let timeoutSeconds: Double

    private let apiKey: String
    private let session: URLSession

    public var name: String { "\(provider.rawValue)-cleanup" }

    /// Order `.auto` probes providers in, per ARCHITECTURE.md and the
    /// `CleanupProvider` doc comment: groq → openai → anthropic.
    static let autoOrder: [CleanupProvider] = [.groq, .openai, .anthropic]

    public init(provider: CleanupProvider, apiKey: String, model: String, timeoutSeconds: Double) {
        self.init(
            provider: provider,
            apiKey: apiKey,
            model: model,
            timeoutSeconds: timeoutSeconds,
            session: .shared
        )
    }

    init(
        provider: CleanupProvider,
        apiKey: String,
        model: String,
        timeoutSeconds: Double,
        session: URLSession
    ) {
        precondition(
            provider != .auto,
            "LLMCleaner needs a concrete provider — use LLMCleaner.make(config:env:) to resolve .auto"
        )
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.session = session
    }

    // MARK: Selection (pure, unit-tested)

    /// Picks the provider to use and the key to use it with.
    ///
    /// - `.auto` → the first of groq → openai → anthropic that has a key.
    /// - an explicit provider → that provider, but only if its key is present.
    ///
    /// `nil` means "no cleaner": there is no key to work with. That is a normal
    /// offline configuration, not an error — the caller logs it and dictates
    /// with raw transcripts. Deliberately ignores `config.enabled` so callers
    /// can ask "could cleanup run?" independently; `make` applies `enabled`.
    public static func resolveProvider(
        _ config: CleanupConfig,
        env: Env
    ) -> (provider: CleanupProvider, apiKey: String)? {
        if config.provider == .auto {
            for candidate in autoOrder {
                if let key = apiKey(for: candidate, env: env) { return (candidate, key) }
            }
            return nil
        }
        guard let key = apiKey(for: config.provider, env: env) else { return nil }
        return (config.provider, key)
    }

    /// Builds a cleaner from config + environment, or `nil` when cleanup is
    /// switched off or no usable key exists. The caller treats `nil` as
    /// "skip cleanup" and keeps dictating.
    public static func make(config: CleanupConfig, env: Env) -> LLMCleaner? {
        guard config.enabled else {
            Log.llm.debug("cleanup disabled in config")
            return nil
        }
        guard let resolved = resolveProvider(config, env: env) else {
            Log.llm.debug("cleanup skipped: no API key for provider \(config.provider.rawValue, privacy: .public)")
            return nil
        }
        return LLMCleaner(
            provider: resolved.provider,
            apiKey: resolved.apiKey,
            model: model(for: resolved.provider, override: config.model),
            timeoutSeconds: config.timeoutSeconds
        )
    }

    /// `config.model` when set to something non-blank, else the provider default.
    static func model(for provider: CleanupProvider, override: String?) -> String {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        switch provider {
        case .groq, .auto: return Defaults.groqLLMModel
        case .openai: return Defaults.openaiLLMModel
        case .anthropic: return Defaults.anthropicLLMModel
        }
    }

    static func apiKey(for provider: CleanupProvider, env: Env) -> String? {
        switch provider {
        case .groq: return env.groqKey
        case .openai: return env.openaiKey
        case .anthropic: return env.anthropicKey
        case .auto: return nil
        }
    }

    // MARK: TranscriptCleaner

    public func clean(_ raw: String) async throws -> String {
        // Nothing to clean — skip the round trip entirely.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }

        let request = try Self.buildRequest(
            provider: provider,
            apiKey: apiKey,
            model: model,
            raw: raw,
            timeoutSeconds: timeoutSeconds
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
            throw OWError.cleanupFailed("no HTTP response")
        }
        guard CloudHTTP.okStatusCodes.contains(http.statusCode) else {
            Log.llm.error("cleanup HTTP \(http.statusCode, privacy: .public) from \(self.name, privacy: .public)")
            throw OWError.cleanupFailed("HTTP \(http.statusCode): \(CloudHTTP.bodySnippet(data))")
        }

        let cleaned = provider == .anthropic
            ? try Self.parseAnthropicResponse(data)
            : try Self.parseChatResponse(data)
        guard !cleaned.isEmpty else { throw OWError.cleanupFailed("empty response") }
        return cleaned
    }

    // MARK: Request building (pure, unit-tested)

    static func endpoint(for provider: CleanupProvider) -> String {
        switch provider {
        case .groq, .auto: return Defaults.groqChatURL
        case .openai: return Defaults.openaiChatURL
        case .anthropic: return Defaults.anthropicMessagesURL
        }
    }

    static func buildRequest(
        provider: CleanupProvider,
        apiKey: String,
        model: String,
        raw: String,
        timeoutSeconds: Double
    ) throws -> URLRequest {
        let endpoint = endpoint(for: provider)
        guard let url = URL(string: endpoint) else {
            throw OWError.cleanupFailed("invalid endpoint URL \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // NOTE: URLSession treats this as an inactivity timeout, not a wall
        // clock deadline. Fine for these tiny single-shot responses; the caller
        // still owns the fallback if it somehow overruns.
        request.timeoutInterval = timeoutSeconds
        request.setValue(CloudHTTP.jsonContentType, forHTTPHeaderField: "Content-Type")

        switch provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Defaults.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
            request.httpBody = try anthropicBody(model: model, raw: raw)
        case .groq, .openai, .auto:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try chatBody(model: model, raw: raw)
        }
        return request
    }

    /// OpenAI-compatible `chat/completions` payload.
    static func chatBody(model: String, raw: String) throws -> Data {
        let body = ChatCompletionsRequest(
            model: model,
            temperature: 0,
            messages: [
                ChatMessage(role: "system", content: Defaults.cleanupSystemPrompt),
                ChatMessage(role: "user", content: raw),
            ]
        )
        do {
            return try CloudHTTP.encodeJSON(body)
        } catch {
            throw OWError.cleanupFailed("could not encode request")
        }
    }

    /// Anthropic `messages` payload — system prompt is a top-level field there.
    static func anthropicBody(model: String, raw: String) throws -> Data {
        let body = AnthropicMessagesRequest(
            model: model,
            maxTokens: 4096,
            system: Defaults.cleanupSystemPrompt,
            messages: [ChatMessage(role: "user", content: raw)]
        )
        do {
            return try CloudHTTP.encodeJSON(body)
        } catch {
            throw OWError.cleanupFailed("could not encode request")
        }
    }

    // MARK: Response parsing (pure, unit-tested)

    /// `choices[0].message.content`
    static func parseChatResponse(_ data: Data) throws -> String {
        guard let payload = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data),
              let content = payload.choices?.first?.message?.content
        else {
            throw OWError.cleanupFailed("unexpected response: \(CloudHTTP.bodySnippet(data))")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `content[0].text`, tolerating a leading non-text block (e.g. thinking).
    static func parseAnthropicResponse(_ data: Data) throws -> String {
        guard let payload = try? JSONDecoder().decode(AnthropicMessagesResponse.self, from: data),
              let blocks = payload.content, !blocks.isEmpty
        else {
            throw OWError.cleanupFailed("unexpected response: \(CloudHTTP.bodySnippet(data))")
        }
        let textBlock = blocks.first { $0.type == "text" && $0.text != nil } ?? blocks[0]
        guard let text = textBlock.text else {
            throw OWError.cleanupFailed("unexpected response: \(CloudHTTP.bodySnippet(data))")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire types

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let temperature: Int
    let messages: [ChatMessage]
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }
    let choices: [Choice]?
}

private struct AnthropicMessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String?
        let text: String?
    }
    let content: [Block]?
}
