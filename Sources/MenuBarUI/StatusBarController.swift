// StatusBarController — the NSStatusItem menu (Task W5).
//
// This module deliberately knows nothing about DictationController, the engines
// or the config beyond OpenWisperCore's value types: everything it can read or
// change goes through the closures in `StatusBarActions`, which the Wave-B
// integrator supplies. That keeps the menu buildable and reviewable on its own,
// and keeps engine/enable state owned by exactly one place — the app.
import AppKit
import OpenWisperCore
import ServiceManagement

/// Everything the status bar menu can observe or change in the running app.
///
/// The getters are polled every time the menu (or a submenu) is about to open,
/// via `NSMenuDelegate.menuNeedsUpdate`, so the integrator never has to push
/// state into the controller. Call `StatusBarController.refresh()` explicitly
/// only when something changes while the menu is already on screen.
///
/// All closures are invoked on the main thread.
public struct StatusBarActions {
    /// Bring up the app window (History / Model / Permissions), front and key.
    public var openMainWindow: () -> Void
    /// Is dictation currently armed (hotkey listening)?
    public var isEnabled: () -> Bool
    /// Arm / disarm dictation.
    public var setEnabled: (Bool) -> Void
    /// The engine currently selected in config.
    public var currentEngine: () -> EngineKind
    /// Persist and apply a new engine choice.
    public var setEngine: (EngineKind) -> Void
    /// Short human-readable engine summary for the header row,
    /// e.g. `"Local · ggml-small.en"` or `"Groq · whisper-large-v3-turbo"`.
    public var engineDetail: () -> String
    /// Re-read config.json from disk and re-apply it.
    public var reloadConfig: () -> Void
    /// Terminate the app.
    public var quit: () -> Void

    public init(
        openMainWindow: @escaping () -> Void,
        isEnabled: @escaping () -> Bool,
        setEnabled: @escaping (Bool) -> Void,
        currentEngine: @escaping () -> EngineKind,
        setEngine: @escaping (EngineKind) -> Void,
        engineDetail: @escaping () -> String,
        reloadConfig: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.openMainWindow = openMainWindow
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.currentEngine = currentEngine
        self.setEngine = setEngine
        self.engineDetail = engineDetail
        self.reloadConfig = reloadConfig
        self.quit = quit
    }
}

// MARK: - Menu content tables

/// Display order and labels of the Engine submenu. Index into this array is
/// stored in each item's `tag`.
private let engineChoices: [(kind: EngineKind, title: String)] = [
    (.auto, "Auto"),
    (.local, "Local"),
    (.groq, "Groq"),
    (.openai, "OpenAI"),
]

/// The three TCC permissions, in the order the README walks through them.
/// `rawValue` is stored in each item's `tag`.
private enum PermissionRow: Int, CaseIterable {
    case microphone = 0
    case inputMonitoring = 1
    case accessibility = 2

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    /// Shown as the item's tooltip so the menu explains itself.
    var reason: String {
        switch self {
        case .microphone: return "Needed to record your voice."
        case .inputMonitoring: return "Needed for the dictation hotkey."
        case .accessibility: return "Needed to paste what you said into the app you're using."
        }
    }

    var pane: Permissions.SettingsPane {
        switch self {
        case .microphone: return .microphone
        case .inputMonitoring: return .inputMonitoring
        case .accessibility: return .accessibility
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return Permissions.microphone == .granted
        case .inputMonitoring: return Permissions.inputMonitoring == .granted
        case .accessibility: return Permissions.accessibility
        }
    }
}

private let grantedGlyph = "✓"
private let missingGlyph = "⚠"

// MARK: - Controller

/// The menu bar item: a template mic glyph plus the app's only real UI surface.
///
/// The menu is built once and then *refreshed in place* whenever it is about to
/// open, which keeps key equivalents and submenu identity stable.
@MainActor
public final class StatusBarController: NSObject, NSMenuDelegate {

    // MARK: Stored state

    private let actions: StatusBarActions
    private let statusItem: NSStatusItem

    private let menu = NSMenu()
    private let engineMenu = NSMenu()
    private let permissionsMenu = NSMenu()

    private let headerItem = NSMenuItem()
    private let enabledItem = NSMenuItem()
    private let permissionsItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()
    private var engineItems: [NSMenuItem] = []
    private var permissionItems: [NSMenuItem] = []

    /// Launch-at-login needs a real bundle: `SMAppService.mainApp` has nothing to
    /// register when we are running straight out of `.build/<config>/OpenWisper`.
    private let isBundled = Bundle.main.bundlePath.hasSuffix(".app")

    /// Pinned point size so "mic.fill" and "mic.slash" occupy the same width and
    /// the item does not jump when dictation is toggled.
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)

    // MARK: Lifecycle

    public init(actions: StatusBarActions) {
        self.actions = actions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        statusItem.menu = menu
        refresh()
    }

    // MARK: Menu construction (once)

    private func buildMenu() {
        // Manual enablement: NSMenu's automatic validation would re-enable the
        // header row and the unbundled "Launch at Login" item behind our back,
        // because their target implements the action.
        for m in [menu, engineMenu, permissionsMenu] {
            m.autoenablesItems = false
            m.delegate = self
        }

        // --- Header ---------------------------------------------------------
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        // --- Open the window ------------------------------------------------
        // First actionable item: for most people this menu is now the way *in*
        // to the app rather than the app itself.
        let openWindowItem = NSMenuItem(
            title: "Open \(Defaults.appName)…",
            action: #selector(openMainWindow(_:)),
            keyEquivalent: "o"
        )
        openWindowItem.keyEquivalentModifierMask = [.command]
        openWindowItem.target = self
        openWindowItem.toolTip = "Transcript history, engine and permissions."
        menu.addItem(openWindowItem)

        menu.addItem(.separator())

        // --- Enabled --------------------------------------------------------
        enabledItem.title = "Enabled"
        enabledItem.target = self
        enabledItem.action = #selector(toggleEnabled(_:))
        enabledItem.keyEquivalent = "e"
        enabledItem.keyEquivalentModifierMask = [.command]
        enabledItem.toolTip = "Stop listening for the hotkey without quitting OpenWisper."
        menu.addItem(enabledItem)

        // --- Engine ---------------------------------------------------------
        for (index, choice) in engineChoices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            engineMenu.addItem(item)
            engineItems.append(item)
        }
        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        menu.addItem(.separator())

        // --- Permissions ----------------------------------------------------
        for row in PermissionRow.allCases {
            let item = NSMenuItem(title: row.title, action: #selector(handlePermission(_:)), keyEquivalent: "")
            item.target = self
            item.tag = row.rawValue
            item.toolTip = row.reason
            permissionsMenu.addItem(item)
            permissionItems.append(item)
        }
        permissionsMenu.addItem(.separator())
        let recheckItem = NSMenuItem(title: "Re-check", action: #selector(recheckPermissions(_:)), keyEquivalent: "")
        recheckItem.target = self
        recheckItem.toolTip = "Re-read the current permission state."
        permissionsMenu.addItem(recheckItem)

        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)

        // --- Launch at login ------------------------------------------------
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin(_:))
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        // --- Files ----------------------------------------------------------
        menu.addItem(actionItem("Advanced Settings File", #selector(openConfigFile(_:))))
        menu.addItem(actionItem("Open Models Folder", #selector(openModelsFolder(_:))))
        menu.addItem(actionItem("Reload Settings", #selector(reloadConfigFromDisk(_:))))

        menu.addItem(.separator())

        // --- Quit -----------------------------------------------------------
        let quitItem = NSMenuItem(
            title: "Quit \(Defaults.appName)",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Refresh

    /// Re-syncs the status icon and every dynamic title / check state from the
    /// injected getters and the live permission + login-item APIs.
    public func refresh() {
        refreshIcon()
        headerItem.title = "\(Defaults.appName) v\(Defaults.version) — \(actions.engineDetail())"
        enabledItem.state = actions.isEnabled() ? .on : .off
        refreshEngineItems()
        refreshPermissionItems()
        refreshLaunchAtLoginItem()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let enabled = actions.isEnabled()
        let symbol = enabled ? "mic.fill" : "mic.slash"
        let description = enabled
            ? "\(Defaults.appName) — dictation enabled"
            : "\(Defaults.appName) — dictation disabled"

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(Self.symbolConfiguration) {
            image.isTemplate = true
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            // Should not happen on macOS 14+, but never leave a zero-width item
            // the user cannot click.
            button.image = nil
            button.title = "OW"
            button.imagePosition = .noImage
        }
        button.appearsDisabled = !enabled
        button.toolTip = description
    }

    private func refreshEngineItems() {
        let current = actions.currentEngine()
        for (item, choice) in zip(engineItems, engineChoices) {
            item.state = (choice.kind == current) ? .on : .off
        }
    }

    private func refreshPermissionItems() {
        var allGranted = true
        for (item, row) in zip(permissionItems, PermissionRow.allCases) {
            let granted = row.isGranted
            allGranted = allGranted && granted
            item.title = "\(granted ? grantedGlyph : missingGlyph)  \(row.title)"
        }
        // Surface the warning one level up, so a missing grant is visible without
        // opening the submenu (ARCHITECTURE.md: "menu shows warning state").
        permissionsItem.title = allGranted ? "Permissions" : "Permissions  \(missingGlyph)"
    }

    private func refreshLaunchAtLoginItem() {
        guard isBundled else {
            launchAtLoginItem.title = "Launch at Login (requires installed app)"
            launchAtLoginItem.isEnabled = false
            launchAtLoginItem.state = .off
            launchAtLoginItem.toolTip =
                "Move OpenWisper to the Applications folder to use this."
            return
        }
        let status = SMAppService.mainApp.status
        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.isEnabled = true
        launchAtLoginItem.state = (status == .enabled) ? .on : .off
        launchAtLoginItem.toolTip = (status == .requiresApproval)
            ? "Approve OpenWisper under Login Items in System Settings → General."
            : nil
    }

    // MARK: Actions

    @objc private func openMainWindow(_ sender: NSMenuItem) {
        actions.openMainWindow()
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        actions.setEnabled(!actions.isEnabled())
        refresh()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard engineChoices.indices.contains(sender.tag) else { return }
        actions.setEngine(engineChoices[sender.tag].kind)
        // The header shows the engine detail, so refresh the whole menu.
        refresh()
    }

    @objc private func handlePermission(_ sender: NSMenuItem) {
        guard let row = PermissionRow(rawValue: sender.tag) else { return }
        // Ask through the API first — that is what registers OpenWisper in the
        // System Settings list at all — then open the pane, because neither
        // Input Monitoring nor Accessibility is ever granted by the prompt alone.
        switch row {
        case .microphone:
            // The completion fires after the menu has closed, so there is nothing
            // to update from it; the next menu open re-polls the status.
            Permissions.requestMicrophone { _ in }
        case .inputMonitoring:
            Permissions.requestInputMonitoring()
        case .accessibility:
            Permissions.requestAccessibility()
        }
        Permissions.openSystemSettings(row.pane)
        refreshPermissionItems()
    }

    @objc private func recheckPermissions(_ sender: NSMenuItem) {
        refresh()
        // Clicking dismissed the menu, so re-open it on the next main-actor turn:
        // otherwise "Re-check" looks like it did nothing.
        Task { @MainActor in
            self.statusItem.button?.performClick(nil)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard isBundled else { return }
        let service = SMAppService.mainApp
        let wasEnabled = service.status == .enabled

        var failure: String?
        do {
            if wasEnabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            failure = error.localizedDescription
        }

        if let failure {
            presentAlert(
                title: wasEnabled
                    ? "Could not turn off Launch at Login"
                    : "Could not turn on Launch at Login",
                message: failure,
                offersLoginItems: true
            )
        } else if !wasEnabled, SMAppService.mainApp.status == .requiresApproval {
            // register() succeeds but stays inert once the user has switched
            // OpenWisper off in System Settings; only they can turn it back on.
            presentAlert(
                title: "OpenWisper needs your approval to launch at login",
                message: "Turn OpenWisper on under Login Items in System Settings → General.",
                offersLoginItems: true
            )
        }

        refreshLaunchAtLoginItem()
    }

    @objc private func openConfigFile(_ sender: NSMenuItem) {
        // Creates the file (and the directory tree) on a fresh install, so this
        // item never opens nothing.
        _ = AppConfig.loadOrCreate()
        NSWorkspace.shared.open(AppPaths.configURL)
    }

    @objc private func openModelsFolder(_ sender: NSMenuItem) {
        AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.modelsDir)
    }

    @objc private func reloadConfigFromDisk(_ sender: NSMenuItem) {
        actions.reloadConfig()
        refresh()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        actions.quit()
    }

    // MARK: Alerts

    private func presentAlert(title: String, message: String, offersLoginItems: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if offersLoginItems {
            alert.addButton(withTitle: "Open Login Items…")
        }
        // An LSUIElement app is never the active app, so without this the alert
        // opens behind whatever the user was typing into.
        NSApp.activate()
        let response = alert.runModal()
        if offersLoginItems, response == .alertSecondButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: NSMenuDelegate

    /// Everything dynamic is re-read here, so the menu can never show stale
    /// permission, engine or login-item state.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            refresh()
        } else if menu === engineMenu {
            refreshEngineItems()
        } else if menu === permissionsMenu {
            refreshPermissionItems()
        }
    }
}
