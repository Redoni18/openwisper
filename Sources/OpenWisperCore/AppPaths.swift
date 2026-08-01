import Foundation

/// Canonical on-disk locations. Everything user-facing lives under
/// ~/Library/Application Support/OpenWisper/.
public enum AppPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Defaults.appName, isDirectory: true)
    }

    public static var modelsDir: URL {
        appSupport.appendingPathComponent("models", isDirectory: true)
    }

    public static var configURL: URL {
        appSupport.appendingPathComponent("config.json")
    }

    public static var envURL: URL {
        appSupport.appendingPathComponent(".env")
    }

    /// The local transcript history (`TranscriptHistoryStore`). The only file
    /// OpenWisper writes that contains anything you said.
    public static var historyURL: URL {
        appSupport.appendingPathComponent(Defaults.historyFile)
    }

    /// Creates the directory tree if missing. Safe to call repeatedly.
    public static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [appSupport, modelsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
