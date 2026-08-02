// MainWindowActions — the seam between the app window and the running app.
//
// Same rule as MenuBarUI: this module knows nothing about DictationController,
// the engine factory, the cleaner or the env beyond OpenWisperCore's value
// types. Everything it can read or change goes through the closures below,
// which the app supplies at launch. That keeps the window buildable and
// snapshot-renderable on its own (see the `window-demo` executable), and keeps
// every piece of mutable app state owned by exactly one place — AppDelegate.
import Foundation
import OpenWisperCore

// MARK: - Pages

/// The window's three pages, in sidebar order.
public enum MainWindowPage: String, CaseIterable, Identifiable, Hashable {
    case history
    case model
    case permissions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .history: return "History"
        case .model: return "Model"
        case .permissions: return "Permissions"
        }
    }

    /// Sidebar glyph.
    public var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .model: return "waveform"
        case .permissions: return "lock.shield"
        }
    }

    /// One line under the page title, so each page says what it is for.
    public var subtitle: String {
        switch self {
        case .history: return "Everything OpenWisper has typed for you, newest first."
        case .model: return "How your speech is turned into text, and what it needs."
        case .permissions: return "The macOS approvals OpenWisper needs to work."
        }
    }
}

// MARK: - Injected state

/// The local whisper model as it exists on disk right now.
public struct LocalModelInfo: Equatable {
    /// File name of the model that *would* be loaded — the resolved path's last
    /// component, whether or not the file is actually there.
    public var fileName: String
    /// Size on disk. `nil` means the file does not exist, which is the state
    /// the "run `make model`" hint is for.
    public var byteSize: Int64?

    public var isAvailable: Bool { byteSize != nil }

    public init(fileName: String, byteSize: Int64? = nil) {
        self.fileName = fileName
        self.byteSize = byteSize
    }

    /// `"470 MB"`, or nil when there is no file to measure.
    public var formattedSize: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// The three providers a key can be saved for. Raw values match `EngineKind`
/// where the two overlap, so the engine cards can open the matching key field.
public enum APIKeyKind: String, CaseIterable, Identifiable {
    case groq
    case openai
    case anthropic

    public var id: String { rawValue }
}

/// One step of an in-app model download, delivered on the main thread.
/// `fraction` is nil when the server did not say how big the file is.
public enum ModelDownloadEvent: Equatable {
    case progress(fraction: Double?, receivedBytes: Int64)
    case finished
    case cancelled
    case failed(message: String)
}

/// Which API keys the app found — **presence only**. Key values never leave
/// `Env`, are never rendered, and are never logged.
public struct APIKeyPresence: Equatable {
    public var groq: Bool
    public var openai: Bool
    public var anthropic: Bool

    public init(groq: Bool = false, openai: Bool = false, anthropic: Bool = false) {
        self.groq = groq
        self.openai = openai
        self.anthropic = anthropic
    }
}

/// The three TCC permissions OpenWisper needs.
public enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case inputMonitoring
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    /// Kept word-for-word in sync with `PermissionRow.reason` in MenuBarUI, so
    /// the menu tooltip and the window say the same thing.
    public var reason: String {
        switch self {
        case .microphone: return "Needed to record your voice."
        case .inputMonitoring: return "Needed for the dictation hotkey."
        case .accessibility: return "Needed to paste what you said into the app you're using."
        }
    }

    public var symbol: String {
        switch self {
        case .microphone: return "mic"
        case .inputMonitoring: return "keyboard"
        case .accessibility: return "hand.tap"
        }
    }
}

/// A reading of all three permissions, taken together so the page never shows a
/// mix of old and new state.
public struct PermissionsSnapshot: Equatable {
    public var microphone: PermissionStatus
    public var inputMonitoring: PermissionStatus
    public var accessibility: PermissionStatus

    public init(
        microphone: PermissionStatus = .undetermined,
        inputMonitoring: PermissionStatus = .undetermined,
        accessibility: PermissionStatus = .undetermined
    ) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }

    public func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone: return microphone
        case .inputMonitoring: return inputMonitoring
        case .accessibility: return accessibility
        }
    }

    public var allGranted: Bool {
        microphone == .granted && inputMonitoring == .granted && accessibility == .granted
    }
}

// MARK: - Actions

/// Everything the app window can observe or change in the running app.
///
/// The getters are polled by `MainWindowModel.refresh()` — on every window
/// activation, after any action that could change what they return, and on a
/// slow timer while the Permissions page is visible. Nothing pushes state into
/// the window.
///
/// All closures are invoked on the main thread.
public struct MainWindowActions {

    // --- Engine ---

    /// The engine currently selected in config (may be `.auto`).
    public var currentEngine: () -> EngineKind
    /// Persist and apply a new engine choice. Same path the menu bar uses.
    public var setEngine: (EngineKind) -> Void
    /// What `currentEngine` actually resolved to, e.g. `"Local · ggml-small.en"`.
    public var engineDetail: () -> String
    /// The local model file the current config points at.
    public var localModel: () -> LocalModelInfo
    /// Which API keys exist — booleans only, never the values.
    public var apiKeys: () -> APIKeyPresence
    /// Save (or, with nil, remove) a provider's API key. The value flows one
    /// way — window → app — and is never readable back through this seam.
    public var setAPIKey: (APIKeyKind, String?) -> Void

    // --- Model download ---

    /// Start downloading the recommended local model, reporting every step to
    /// the handler (on the main thread). A download already in flight is left
    /// alone. The app re-resolves its engine itself on `.finished`.
    public var downloadModel: (@escaping (ModelDownloadEvent) -> Void) -> Void
    /// Cancel an in-flight model download; the handler receives `.cancelled`.
    public var cancelModelDownload: () -> Void

    // --- Cleanup ---

    public var isCleanupEnabled: () -> Bool
    /// Persist `cleanup.enabled` and rebuild the cleaner immediately.
    public var setCleanupEnabled: (Bool) -> Void
    /// One line describing the provider `.auto` (or an explicit choice) resolved
    /// to, e.g. `"Groq · llama-3.1-8b-instant"` or `"No API key — cleanup is
    /// skipped"`. Composed by the app because provider resolution lives in
    /// CloudAI, which this module deliberately does not depend on.
    public var cleanupDetail: () -> String

    // --- History ---

    public var isHistoryEnabled: () -> Bool
    /// Persist `history.enabled` and apply it to the live store.
    public var setHistoryEnabled: (Bool) -> Void

    // --- Permissions ---

    public var permissions: () -> PermissionsSnapshot
    /// Request through the TCC API and then open the matching System Settings
    /// pane — the same request-then-open the menu bar does, because neither
    /// Input Monitoring nor Accessibility is ever granted by the prompt alone.
    public var requestPermission: (PermissionKind) -> Void

    // --- Files ---

    public var openConfigFile: () -> Void
    public var openAppSupportFolder: () -> Void
    public var openModelsFolder: () -> Void
    public var reloadConfig: () -> Void

    public init(
        currentEngine: @escaping () -> EngineKind,
        setEngine: @escaping (EngineKind) -> Void,
        engineDetail: @escaping () -> String,
        localModel: @escaping () -> LocalModelInfo,
        apiKeys: @escaping () -> APIKeyPresence,
        setAPIKey: @escaping (APIKeyKind, String?) -> Void,
        downloadModel: @escaping (@escaping (ModelDownloadEvent) -> Void) -> Void,
        cancelModelDownload: @escaping () -> Void,
        isCleanupEnabled: @escaping () -> Bool,
        setCleanupEnabled: @escaping (Bool) -> Void,
        cleanupDetail: @escaping () -> String,
        isHistoryEnabled: @escaping () -> Bool,
        setHistoryEnabled: @escaping (Bool) -> Void,
        permissions: @escaping () -> PermissionsSnapshot,
        requestPermission: @escaping (PermissionKind) -> Void,
        openConfigFile: @escaping () -> Void,
        openAppSupportFolder: @escaping () -> Void,
        openModelsFolder: @escaping () -> Void,
        reloadConfig: @escaping () -> Void
    ) {
        self.currentEngine = currentEngine
        self.setEngine = setEngine
        self.engineDetail = engineDetail
        self.localModel = localModel
        self.apiKeys = apiKeys
        self.setAPIKey = setAPIKey
        self.downloadModel = downloadModel
        self.cancelModelDownload = cancelModelDownload
        self.isCleanupEnabled = isCleanupEnabled
        self.setCleanupEnabled = setCleanupEnabled
        self.cleanupDetail = cleanupDetail
        self.isHistoryEnabled = isHistoryEnabled
        self.setHistoryEnabled = setHistoryEnabled
        self.permissions = permissions
        self.requestPermission = requestPermission
        self.openConfigFile = openConfigFile
        self.openAppSupportFolder = openAppSupportFolder
        self.openModelsFolder = openModelsFolder
        self.reloadConfig = reloadConfig
    }
}
