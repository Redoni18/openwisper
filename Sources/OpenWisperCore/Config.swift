import Foundation

// Tolerant decoding helper: any missing or malformed key falls back to the
// built-in default, so hand-edited config files degrade gracefully.
extension KeyedDecodingContainer {
    func ow<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
    func owOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

public struct HotkeyConfig: Codable {
    /// Single named key: "fn", "rightCommand", "leftCommand", "rightOption", "leftOption",
    /// "leftControl", "rightControl", "f13"..."f19", or "keycode:NN" for a raw CGKeyCode.
    /// Ignored when `keys` supplies at least one key — see `effectiveKeys`.
    public var key: String
    /// Several keys, any of which triggers dictation. Same vocabulary as `key`.
    /// The point is mixed-keyboard setups: external (non-Apple) keyboards handle
    /// `fn` in firmware and never report it to macOS, so `["fn", "rightCommand"]`
    /// keeps the built-in keyboard on `fn` while giving the external one a key
    /// that actually arrives. nil (the default) means "just `key`".
    public var keys: [String]?
    /// How the hotkey drives dictation. Unknown values fall back to "flow".
    /// - "flow" (default): hold to talk, or double-tap to lock hands-free until
    ///   the next tap stops it.
    /// - "hold": pure push-to-talk — records only while the key is held.
    /// - "toggle": tap to start, tap again to stop.
    public var mode: String
    /// The tap-vs-hold threshold. In "hold" mode a press shorter than this is
    /// discarded as an accidental tap; in "flow" mode it is what makes a press a
    /// *tap*, opening the `doubleTapWindowMs` window instead of ending the
    /// utterance.
    public var minHoldMs: Int
    /// "flow" mode only: how long after a tap a second press still counts as a
    /// double-tap and locks the session hands-free. 0 disables the lock.
    public var doubleTapWindowMs: Int

    public init(
        key: String = "fn",
        keys: [String]? = nil,
        mode: String = "flow",
        minHoldMs: Int = 250,
        doubleTapWindowMs: Int = 300
    ) {
        self.key = key
        self.keys = keys
        self.mode = mode
        self.minHoldMs = minHoldMs
        self.doubleTapWindowMs = doubleTapWindowMs
    }

    /// The keys actually bound: `keys` when it carries anything usable, else the
    /// single `key`. Blank and whitespace-only entries are dropped, so a list
    /// that is empty (or all blanks) falls back to `key` rather than to nothing.
    /// Never empty.
    public var effectiveKeys: [String] {
        if let keys = keys {
            let cleaned = keys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty { return cleaned }
        }
        return [key]
    }

    enum CodingKeys: String, CodingKey { case key, keys, mode, minHoldMs, doubleTapWindowMs }
    public init(from decoder: Decoder) throws {
        let d = HotkeyConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            key: c.ow(.key, d.key),
            keys: c.owOptional(.keys),
            mode: c.ow(.mode, d.mode),
            minHoldMs: c.ow(.minHoldMs, d.minHoldMs),
            doubleTapWindowMs: c.ow(.doubleTapWindowMs, d.doubleTapWindowMs)
        )
    }
}

public struct TranscriptionConfig: Codable {
    public var engine: EngineKind
    /// Absolute or ~-relative path to a ggml model. nil → App Support/models/ggml-small.en.bin.
    public var modelPath: String?
    /// ISO 639-1 code, or "auto" to let whisper detect.
    public var language: String
    public var groqModel: String
    public var openaiModel: String
    /// Hard cap on a single utterance; audio past this is dropped.
    public var maxSeconds: Int

    public init(
        engine: EngineKind = .local,
        modelPath: String? = nil,
        language: String = "en",
        groqModel: String = Defaults.groqSTTModel,
        openaiModel: String = Defaults.openaiSTTModel,
        maxSeconds: Int = 600
    ) {
        self.engine = engine
        self.modelPath = modelPath
        self.language = language
        self.groqModel = groqModel
        self.openaiModel = openaiModel
        self.maxSeconds = maxSeconds
    }

    enum CodingKeys: String, CodingKey {
        case engine, modelPath, language, groqModel, openaiModel, maxSeconds
    }
    public init(from decoder: Decoder) throws {
        let d = TranscriptionConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            engine: c.ow(.engine, d.engine),
            modelPath: c.owOptional(.modelPath),
            language: c.ow(.language, d.language),
            groqModel: c.ow(.groqModel, d.groqModel),
            openaiModel: c.ow(.openaiModel, d.openaiModel),
            maxSeconds: c.ow(.maxSeconds, d.maxSeconds)
        )
    }

    public func resolvedModelURL() -> URL {
        if let p = modelPath, !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        let preferred = AppPaths.modelsDir.appendingPathComponent(Defaults.defaultModelFile)
        let fm = FileManager.default
        if fm.fileExists(atPath: preferred.path) { return preferred }
        // No explicit path and the default model isn't there: fall back to any
        // downloaded ggml model (largest first) so `make model SIZE=medium.en`
        // works without also editing config.json.
        if let entries = try? fm.contentsOfDirectory(
            at: AppPaths.modelsDir, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            let candidates = entries
                .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
                .sorted { lhs, rhs in
                    let l = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let r = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return l > r
                }
            if let best = candidates.first { return best }
        }
        return preferred
    }
}

public struct CleanupConfig: Codable {
    public var enabled: Bool
    public var provider: CleanupProvider
    /// nil → provider's default model (see Defaults).
    public var model: String?
    /// On timeout or any failure the raw transcript is used instead.
    public var timeoutSeconds: Double

    public init(
        enabled: Bool = true,
        provider: CleanupProvider = .auto,
        model: String? = nil,
        timeoutSeconds: Double = 6.0
    ) {
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey { case enabled, provider, model, timeoutSeconds }
    public init(from decoder: Decoder) throws {
        let d = CleanupConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            enabled: c.ow(.enabled, d.enabled),
            provider: c.ow(.provider, d.provider),
            model: c.owOptional(.model),
            timeoutSeconds: c.ow(.timeoutSeconds, d.timeoutSeconds)
        )
    }
}

public struct InsertConfig: Codable {
    public var mode: InsertMode
    /// How long after Cmd-V before the previous clipboard is restored.
    /// Only relevant when `copyToClipboard` is false.
    public var restoreClipboardDelayMs: Int
    /// When true (default), the transcript stays on the clipboard after
    /// insertion — a safety net for when the paste landed nowhere (no text
    /// field focused): just ⌘V it yourself. When false, the previous clipboard
    /// contents are restored after `restoreClipboardDelayMs` (the original
    /// snapshot-and-restore behavior).
    public var copyToClipboard: Bool

    public init(
        mode: InsertMode = .paste,
        restoreClipboardDelayMs: Int = 600,
        copyToClipboard: Bool = true
    ) {
        self.mode = mode
        self.restoreClipboardDelayMs = restoreClipboardDelayMs
        self.copyToClipboard = copyToClipboard
    }

    enum CodingKeys: String, CodingKey { case mode, restoreClipboardDelayMs, copyToClipboard }
    public init(from decoder: Decoder) throws {
        let d = InsertConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            mode: c.ow(.mode, d.mode),
            restoreClipboardDelayMs: c.ow(.restoreClipboardDelayMs, d.restoreClipboardDelayMs),
            copyToClipboard: c.ow(.copyToClipboard, d.copyToClipboard)
        )
    }
}

public struct UIConfig: Codable {
    public var showPill: Bool
    public var playSounds: Bool
    /// Dock the pill into the MacBook's notch when the display under the
    /// pointer has one, growing out of the cutout instead of floating at the
    /// bottom of the screen. Displays without a notch always use the floating
    /// pill, whatever this is set to.
    public var useNotch: Bool

    public init(showPill: Bool = true, playSounds: Bool = false, useNotch: Bool = true) {
        self.showPill = showPill
        self.playSounds = playSounds
        self.useNotch = useNotch
    }

    enum CodingKeys: String, CodingKey { case showPill, playSounds, useNotch }
    public init(from decoder: Decoder) throws {
        let d = UIConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            showPill: c.ow(.showPill, d.showPill),
            playSounds: c.ow(.playSounds, d.playSounds),
            useNotch: c.ow(.useNotch, d.useNotch)
        )
    }
}

public struct HistoryConfig: Codable {
    /// Keep a local record of every inserted transcript. On by default: the
    /// History page is where a paste that landed nowhere gets recovered from.
    /// Turning it off stops new entries — it does not delete the old ones
    /// (that is "Clear All" in the window).
    public var enabled: Bool
    /// How many transcripts to keep before the oldest are dropped.
    /// `TranscriptHistoryStore` clamps this to 1…10000.
    public var maxEntries: Int

    public init(enabled: Bool = true, maxEntries: Int = 200) {
        self.enabled = enabled
        self.maxEntries = maxEntries
    }

    enum CodingKeys: String, CodingKey { case enabled, maxEntries }
    public init(from decoder: Decoder) throws {
        let d = HistoryConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            enabled: c.ow(.enabled, d.enabled),
            maxEntries: c.ow(.maxEntries, d.maxEntries)
        )
    }
}

public struct AppConfig: Codable {
    public var hotkey: HotkeyConfig
    public var transcription: TranscriptionConfig
    public var cleanup: CleanupConfig
    public var insert: InsertConfig
    public var ui: UIConfig
    public var history: HistoryConfig

    public init(
        hotkey: HotkeyConfig = HotkeyConfig(),
        transcription: TranscriptionConfig = TranscriptionConfig(),
        cleanup: CleanupConfig = CleanupConfig(),
        insert: InsertConfig = InsertConfig(),
        ui: UIConfig = UIConfig(),
        history: HistoryConfig = HistoryConfig()
    ) {
        self.hotkey = hotkey
        self.transcription = transcription
        self.cleanup = cleanup
        self.insert = insert
        self.ui = ui
        self.history = history
    }

    enum CodingKeys: String, CodingKey { case hotkey, transcription, cleanup, insert, ui, history }
    public init(from decoder: Decoder) throws {
        let d = AppConfig()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = d; return }
        self.init(
            hotkey: c.ow(.hotkey, d.hotkey),
            transcription: c.ow(.transcription, d.transcription),
            cleanup: c.ow(.cleanup, d.cleanup),
            insert: c.ow(.insert, d.insert),
            ui: c.ow(.ui, d.ui),
            history: c.ow(.history, d.history)
        )
    }

    /// Loads the config, writing a fresh default file on first run or parse failure.
    public static func loadOrCreate(at url: URL = AppPaths.configURL) -> AppConfig {
        AppPaths.ensureDirectories()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let cfg = AppConfig()
            try? cfg.save(to: url)
            return cfg
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            Log.app.error("Failed to parse config at \(url.path): \(String(describing: error)) — using defaults")
            return AppConfig()
        }
    }

    public func save(to url: URL = AppPaths.configURL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
