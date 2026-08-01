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

    public var groqKey: String? { self["GROQ_API_KEY"] }
    public var openaiKey: String? { self["OPENAI_API_KEY"] }
    public var anthropicKey: String? { self["ANTHROPIC_API_KEY"] }
}
