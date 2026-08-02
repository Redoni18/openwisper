import AppKit
import CloudAI
import Foundation
import InsertIO
import MainWindowUI
import MenuBarUI
import OpenWisperCore
import PillUI
import Spine
import WhisperLocal

/// The root of the object graph: builds every component from `config.json` +
/// `.env`, wires them together, and keeps them alive.
///
/// Two weak references make ownership load-bearing rather than incidental:
/// `NSApplication.delegate` is weak (so `main.swift`'s top-level binding holds
/// *this*), and `HotkeyListener.delegate` is weak (so `controller` below is the
/// only strong reference to the state machine). Nothing here may be a `let`
/// either — engine, hotkey and even the controller are rebuilt at runtime when
/// the user changes the config or the engine.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// How long a controller replaced by a config reload is kept alive. Its
    /// in-flight utterance holds it only weakly, so dropping it immediately
    /// would throw away words that were already spoken and transcribed.
    private static let retiredControllerGrace: TimeInterval = 45

    // MARK: Configuration

    private var config = AppConfig()
    private var env = Env(values: [:])

    /// `OPENWISPER_SKIP_ONBOARDING=1` suppresses every startup alert (onboarding
    /// *and* engine warnings). Used by the launch tests and CI, where a modal
    /// alert would wedge an unattended run.
    private var suppressStartupUI = false

    // MARK: Components

    private var recorder: Recorder?
    private var inserter: TextInserter?
    private var indicator: RecordingIndicator?
    private var controller: DictationController?
    private var listener: HotkeyListener?
    private var statusBar: StatusBarController?
    private var engine: EngineSelection?

    /// Local transcript history. Built eagerly — before any config is read —
    /// because `buildController()` must always have something to wrap the
    /// inserter in; `applyHistoryConfig()` then pushes `config.history` into it
    /// at launch and on every reload.
    private let history = TranscriptHistoryStore()

    /// The app window. Built on first use: most sessions never open it, and it
    /// costs an NSWindow plus a SwiftUI hosting view.
    private var mainWindow: MainWindowController?

    /// The in-flight model download, if any. One at a time; dropped on any
    /// terminal event so the next attempt starts clean.
    private var modelDownloader: ModelDownloader?

    /// Warnings already shown this session; each is surfaced exactly once.
    private var shownWarnings: Set<String> = []

    /// Set when the event tap could not be created, so the menu can say so.
    private var hotkeyFailure: String?

    /// See `retire(_:)`.
    private var retiredControllers: [DictationController] = []

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        config = AppConfig.loadOrCreate()
        env = Env.load()
        suppressStartupUI = env["OPENWISPER_SKIP_ONBOARDING"] == "1"

        guard !terminateIfAlreadyRunning() else { return }

        Log.app.info(
            "OpenWisper \(Defaults.version, privacy: .public) starting (bundle: \(Bundle.main.bundlePath, privacy: .public))"
        )

        installMainMenu()
        applyHistoryConfig()

        // Engine first: the controller is built around whatever it resolves to.
        selectEngine(announce: false)
        buildController()
        startHotkeyListener()

        // Last, because its getters run immediately from `init` — everything the
        // action closures read has to exist by now.
        buildStatusBar()

        runOnboardingIfNeeded()
        presentPendingWarnings()
        runMainMenuSelfCheck()
    }

    /// One OpenWisper is enough: two instances would fight over the hotkey tap
    /// and the status item. Only checked for the bundled app — an unbundled
    /// `make run` has no bundle identifier of its own and must not be killed off
    /// by an installed copy that happens to be running.
    private func terminateIfAlreadyRunning() -> Bool {
        guard Bundle.main.bundleIdentifier == Defaults.bundleID else { return false }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Defaults.bundleID)
            .filter { $0.processIdentifier != ownPID }
        guard let existing = others.first else { return false }

        Log.app.error(
            "OpenWisper is already running (pid \(existing.processIdentifier, privacy: .public)) — terminating this instance"
        )
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Teardown

    func applicationWillTerminate(_ notification: Notification) {
        // Stop listening before anything else: a tap callback landing halfway
        // through teardown has nowhere useful to go.
        listener?.stop()
        listener = nil
        controller?.isEnabled = false

        // WhisperLocal's `atexit` net frees any surviving context (ggml's Metal
        // globals abort the process if one is still registered at exit). Doing it
        // here as well is the belt to that suspenders, and it releases the GPU
        // before AppKit starts tearing the process down.
        engine?.local?.unload()

        Log.app.info("OpenWisper terminated")
    }

    // MARK: - Components

    /// Builds `recorder` / `inserter` / `indicator` / `controller` for the
    /// current config and engine. Called at launch, and again when a config
    /// reload changes something `DictationController` owns immutably.
    private func buildController() {
        let selection = engine ?? EngineFactory.make(config: config, env: env)
        engine = selection

        // nil cleaner = "no cleanup", which is the correct offline behaviour:
        // dictation keeps working and the raw transcript is inserted.
        let cleaner = LLMCleaner.make(config: config.cleanup, env: env)
        // History wraps the real inserter rather than living inside
        // DictationController: the transcript is recorded *before* the paste is
        // attempted, so an insertion that lands nowhere — or throws — still
        // leaves the words somewhere the user can get at them.
        let inserter = HistoryRecordingInserter(
            wrapping: makeInserter(config.insert),
            store: history,
            engineName: { [weak self] in self?.currentEngineName() ?? EngineKind.local.rawValue }
        )
        let indicator: RecordingIndicator = config.ui.showPill ? PillController() : NoopIndicator()
        if let pill = indicator as? PillController {
            pill.prefersNotch = config.ui.useNotch
            // Build the panel and run one offscreen layout pass now, so the
            // first dictation doesn't pay the window-creation cost (visible as
            // a beat of lag on the very first hotkey press).
            pill.prewarm()
        }
        let recorder = Recorder(maxSeconds: config.transcription.maxSeconds)

        let controller = DictationController(
            config: config,
            recorder: recorder,
            transcriber: selection.transcriber,
            cleaner: cleaner,
            inserter: inserter,
            indicator: indicator
        )
        // Required for esc-cancel in toggle mode, where the hotkey is not
        // physically held and the listener cannot know a session is live.
        // Reads `self.listener` rather than capturing one, so a rebuilt listener
        // is picked up automatically.
        controller.recordingStateChanged = { [weak self] isRecording in
            guard let self else { return }
            self.listener?.isSessionActive = isRecording
            self.playFeedbackSound(recordingStarted: isRecording)
        }

        if let previous = self.controller {
            controller.isEnabled = previous.isEnabled
            retire(previous)
        }

        self.recorder = recorder
        self.inserter = inserter
        self.indicator = indicator
        self.controller = controller
        listener?.delegate = controller

        Log.app.info(
            "Dictation controller built (insert: \(self.config.insert.mode.rawValue, privacy: .public), pill: \(self.config.ui.showPill, privacy: .public), cleanup: \(cleaner?.name ?? "off", privacy: .public))"
        )
    }

    /// Disarms a replaced controller and keeps it alive long enough for any
    /// utterance already in flight to finish inserting.
    private func retire(_ controller: DictationController) {
        controller.isEnabled = false        // also cancels a live recording
        controller.recordingStateChanged = nil
        retiredControllers.append(controller)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retiredControllerGrace) { [weak self] in
            MainActor.assumeIsolated {
                self?.retiredControllers.removeAll { $0 === controller }
            }
        }
    }

    /// (Re)creates the event tap. Safe to call repeatedly — it is also how a tap
    /// that could not be created at launch gets retried once the user grants
    /// Input Monitoring.
    private func startHotkeyListener() {
        listener?.stop()

        let listener = HotkeyListener(config: config.hotkey)
        listener.delegate = controller
        listener.isSessionActive = controller?.isRecording ?? false
        self.listener = listener

        do {
            try listener.start()
            hotkeyFailure = nil
            Log.app.info(
                "Hotkey \"\(self.config.hotkey.key, privacy: .public)\" armed in \(self.config.hotkey.mode, privacy: .public) mode"
            )
        } catch OWError.inputMonitoringNotGranted {
            hotkeyFailure = "hotkey off, grant Input Monitoring"
            Log.app.error("Could not create the event tap — Input Monitoring is not granted")
        } catch {
            hotkeyFailure = "hotkey off (\(error.localizedDescription))"
            Log.app.error("Could not start the hotkey listener: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func buildStatusBar() {
        let actions = StatusBarActions(
            openMainWindow: { [weak self] in self?.showMainWindow() },
            isEnabled: { [weak self] in self?.controller?.isEnabled ?? false },
            setEnabled: { [weak self] enabled in self?.setDictationEnabled(enabled) },
            currentEngine: { [weak self] in self?.config.transcription.engine ?? .local },
            setEngine: { [weak self] kind in self?.changeEngine(to: kind) },
            engineDetail: { [weak self] in self?.engineDetailText() ?? "no engine" },
            reloadConfig: { [weak self] in self?.reloadConfig() },
            quit: { NSApp.terminate(nil) }
        )
        statusBar = StatusBarController(actions: actions)
    }

    // MARK: - App window

    /// Builds the window on first use and brings it to `page`.
    private func showMainWindow(_ page: MainWindowPage = .history) {
        let controller = mainWindow ?? MainWindowController(
            store: history,
            actions: makeMainWindowActions()
        )
        mainWindow = controller
        controller.show(page: page)
        Log.ui.info("Main window shown on the \(page.rawValue, privacy: .public) page")
    }

    /// Double-clicking OpenWisper in Finder while it is already running has to
    /// do *something* visible, or it looks like the app failed to launch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Everything the window can read or change, as closures. Same discipline
    /// as `StatusBarActions`: MainWindowUI never sees the engine, the cleaner
    /// or the env — only these.
    private func makeMainWindowActions() -> MainWindowActions {
        MainWindowActions(
            currentEngine: { [weak self] in self?.config.transcription.engine ?? .local },
            setEngine: { [weak self] kind in self?.changeEngine(to: kind) },
            engineDetail: { [weak self] in self?.engineDetailText() ?? "no engine" },
            localModel: { [weak self] in self?.localModelInfo() ?? LocalModelInfo(fileName: Defaults.defaultModelFile) },
            apiKeys: { [weak self] in self?.apiKeyPresence() ?? APIKeyPresence() },
            setAPIKey: { [weak self] kind, value in self?.setAPIKey(kind, to: value) },
            downloadModel: { [weak self] onEvent in self?.startModelDownload(onEvent) },
            cancelModelDownload: { [weak self] in self?.modelDownloader?.cancel() },
            isCleanupEnabled: { [weak self] in self?.config.cleanup.enabled ?? false },
            setCleanupEnabled: { [weak self] enabled in self?.setCleanupEnabled(enabled) },
            cleanupDetail: { [weak self] in self?.cleanupDetailText() ?? "unavailable" },
            isHistoryEnabled: { [weak self] in self?.config.history.enabled ?? false },
            setHistoryEnabled: { [weak self] enabled in self?.setHistoryEnabled(enabled) },
            permissions: { Self.permissionsSnapshot() },
            requestPermission: { kind in Self.requestPermission(kind) },
            openConfigFile: {
                // Creates the file (and the directory tree) on a fresh install,
                // so this never opens nothing.
                _ = AppConfig.loadOrCreate()
                NSWorkspace.shared.open(AppPaths.configURL)
            },
            openAppSupportFolder: {
                AppPaths.ensureDirectories()
                NSWorkspace.shared.open(AppPaths.appSupport)
            },
            openModelsFolder: {
                AppPaths.ensureDirectories()
                NSWorkspace.shared.open(AppPaths.modelsDir)
            },
            reloadConfig: { [weak self] in self?.reloadConfig() }
        )
    }

    /// The model file the current config resolves to, and whether it is there.
    private func localModelInfo() -> LocalModelInfo {
        let url = config.transcription.resolvedModelURL()
        var byteSize: Int64?
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            byteSize = Int64(size)
        }
        return LocalModelInfo(fileName: url.lastPathComponent, byteSize: byteSize)
    }

    /// Saves (or removes) a provider key in the App Support `.env`, then
    /// reloads the environment and re-resolves everything a key can affect —
    /// the cleaner and, through `.auto` or an explicit cloud choice, the
    /// engine. The value itself is written to disk and forgotten; it is never
    /// logged and never flows back into the window.
    private func setAPIKey(_ kind: APIKeyKind, to value: String?) {
        let variable: String
        switch kind {
        case .groq: variable = "GROQ_API_KEY"
        case .openai: variable = "OPENAI_API_KEY"
        case .anthropic: variable = "ANTHROPIC_API_KEY"
        }
        do {
            try Env.setValue(value, forKey: variable, in: AppPaths.envURL)
        } catch {
            Log.app.error(
                "Could not write \(variable, privacy: .public) to .env: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        env = Env.load()
        controller?.cleaner = LLMCleaner.make(config: config.cleanup, env: env)
        selectEngine(announce: false)
        Log.app.info("\(variable, privacy: .public) \(value == nil ? "removed" : "saved", privacy: .public)")
    }

    /// The window's Download button. Fetches the recommended model into the
    /// models folder, then re-resolves the engine so a `local` (or `auto`)
    /// choice that was stuck on "no model" starts working immediately.
    private func startModelDownload(_ onEvent: @escaping (ModelDownloadEvent) -> Void) {
        guard modelDownloader == nil else { return }
        guard let url = URL(string: Defaults.defaultModelURL) else {
            onEvent(.failed(message: "The download address is invalid — please report this."))
            return
        }

        let destination = AppPaths.modelsDir.appendingPathComponent(Defaults.defaultModelFile)
        let downloader = ModelDownloader(url: url, destination: destination) { [weak self] event in
            guard let self else { return }
            switch event {
            case .finished:
                self.modelDownloader = nil
                self.selectEngine(announce: false)
            case .cancelled, .failed:
                self.modelDownloader = nil
            case .progress:
                break
            }
            onEvent(event)
        }
        modelDownloader = downloader
        downloader.start()
        Log.app.info("Model download started: \(Defaults.defaultModelURL, privacy: .public)")
    }

    /// Presence only. Key *values* never leave `Env`.
    private func apiKeyPresence() -> APIKeyPresence {
        APIKeyPresence(
            groq: env.groqKey != nil,
            openai: env.openaiKey != nil,
            anthropic: env.anthropicKey != nil
        )
    }

    /// What `cleanup.provider` actually resolved to, for the Model page's one
    /// line about it.
    private func cleanupDetailText() -> String {
        guard let cleaner = LLMCleaner.make(config: config.cleanup, env: env) else {
            return config.cleanup.enabled
                ? "No API key — tidying is skipped, you'll get exactly what you said"
                : "Off — you'll get exactly what you said"
        }
        return "\(Self.providerName(cleaner.provider)) · \(cleaner.model)"
    }

    private static func providerName(_ provider: CleanupProvider) -> String {
        switch provider {
        case .auto: return "Auto"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    private static func permissionsSnapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphone: Permissions.microphone,
            inputMonitoring: Permissions.inputMonitoring,
            // AXIsProcessTrusted is a yes/no; there is no "not yet asked".
            accessibility: Permissions.accessibility ? .granted : .denied
        )
    }

    /// Ask through the API first — that is what registers OpenWisper in the
    /// System Settings list at all — then open the pane, because neither Input
    /// Monitoring nor Accessibility is ever granted by the prompt alone. Same
    /// two-step the menu bar does.
    private static func requestPermission(_ kind: PermissionKind) {
        let pane: Permissions.SettingsPane
        switch kind {
        case .microphone:
            Permissions.requestMicrophone { _ in }
            pane = .microphone
        case .inputMonitoring:
            Permissions.requestInputMonitoring()
            pane = .inputMonitoring
        case .accessibility:
            Permissions.requestAccessibility()
            pane = .accessibility
        }
        Permissions.openSystemSettings(pane)
    }

    // MARK: - Main menu

    /// An `LSUIElement` app has no menu bar — and therefore, by default, no
    /// ⌘C, ⌘V, ⌘A or ⌘W anywhere in its windows: key equivalents are dispatched
    /// through `NSApp.mainMenu`, and ours would be nil. The History page's
    /// search field and every text control in the window depend on this. None
    /// of it is ever *displayed*; it exists so those keystrokes have somewhere
    /// to go.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: Defaults.appName)
        appMenu.addItem(
            withTitle: "Quit \(Defaults.appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // `undo:`/`redo:` are dispatched to the field editor's undo manager and
        // have no Swift-visible declaration for `#selector` to name.
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        // Deliberately not `NSApp.windowsMenu`: that would have AppKit list the
        // pill panel in here.

        NSApp.mainMenu = mainMenu
    }

    /// `OPENWISPER_MENU_SELFTEST=1` has the app interrogate its own main menu
    /// and log what it finds.
    ///
    /// It exists because there is no safe way to check this from outside the
    /// process: posting a real ⌘W at the machine lands in whatever window
    /// happens to be in front, which on a Mac someone is using is somebody
    /// else's unsaved document. Costs nothing when the variable is absent.
    private func runMainMenuSelfCheck() {
        guard env["OPENWISPER_MENU_SELFTEST"] == "1" else { return }
        guard let mainMenu = NSApp.mainMenu else {
            Log.app.error("menu self-check: NSApp.mainMenu is nil — ⌘C/⌘V/⌘W are all dead")
            return
        }
        for key in ["x", "c", "v", "a", "w", "m", "q"] {
            let found = Self.menuItem(forKeyEquivalent: key, in: mainMenu)
            Log.app.info(
                "menu self-check ⌘\(key.uppercased(), privacy: .public) → \(found?.title ?? "MISSING", privacy: .public)"
            )
        }
    }

    private static func menuItem(forKeyEquivalent key: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == key { return item }
            if let submenu = item.submenu, let found = menuItem(forKeyEquivalent: key, in: submenu) {
                return found
            }
        }
        return nil
    }

    // MARK: - Engine

    /// Resolves the engine from the current config + env and hands it to the
    /// controller. In-flight utterances keep the engine they started with — the
    /// controller snapshots it before its first suspension.
    private func selectEngine(announce: Bool) {
        let previousLocal = engine?.local
        let selection = EngineFactory.make(config: config, env: env, reusing: previousLocal)
        engine = selection
        controller?.transcriber = selection.transcriber

        // A local engine we are no longer using is holding the model — and the
        // GPU — for nothing.
        if let previousLocal, previousLocal !== selection.local {
            unloadInBackground(previousLocal)
        }
        if let local = selection.local {
            preload(local)
        }

        Log.app.info("Engine: \(selection.detail, privacy: .public)")
        if announce { presentPendingWarnings() }
        statusBar?.refresh()
    }

    /// Loads the model now rather than on the first utterance. The very first
    /// Metal run on a machine also compiles the embedded shader library (≈9 s) —
    /// no utterance should ever pay for that.
    private func preload(_ local: LocalWhisperTranscriber) {
        guard local.isModelAvailable else { return }
        Task {
            do {
                let seconds = try await local.preload()
                if seconds > 0 {
                    Log.app.info("Whisper model preloaded in \(String(format: "%.2f", seconds), privacy: .public)s")
                }
            } catch {
                // Already surfaced by the engine warning and by the per-utterance
                // error pill; there is nothing extra to tell the user here.
                Log.app.error("Model preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `unload()` blocks until any in-flight load or inference finishes, which on
    /// the first Metal run can be several seconds — never on the main thread.
    private func unloadInBackground(_ local: LocalWhisperTranscriber) {
        let box = UnloadBox(transcriber: local)
        DispatchQueue.global(qos: .utility).async { box.run() }
    }

    /// `LocalWhisperTranscriber` serialises every call into whisper.cpp on its
    /// own queue (see `WhisperContext`), so handing one to a background queue for
    /// the sole purpose of calling `unload()` is safe. This box says so to the
    /// compiler without changing WhisperLocal.
    private struct UnloadBox: @unchecked Sendable {
        let transcriber: LocalWhisperTranscriber
        func run() { transcriber.unload() }
    }

    private func changeEngine(to kind: EngineKind) {
        config.transcription.engine = kind
        saveConfig()
        selectEngine(announce: true)
    }

    private func engineDetailText() -> String {
        let base = engine?.detail ?? "no engine"
        guard let hotkeyFailure else { return base }
        return "\(base) — \(hotkeyFailure)"
    }

    /// Short name of the engine actually in force — `"local"`, `"groq"`,
    /// `"openai"`, never `"auto"`. Stamped onto every history entry.
    private func currentEngineName() -> String {
        (engine?.resolved ?? config.transcription.engine).rawValue
    }

    private func saveConfig() {
        do {
            try config.save()
        } catch {
            Log.app.error("Could not save config.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Feedback sounds

    /// `ui.playSounds` — start/stop feedback, off by default. Loaded once and
    /// held, so an utterance never waits on disk for a 20 kB system sound.
    private lazy var startSound = NSSound(named: NSSound.Name("Tink"))
    private lazy var stopSound = NSSound(named: NSSound.Name("Pop"))

    private func playFeedbackSound(recordingStarted: Bool) {
        guard config.ui.playSounds else { return }
        let sound = recordingStarted ? startSound : stopSound
        // A sound still playing from the previous utterance must restart, not be
        // ignored — back-to-back dictation is the normal case.
        sound?.stop()
        sound?.play()
    }

    // MARK: - Menu actions

    /// Pushes `config.history` into the live store. Called at launch and on
    /// every reload, so editing `history` in config.json takes effect without
    /// a relaunch — and so lowering `maxEntries` trims what is already there.
    private func applyHistoryConfig() {
        history.isEnabled = config.history.enabled
        history.maxEntries = config.history.maxEntries
    }

    /// The window's "Save history" switch: persist it *and* apply it live, so
    /// the next utterance is already recorded (or not).
    private func setHistoryEnabled(_ enabled: Bool) {
        config.history.enabled = enabled
        saveConfig()
        history.isEnabled = enabled
        Log.app.info("Transcript history \(enabled ? "on" : "off", privacy: .public)")
    }

    /// The window's cleanup switch. Mirrors what `reloadConfig` does for the
    /// same setting: a fresh cleaner (or nil, which means "skip cleanup") on
    /// the controller that is already running.
    private func setCleanupEnabled(_ enabled: Bool) {
        config.cleanup.enabled = enabled
        saveConfig()
        controller?.cleaner = LLMCleaner.make(config: config.cleanup, env: env)
        Log.app.info("Cleanup \(enabled ? "on" : "off", privacy: .public)")
    }

    private func setDictationEnabled(_ enabled: Bool) {
        controller?.isEnabled = enabled
        // Re-arming is the natural moment to retry a tap that could not be
        // created at launch — the user may have granted Input Monitoring since.
        if enabled, listener?.isRunning != true { startHotkeyListener() }
        statusBar?.refresh()
    }

    /// Re-reads config.json (and `.env`, so a key added there takes effect) and
    /// re-applies everything it touches.
    private func reloadConfig() {
        let previous = config
        config = AppConfig.loadOrCreate()
        env = Env.load()

        controller?.config = config
        controller?.cleaner = LLMCleaner.make(config: config.cleanup, env: env)
        applyHistoryConfig()

        // `DictationController` owns its recorder, inserter and indicator
        // immutably, so anything that changes one of those needs a fresh
        // controller rather than a mutation.
        if Self.needsControllerRebuild(from: previous, to: config) {
            buildController()
        }

        if previous.hotkey.key != config.hotkey.key || listener?.isRunning != true {
            startHotkeyListener()
        }

        selectEngine(announce: true)
        statusBar?.refresh()
        Log.app.info("Config reloaded from \(AppPaths.configURL.path, privacy: .public)")
    }

    private static func needsControllerRebuild(from old: AppConfig, to new: AppConfig) -> Bool {
        old.insert.mode != new.insert.mode
            || old.insert.restoreClipboardDelayMs != new.insert.restoreClipboardDelayMs
            || old.insert.copyToClipboard != new.insert.copyToClipboard
            || old.ui.showPill != new.ui.showPill
            || old.ui.useNotch != new.ui.useNotch
            || old.transcription.maxSeconds != new.transcription.maxSeconds
    }

    // MARK: - Onboarding & warnings

    /// On the very first launch, and on any later launch where a permission is
    /// missing, open the app window on the Permissions page — those are exactly
    /// the states where nothing works and the reason is invisible.
    ///
    /// This used to run a modal alert flow (`OnboardingPrompt`), which read as a
    /// second, icon-less "app" that popped up over everything. The window shows
    /// the same facts with live status dots instead, and its poll loop notices
    /// grants as they land in System Settings.
    private func runOnboardingIfNeeded() {
        guard !suppressStartupUI else {
            Log.app.info("OPENWISPER_SKIP_ONBOARDING=1 — skipping all startup UI")
            return
        }
        guard OnboardingMarker.isFirstLaunch || !Permissions.allGranted else { return }

        OnboardingMarker.markShown()
        showMainWindow(.permissions)
    }

    /// One alert for every engine warning not yet shown this session.
    private func presentPendingWarnings() {
        guard !suppressStartupUI else { return }
        let pending = (engine?.warnings ?? []).filter { shownWarnings.insert($0).inserted }
        guard !pending.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "OpenWisper needs a quick setup step"
        alert.informativeText = pending.joined(separator: "\n\n")
        // Every warning's fix now lives on the Model page (download the model,
        // add a key), so the button goes straight there.
        alert.addButton(withTitle: "Open Model Page…")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            showMainWindow(.model)
        }
    }
}
