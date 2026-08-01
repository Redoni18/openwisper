// MainWindowModel — the single observable the window's three pages read from.
//
// It is a *mirror*, not a source of truth: every published property is pulled
// out of `MainWindowActions` (or the history store) by `refresh()`, and every
// mutation goes straight back out through an action closure and then re-pulls.
// Nothing about the app's state lives only here, which is what lets the window
// be closed and re-opened, or rendered offscreen by `window-demo` with canned
// closures, without any of the pages knowing the difference.
import AppKit
import Combine
import OpenWisperCore
import SwiftUI

@MainActor
public final class MainWindowModel: ObservableObject {

    // MARK: Injected

    /// The live history store. The window mutates it directly (delete, clear);
    /// the on/off switch goes through `actions` instead, because it has to be
    /// persisted to config.json as well.
    private let store: TranscriptHistoryStore
    private let actions: MainWindowActions

    // MARK: Mirrored app state

    @Published public var page: MainWindowPage
    @Published public private(set) var entries: [TranscriptEntry] = []
    @Published public private(set) var historyEnabled = true
    @Published public private(set) var engine: EngineKind = .local
    @Published public private(set) var engineDetail = ""
    @Published public private(set) var localModel = LocalModelInfo(fileName: Defaults.defaultModelFile)
    @Published public private(set) var apiKeys = APIKeyPresence()
    @Published public private(set) var cleanupEnabled = true
    @Published public private(set) var cleanupDetail = ""
    @Published public private(set) var permissions = PermissionsSnapshot()

    // MARK: View state

    /// Case-insensitive filter over transcript text.
    @Published public var search = ""
    /// The row showing its full text. Only one at a time — the list is a
    /// scanning surface first and a reading surface second.
    @Published public var expandedEntry: UUID?
    /// The row whose Copy button is currently saying "Copied".
    @Published public private(set) var copiedEntry: UUID?
    @Published public var isConfirmingClear = false

    /// Resets `copiedEntry` a beat after a copy. Held so a second copy cancels
    /// the first one's reset instead of clearing the new confirmation early.
    private var copyResetTask: Task<Void, Never>?

    /// How long a row says "Copied" before going back to "Copy".
    private static let copiedFeedbackSeconds: TimeInterval = 1.2

    public init(
        store: TranscriptHistoryStore,
        actions: MainWindowActions,
        page: MainWindowPage = .history
    ) {
        self.store = store
        self.actions = actions
        self.page = page
        refresh()

        // The store is the only thing that changes without the window asking:
        // a dictation that completes while the window is open has to land in
        // the list. `onChange` has exactly one observer by contract, and this
        // is it.
        store.onChange = { [weak self] in self?.reloadEntries() }
    }

    // MARK: - Reading

    /// Re-pulls everything from the injected getters. Cheap — all of it is
    /// either in memory or a single `stat` — so it is safe to call on every
    /// window activation and page switch.
    public func refresh() {
        reloadEntries()
        historyEnabled = actions.isHistoryEnabled()
        engine = actions.currentEngine()
        engineDetail = actions.engineDetail()
        localModel = actions.localModel()
        apiKeys = actions.apiKeys()
        cleanupEnabled = actions.isCleanupEnabled()
        cleanupDetail = actions.cleanupDetail()
        permissions = actions.permissions()
    }

    /// The Permissions page polls this on a slow timer while it is on screen:
    /// granting a permission happens in System Settings, in another app, with
    /// no notification back to us.
    public func refreshPermissions() {
        permissions = actions.permissions()
    }

    private func reloadEntries() {
        entries = store.entries
        // A row that vanished (deleted elsewhere, or dropped by the cap) must
        // not leave the list holding a selection nothing renders.
        if let expandedEntry, !entries.contains(where: { $0.id == expandedEntry }) {
            self.expandedEntry = nil
        }
    }

    public var filteredEntries: [TranscriptEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    public var isSearching: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - History actions

    public func isCopied(_ entry: TranscriptEntry) -> Bool {
        copiedEntry == entry.id
    }

    /// One click, one transcript on the clipboard. The whole point of the
    /// History page.
    public func copy(_ entry: TranscriptEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)

        copiedEntry = entry.id
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.copiedFeedbackSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.copiedEntry = nil
        }
    }

    public func toggleExpanded(_ entry: TranscriptEntry) {
        expandedEntry = (expandedEntry == entry.id) ? nil : entry.id
    }

    public func delete(_ entry: TranscriptEntry) {
        store.delete(id: entry.id)   // fires onChange → reloadEntries()
    }

    public func clearAll() {
        store.clear()
    }

    public func setHistoryEnabled(_ enabled: Bool) {
        actions.setHistoryEnabled(enabled)
        historyEnabled = actions.isHistoryEnabled()
    }

    public var historyEnabledBinding: Binding<Bool> {
        Binding(get: { self.historyEnabled }, set: { self.setHistoryEnabled($0) })
    }

    // MARK: - Model page actions

    public func setEngine(_ kind: EngineKind) {
        actions.setEngine(kind)
        // Switching engines re-resolves the detail string, the model file and
        // (via `.auto`) sometimes the engine itself, so re-pull everything.
        refresh()
    }

    public var engineBinding: Binding<EngineKind> {
        Binding(get: { self.engine }, set: { self.setEngine($0) })
    }

    public func setCleanupEnabled(_ enabled: Bool) {
        actions.setCleanupEnabled(enabled)
        cleanupEnabled = actions.isCleanupEnabled()
        cleanupDetail = actions.cleanupDetail()
    }

    public var cleanupEnabledBinding: Binding<Bool> {
        Binding(get: { self.cleanupEnabled }, set: { self.setCleanupEnabled($0) })
    }

    public func openConfigFile() { actions.openConfigFile() }
    public func openAppSupportFolder() { actions.openAppSupportFolder() }
    public func openModelsFolder() { actions.openModelsFolder() }

    public func reloadConfig() {
        actions.reloadConfig()
        refresh()
    }

    // MARK: - Permissions page actions

    public func requestPermission(_ kind: PermissionKind) {
        actions.requestPermission(kind)
        // The grant happens in System Settings, so this only ever catches the
        // microphone prompt's immediate answer; the timer picks up the rest.
        refreshPermissions()
    }
}
