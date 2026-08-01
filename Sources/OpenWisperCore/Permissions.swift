import AppKit
import ApplicationServices
import AVFoundation
import IOKit
import IOKit.hid

public enum PermissionStatus {
    case granted, denied, undetermined
}

/// The three TCC permissions OpenWisper needs, plus System Settings deep links.
///  - Microphone: record speech
///  - Input Monitoring: the global hotkey event tap (listen-only)
///  - Accessibility: posting the synthetic Cmd-V / keystrokes
public enum Permissions {
    // MARK: Microphone

    public static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    public static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Accessibility

    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// With `prompt: true`, macOS shows its own "grant in System Settings" dialog once.
    @discardableResult
    public static func requestAccessibility(prompt: Bool = true) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Input Monitoring

    public static var inputMonitoring: PermissionStatus {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted { return .granted }
        if access == kIOHIDAccessTypeDenied { return .denied }
        return .undetermined
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: System Settings deep links

    public enum SettingsPane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    public static func openSystemSettings(_ pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    /// True when everything dictation needs is in place.
    public static var allGranted: Bool {
        microphone == .granted && accessibility && inputMonitoring == .granted
    }
}
