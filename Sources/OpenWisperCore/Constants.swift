import Foundation

/// Central defaults. Config/env can override the overridable ones.
public enum Defaults {
    public static let appName = "OpenWisper"
    public static let bundleID = "com.openwisper.app"
    public static let version = "0.1.0"

    /// Whisper wants 16 kHz mono Float32.
    public static let sampleRate = 16000

    /// Model file used when `transcription.modelPath` is not set.
    public static let defaultModelFile = "ggml-small.en.bin"

    /// Where the in-app downloader fetches `defaultModelFile` from — the same
    /// canonical whisper.cpp repository `scripts/download_model.sh` uses.
    public static let defaultModelURL =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(defaultModelFile)"

    /// Approximate size of `defaultModelFile`, for the download button's label
    /// and as a floor under what counts as a complete download (an HTML error
    /// page is never hundreds of megabytes).
    public static let defaultModelApproxBytes: Int64 = 488_000_000

    /// Local transcript history, next to config.json (see `AppPaths.historyURL`).
    public static let historyFile = "history.json"

    // --- Speech-to-text (cloud) ---
    public static let groqSTTURL = "https://api.groq.com/openai/v1/audio/transcriptions"
    public static let openaiSTTURL = "https://api.openai.com/v1/audio/transcriptions"
    public static let groqSTTModel = "whisper-large-v3-turbo"
    public static let openaiSTTModel = "whisper-1"
    public static let sttTimeoutSeconds: Double = 30

    // --- Transcript cleanup (LLM) ---
    public static let groqChatURL = "https://api.groq.com/openai/v1/chat/completions"
    public static let openaiChatURL = "https://api.openai.com/v1/chat/completions"
    public static let anthropicMessagesURL = "https://api.anthropic.com/v1/messages"
    public static let anthropicAPIVersion = "2023-06-01"
    public static let groqLLMModel = "llama-3.1-8b-instant"
    public static let openaiLLMModel = "gpt-4o-mini"
    public static let anthropicLLMModel = "claude-haiku-4-5-20251001"

    /// Short, strict prompt per product requirement: fillers out, punctuation
    /// fixed, casing matched to dictation — never rephrase or invent content.
    public static let cleanupSystemPrompt = """
    You clean up raw speech-to-text transcripts of dictation.
    Rules:
    - Remove filler words and verbal tics (um, uh, er, like, you know, I mean, sort of) unless clearly intentional content.
    - Remove false starts, stutters, and immediately repeated words; keep the phrasing the speaker settled on.
    - Fix punctuation, capitalization, and sentence boundaries so it reads as natural written text.
    - Convert the spoken commands "new line" and "new paragraph" into actual line breaks.
    - Fix obvious transcription errors only when confident from context.
    - Never add, drop, or rephrase content beyond these rules. Preserve the speaker's language.
    Output ONLY the cleaned text — no commentary, no surrounding quotes.
    """
}
