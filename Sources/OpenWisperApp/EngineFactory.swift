import CloudAI
import Foundation
import OpenWisperCore
import WhisperLocal

/// The transcription engine currently in force, plus everything the app needs to
/// describe it in the menu bar and to tear it down again.
struct EngineSelection {
    /// What `transcription.engine` asked for — may be `.auto`.
    let requested: EngineKind
    /// What that actually resolved to. Never `.auto`.
    let resolved: EngineKind
    let transcriber: Transcriber
    /// Non-nil exactly when `transcriber` is the local engine, so the app can
    /// `preload()` the resident model at launch and `unload()` it on an engine
    /// switch or at terminate.
    let local: LocalWhisperTranscriber?
    /// Menu-bar summary: `"Local · ggml-small.en"`, `"Groq · whisper-large-v3-turbo"`,
    /// `"Auto → Local · ggml-tiny.en"`.
    let detail: String
    /// User-facing configuration problems found while resolving — a missing
    /// model file, or a cloud engine selected without its API key. Surfaced once
    /// per session in an alert; never fatal.
    let warnings: [String]
}

/// Resolves `transcription.engine` + `.env` into a concrete `Transcriber`.
///
/// The rules (ARCHITECTURE.md → "Engine & cleanup selection"):
///
/// - `.local` → whisper.cpp at `resolvedModelURL()`. A missing model file is
///   *not* fatal here: the transcriber is still built so the per-utterance error
///   pill can say "run `make model`", and the same message is surfaced once in
///   an alert at startup.
/// - `.groq` / `.openai` → the matching cloud endpoint, using the key from the
///   environment. **Without that key** the choice is a config error: it is
///   reported, and resolution falls through the `.auto` chain so dictation keeps
///   working.
/// - `.auto` → local if the model file exists, else Groq if `GROQ_API_KEY`, else
///   OpenAI if `OPENAI_API_KEY`, else local (the missing-model error path — it is
///   the only outcome the user can fix with a single command).
enum EngineFactory {

    /// - Parameter existingLocal: the local transcriber currently in use, if any.
    ///   When the new selection is local with the same model file and language it
    ///   is reused, so re-resolving (menu switch, "Reload Config") never drops a
    ///   resident model just to load the identical one again.
    static func make(
        config: AppConfig,
        env: Env,
        reusing existingLocal: LocalWhisperTranscriber? = nil
    ) -> EngineSelection {
        let requested = config.transcription.engine

        switch requested {
        case .local:
            return makeLocal(config: config, requested: .local, reusing: existingLocal, warnings: [])

        case .groq, .openai:
            if let key = apiKey(for: requested, env: env) {
                return makeCloud(
                    kind: requested, apiKey: key, config: config,
                    requested: requested, warnings: []
                )
            }
            return makeAuto(
                config: config, env: env, requested: requested, reusing: existingLocal,
                warnings: [missingKeyWarning(for: requested)]
            )

        case .auto:
            return makeAuto(
                config: config, env: env, requested: .auto,
                reusing: existingLocal, warnings: []
            )
        }
    }

    // MARK: Resolution

    private static func makeAuto(
        config: AppConfig,
        env: Env,
        requested: EngineKind,
        reusing existingLocal: LocalWhisperTranscriber?,
        warnings: [String]
    ) -> EngineSelection {
        if FileManager.default.fileExists(atPath: config.transcription.resolvedModelURL().path) {
            return makeLocal(
                config: config, requested: requested,
                reusing: existingLocal, warnings: warnings
            )
        }
        if let key = env.groqKey {
            return makeCloud(
                kind: .groq, apiKey: key, config: config,
                requested: requested, warnings: warnings
            )
        }
        if let key = env.openaiKey {
            return makeCloud(
                kind: .openai, apiKey: key, config: config,
                requested: requested, warnings: warnings
            )
        }
        // Nothing at all is configured. Local is still the right answer: it is
        // the one the user can fix offline, and `makeLocal` adds the
        // "run make model" warning below.
        return makeLocal(config: config, requested: requested, reusing: existingLocal, warnings: warnings)
    }

    private static func makeLocal(
        config: AppConfig,
        requested: EngineKind,
        reusing existingLocal: LocalWhisperTranscriber?,
        warnings: [String]
    ) -> EngineSelection {
        let modelURL = config.transcription.resolvedModelURL()
        let language = config.transcription.language

        let transcriber: LocalWhisperTranscriber
        if let existingLocal, existingLocal.modelURL == modelURL, existingLocal.language == language {
            transcriber = existingLocal
        } else {
            transcriber = LocalWhisperTranscriber(modelURL: modelURL, language: language)
        }

        var warnings = warnings
        if !transcriber.isModelAvailable {
            warnings.append(missingModelWarning(modelURL))
        }

        return EngineSelection(
            requested: requested,
            resolved: .local,
            transcriber: transcriber,
            local: transcriber,
            detail: detail(
                requested: requested,
                resolved: .local,
                label: "\(displayName(.local)) · \(modelURL.deletingPathExtension().lastPathComponent)"
            ),
            warnings: warnings
        )
    }

    private static func makeCloud(
        kind: EngineKind,
        apiKey: String,
        config: AppConfig,
        requested: EngineKind,
        warnings: [String]
    ) -> EngineSelection {
        let model = kind == .groq ? config.transcription.groqModel : config.transcription.openaiModel
        let transcriber = CloudTranscriber(
            kind: kind,
            apiKey: apiKey,
            model: model,
            language: config.transcription.language
        )
        return EngineSelection(
            requested: requested,
            resolved: kind,
            transcriber: transcriber,
            local: nil,
            detail: detail(
                requested: requested,
                resolved: kind,
                label: "\(displayName(kind)) · \(model)"
            ),
            warnings: warnings
        )
    }

    // MARK: Labels

    /// `"Local · ggml-small.en"` when we got what was asked for, otherwise it
    /// also says where the answer came from: `"Auto → Groq · whisper-large-v3-turbo"`,
    /// `"Groq unavailable → Local · ggml-small.en"`.
    private static func detail(requested: EngineKind, resolved: EngineKind, label: String) -> String {
        if requested == resolved { return label }
        if requested == .auto { return "Auto → \(label)" }
        return "\(displayName(requested)) unavailable → \(label)"
    }

    private static func displayName(_ kind: EngineKind) -> String {
        switch kind {
        case .auto: return "Auto"
        case .local: return "Local"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    // MARK: Keys / warnings

    static func apiKey(for kind: EngineKind, env: Env) -> String? {
        switch kind {
        case .groq: return env.groqKey
        case .openai: return env.openaiKey
        case .local, .auto: return nil
        }
    }

    private static func missingModelWarning(_ url: URL) -> String {
        """
        No whisper model at:
        \(url.path)

        Run `make model` in the OpenWisper repo to download the default model, or point \
        "transcription": { "modelPath": … } in config.json at one you already have. \
        Until then every local dictation ends in an error.
        """
    }

    private static func missingKeyWarning(for kind: EngineKind) -> String {
        let variable = kind == .groq ? "GROQ_API_KEY" : "OPENAI_API_KEY"
        return """
        transcription.engine is "\(kind.rawValue)", but \(variable) is not set.

        Add it to \(AppPaths.envURL.path) and pick the engine again from the menu. \
        OpenWisper has fallen back to the next engine that is actually available.
        """
    }
}
