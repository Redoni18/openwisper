import os

/// Unified loggers — view with Console.app filtered to subsystem com.openwisper.app.
/// No file logging, no telemetry: logs stay in the local unified log.
public enum Log {
    private static let subsystem = Defaults.bundleID

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let stt = Logger(subsystem: subsystem, category: "stt")
    public static let llm = Logger(subsystem: subsystem, category: "llm")
    public static let insert = Logger(subsystem: subsystem, category: "insert")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
