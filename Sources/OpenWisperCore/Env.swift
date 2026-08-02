import Foundation

/// Minimal .env support. Precedence (highest wins):
///   process environment  >  ./.env (dev runs)  >  App Support/OpenWisper/.env
public struct Env {
    public private(set) var values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }

    public static func load() -> Env {
        var merged: [String: String] = [:]
        let files = [
            AppPaths.envURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        ]
        for file in files {
            for (k, v) in parse(fileAt: file) { merged[k] = v }
        }
        for (k, v) in ProcessInfo.processInfo.environment { merged[k] = v }
        return Env(values: merged)
    }

    public static func parse(fileAt url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// KEY=VALUE lines; supports `export KEY=...`, `#` comments, and single/double quotes.
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    /// nil when the key is absent or empty.
    public subscript(_ key: String) -> String? {
        guard let v = values[key], !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return v
    }

    // MARK: - Writing

    /// Sets (or, with `nil`, removes) one `KEY=VALUE` line in a `.env` file,
    /// preserving every other line — comments, blank lines, unrelated keys —
    /// exactly as they were. This is what lets the app take an API key pasted
    /// into the window instead of making the user edit a hidden dotfile.
    ///
    /// The value is trimmed; a value that trims to empty means removal, so a
    /// stray newline on a pasted key can never write `KEY=` and shadow nothing.
    /// The file is created if missing and always written owner-only (0600):
    /// it holds secrets.
    public static func setValue(_ value: String?, forKey key: String, in fileURL: URL) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = (trimmed?.isEmpty == false) ? trimmed : nil

        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        // A trailing newline parses as one empty final element; drop it so we
        // do not accumulate blank lines on every write.
        if lines.last == "" { lines.removeLast() }

        var replaced = false
        lines = lines.compactMap { line -> String? in
            guard defines(line, key: key) else { return line }
            guard !replaced, let newValue else { return nil }  // drop duplicates / removals
            replaced = true
            return "\(key)=\(quoteIfNeeded(newValue))"
        }
        if !replaced, let newValue {
            lines.append("\(key)=\(quoteIfNeeded(newValue))")
        }

        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
    }

    /// Does this line assign `key`? Mirrors `parse`: `KEY=`, `export KEY=`,
    /// surrounding whitespace — but never a comment.
    private static func defines(_ rawLine: String, key: String) -> Bool {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return false }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard let eq = line.firstIndex(of: "=") else { return false }
        return String(line[..<eq]).trimmingCharacters(in: .whitespaces) == key
    }

    /// `parse` strips one layer of double quotes, so quoting is round-trip safe
    /// for values that would otherwise be misread (inline `#` starts a comment
    /// in many .env dialects; leading/trailing spaces would be trimmed away).
    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuotes = value.contains("#") || value.contains(" ")
            || value.hasPrefix("'") || value.hasPrefix("\"")
        return needsQuotes ? "\"\(value)\"" : value
    }

    public var groqKey: String? { self["GROQ_API_KEY"] }
    public var openaiKey: String? { self["OPENAI_API_KEY"] }
    public var anthropicKey: String? { self["ANTHROPIC_API_KEY"] }
}
