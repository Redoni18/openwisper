import Foundation

/// Which speech-to-text engine to use.
/// `.auto`: local if the model file exists, else Groq if key present, else OpenAI if key present.
public enum EngineKind: String, Codable, CaseIterable {
    case auto, local, groq, openai
}

/// How the final text is inserted into the focused app.
public enum InsertMode: String, Codable, CaseIterable {
    case paste   // pasteboard + synthetic Cmd-V, previous clipboard restored afterwards
    case type    // synthetic unicode keystrokes (slower; no clipboard touch)
}

/// Which LLM provider cleans up the raw transcript.
/// `.auto`: first provider with a key, in order groq → openai → anthropic.
public enum CleanupProvider: String, Codable, CaseIterable {
    case auto, groq, openai, anthropic
}

/// A finished mono recording, always 16 kHz Float32 PCM (whisper's native input).
public struct AudioClip {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int = Defaults.sampleRate) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}

/// Unified error domain. User-facing strings live in `errorDescription`.
public enum OWError: Error, LocalizedError, Equatable {
    case micPermissionDenied
    case accessibilityNotGranted
    case inputMonitoringNotGranted
    case modelNotFound(String)
    case apiKeyMissing(String)
    case emptyRecording
    case transcriptionFailed(String)
    case cleanupFailed(String)
    case insertionFailed(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "Microphone access is not granted."
        case .accessibilityNotGranted:
            return "Accessibility permission missing (needed to paste)."
        case .inputMonitoringNotGranted:
            return "Input Monitoring permission missing (needed for the hotkey)."
        case .modelNotFound(let path):
            return "Whisper model not found at \(path). Run `make model`."
        case .apiKeyMissing(let key):
            return "Missing API key \(key) — add it to your .env."
        case .emptyRecording:
            return "Recording was empty or too short."
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        case .cleanupFailed(let msg):
            return "Cleanup failed: \(msg)"
        case .insertionFailed(let msg):
            return "Could not insert text: \(msg)"
        case .network(let msg):
            return "Network error: \(msg)"
        }
    }
}
