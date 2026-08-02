// Env.setValue — the writer behind the window's "Add Key" flow. The rules
// under test: other lines survive byte-for-byte, duplicates collapse, values
// are trimmed, empty means remove, and the file ends up owner-only.
import Foundation
import Testing

@testable import OpenWisperCore

@Suite("Env writing")
struct EnvWriteTests {

    /// A scratch file per test; the suite never touches the real .env.
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("env-write-tests-\(UUID().uuidString)")
            .appendingPathComponent(".env")
    }

    @Test func createsFileAndKey() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Env.setValue("gsk_abc123", forKey: "GROQ_API_KEY", in: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "GROQ_API_KEY=gsk_abc123\n")
        #expect(Env.parse(fileAt: url)["GROQ_API_KEY"] == "gsk_abc123")
    }

    @Test func replacesExistingValueInPlace() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Env.setValue("old", forKey: "OPENAI_API_KEY", in: url)
        try Env.setValue("keep", forKey: "GROQ_API_KEY", in: url)
        try Env.setValue("new", forKey: "OPENAI_API_KEY", in: url)

        let parsed = Env.parse(fileAt: url)
        #expect(parsed["OPENAI_API_KEY"] == "new")
        #expect(parsed["GROQ_API_KEY"] == "keep")

        // Replaced in place: the key it came before is still after it.
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines == ["OPENAI_API_KEY=new", "GROQ_API_KEY=keep"])
    }

    @Test func preservesCommentsAndUnrelatedLines() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = """
        # Cloud transcription
        GROQ_API_KEY=gsk_original
        
        export OPENAI_API_KEY=sk_exported
        SOMETHING_ELSE=untouched
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try original.write(to: url, atomically: true, encoding: .utf8)

        try Env.setValue("gsk_updated", forKey: "GROQ_API_KEY", in: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# Cloud transcription"))
        #expect(text.contains("SOMETHING_ELSE=untouched"))
        #expect(text.contains("GROQ_API_KEY=gsk_updated"))
        // The `export`-style assignment of a *different* key is untouched.
        #expect(text.contains("export OPENAI_API_KEY=sk_exported"))
        #expect(!text.contains("gsk_original"))
    }

    @Test func nilRemovesTheKey() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Env.setValue("value", forKey: "ANTHROPIC_API_KEY", in: url)
        try Env.setValue("keep", forKey: "GROQ_API_KEY", in: url)
        try Env.setValue(nil, forKey: "ANTHROPIC_API_KEY", in: url)

        let parsed = Env.parse(fileAt: url)
        #expect(parsed["ANTHROPIC_API_KEY"] == nil)
        #expect(parsed["GROQ_API_KEY"] == "keep")
    }

    @Test func whitespaceOnlyValueMeansRemoval() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Env.setValue("value", forKey: "GROQ_API_KEY", in: url)
        try Env.setValue("   \n", forKey: "GROQ_API_KEY", in: url)

        #expect(Env.parse(fileAt: url)["GROQ_API_KEY"] == nil)
    }

    @Test func trimsPastedWhitespace() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // The classic paste: a key with a trailing newline.
        try Env.setValue("sk_key\n", forKey: "OPENAI_API_KEY", in: url)

        #expect(Env.parse(fileAt: url)["OPENAI_API_KEY"] == "sk_key")
    }

    @Test func collapsesDuplicateAssignments() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = """
        GROQ_API_KEY=first
        GROQ_API_KEY=second
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try original.write(to: url, atomically: true, encoding: .utf8)

        try Env.setValue("only", forKey: "GROQ_API_KEY", in: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "GROQ_API_KEY=only\n")
    }

    @Test func quotesValuesTheParserWouldMisread() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Env.setValue("abc def#ghi", forKey: "GROQ_API_KEY", in: url)

        // Round-trips through the parser (which strips one quote layer).
        #expect(Env.parse(fileAt: url)["GROQ_API_KEY"] == "abc def#ghi")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "GROQ_API_KEY=\"abc def#ghi\"\n")
    }

    @Test func fileIsOwnerOnly() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Env.setValue("secret", forKey: "GROQ_API_KEY", in: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test func repeatedWritesDoNotAccumulateBlankLines() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for value in ["one", "two", "three"] {
            try Env.setValue(value, forKey: "GROQ_API_KEY", in: url)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "GROQ_API_KEY=three\n")
    }
}
