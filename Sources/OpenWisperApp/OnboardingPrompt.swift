import Foundation
import OpenWisperCore

/// The "has this Mac ever run OpenWisper before?" marker.
///
/// Onboarding itself is the app window opened on its Permissions page — see
/// `AppDelegate.runOnboardingIfNeeded()`. All this type owns is the one bit of
/// state that decision needs, kept as a file in Application Support rather than
/// in UserDefaults so that deleting the OpenWisper folder really does reset the
/// app to a fresh install.
enum OnboardingMarker {

    /// Created the first time onboarding is shown. Its absence is what
    /// "first launch" means.
    private static var markerURL: URL {
        AppPaths.appSupport.appendingPathComponent(".onboarded")
    }

    static var isFirstLaunch: Bool {
        !FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func markShown() {
        AppPaths.ensureDirectories()
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    }
}
