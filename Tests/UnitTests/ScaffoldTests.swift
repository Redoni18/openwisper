import Foundation
import Testing

@testable import OpenWisperCore

@Suite("Scaffold — config & env")
struct ScaffoldTests {

    @Test("A default config survives an encode/decode round trip")
    func defaultConfigRoundTrip() throws {
        let cfg = AppConfig()
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.hotkey.key == "fn")
        #expect(back.transcription.engine == .local)
        #expect(back.insert.mode == .paste)
    }

    @Test("An empty JSON object decodes to the defaults")
    func tolerantDecodeFromEmptyObject() throws {
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(cfg.hotkey.key == "fn")
        #expect(cfg.cleanup.provider == .auto)
    }

    @Test("insert.copyToClipboard defaults to true and round-trips false")
    func copyToClipboardConfig() throws {
        let defaults = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(defaults.insert.copyToClipboard)

        let json = #"{"insert": {"copyToClipboard": false}}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!cfg.insert.copyToClipboard)
        #expect(cfg.insert.mode == .paste, "sibling defaults must survive a partial insert block")
    }

    @Test("`.env` parsing handles comments, `export`, and quotes")
    func envParsing() {
        let parsed = Env.parse("""
        # comment
        GROQ_API_KEY=gsk_123
        export OPENAI_API_KEY="sk-456"
        EMPTY=
        QUOTED='hello world'
        """)
        #expect(parsed["GROQ_API_KEY"] == "gsk_123")
        #expect(parsed["OPENAI_API_KEY"] == "sk-456")
        #expect(parsed["QUOTED"] == "hello world")

        let env = Env(values: parsed)
        #expect(env["EMPTY"] == nil, "empty values should read as nil")
        #expect(env.groqKey == "gsk_123")
    }
}
