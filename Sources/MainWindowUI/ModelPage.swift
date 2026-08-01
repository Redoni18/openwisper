// Model — which engine is transcribing, what it needs, and where the knobs are.
//
// Only the two settings that are genuinely a *choice* get controls here (engine
// and cleanup); everything else in config.json stays file-driven and gets an
// "Open Config File" button instead. A settings pane that half-duplicates a
// config file is worse than either one alone.
//
// The engine picker is four cards, not a segmented control: each option
// carries its own one-line pitch and its own live status (model on disk, key
// present), so choosing an engine and finding out why it will not work are the
// same surface.
import OpenWisperCore
import SwiftUI

struct ModelPage: View {
    @ObservedObject var model: MainWindowModel

    /// Local first — it is the default and the whole point of the app; `.auto`
    /// last as the hands-off option.
    private static let engineOrder: [EngineKind] = [.local, .groq, .openai, .auto]

    var body: some View {
        PageScaffold(.model) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    engineSection
                    cleanupSection
                    configSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Transcription engine")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)],
                spacing: 10
            ) {
                ForEach(Self.engineOrder, id: \.self) { kind in
                    EngineCard(
                        kind: kind,
                        isSelected: model.engine == kind,
                        status: status(for: kind),
                        select: { model.setEngine(kind) }
                    )
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OWTheme.accent)
                Text("Currently using")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(model.engineDetail)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.top, 2)

            if !model.localModel.isAvailable {
                HStack(spacing: 8) {
                    Text("Local needs a model on disk first — run `make model` in the repo.")
                        .formFootnote()
                    Button("Open Models Folder") { model.openModelsFolder() }
                        .buttonStyle(.owQuiet)
                }
            }

            Text("Local never sends anything anywhere. The cloud engines upload each utterance's audio to their provider under your own API key, in exchange for speed (Groq) or OpenAI's hosted model.")
                .formFootnote()
        }
    }

    private func status(for kind: EngineKind) -> EngineCard.Status {
        switch kind {
        case .local:
            if let size = model.localModel.formattedSize {
                return .init(text: "\(size) on disk", tint: .green, icon: "internaldrive")
            }
            return .init(text: "No model yet", tint: .orange, icon: "exclamationmark.triangle.fill")
        case .groq:
            return keyStatus(present: model.apiKeys.groq)
        case .openai:
            return keyStatus(present: model.apiKeys.openai)
        case .auto:
            return .init(text: "Picks for you", tint: OWTheme.brown, icon: "sparkles")
        }
    }

    private func keyStatus(present: Bool) -> EngineCard.Status {
        present
            ? .init(text: "Key found", tint: .green, icon: "key.fill")
            : .init(text: "No key", tint: .secondary, icon: "key.slash")
    }

    // MARK: Cleanup

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Cleanup")

            OWCard {
                Toggle(isOn: model.cleanupEnabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clean up transcripts with an LLM")
                            .font(.system(size: 13, weight: .medium))
                        Text("Strips fillers and false starts, fixes punctuation. It never rephrases you.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(OWTheme.accent)

                Divider()
                    .padding(.vertical, 12)

                HStack(spacing: 6) {
                    Text("Provider")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(model.cleanupDetail)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Button("Open Folder") { model.openAppSupportFolder() }
                        .buttonStyle(.owQuiet)
                        .help("The .env file with your keys lives here.")
                }

                VStack(alignment: .leading, spacing: 6) {
                    KeyPresenceLabel(variable: "GROQ_API_KEY", isPresent: model.apiKeys.groq)
                    KeyPresenceLabel(variable: "OPENAI_API_KEY", isPresent: model.apiKeys.openai)
                    KeyPresenceLabel(variable: "ANTHROPIC_API_KEY", isPresent: model.apiKeys.anthropic)
                }
                .padding(.top, 10)
            }

            Text("Any cleanup failure or timeout falls back to the raw transcript — your words are never lost to a flaky network. Keys live in `~/Library/Application Support/OpenWisper/.env`, tried in order Groq → OpenAI → Anthropic; with no key at all, cleanup is skipped and dictation keeps working offline.")
                .formFootnote()
        }
    }

    // MARK: Config file

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Everything else")

            OWCard {
                HStack(spacing: 8) {
                    Button("Open Config File") { model.openConfigFile() }
                        .buttonStyle(.owQuiet)
                    Button("Reload Config") { model.reloadConfig() }
                        .buttonStyle(.owQuiet)
                    Spacer(minLength: 0)
                }
            }

            Text("The hotkey, insertion mode, pill appearance and history size all live in `config.json`. Edit it and press Reload Config — no relaunch needed.")
                .formFootnote()
        }
    }
}

// MARK: - Engine card

private struct EngineCard: View {
    struct Status {
        let text: String
        let tint: Color
        let icon: String
    }

    let kind: EngineKind
    let isSelected: Bool
    let status: Status
    let select: () -> Void

    var body: some View {
        HoverReader { hovering in
            Button(action: select) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : OWTheme.accent)
                            .frame(width: 27, height: 27)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSelected ? OWTheme.accent : OWTheme.accent.opacity(0.12))
                            )
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(OWTheme.accent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tagline)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            // Two lines whether it needs them or not, so the
                            // four cards stay the same height.
                            .frame(minHeight: 27, alignment: .top)
                    }

                    Chip(text: status.text, tint: status.tint, systemImage: status.icon)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? OWTheme.accent.opacity(0.07) : OWTheme.cardBg)
                        .shadow(color: .black.opacity(hovering && !isSelected ? 0.06 : 0.03),
                                radius: 6, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? OWTheme.accent
                                : hovering ? OWTheme.accent.opacity(0.3) : OWTheme.cardStroke,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.easeOut(duration: 0.13), value: hovering)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(help)
        }
    }

    private var name: String {
        switch kind {
        case .auto: return "Auto"
        case .local: return "Local"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    private var symbol: String {
        switch kind {
        case .auto: return "sparkles"
        case .local: return "desktopcomputer"
        case .groq: return "bolt.fill"
        case .openai: return "cloud.fill"
        }
    }

    private var tagline: String {
        switch kind {
        case .local: return "whisper.cpp on this Mac. Offline and private."
        case .groq: return "Whisper large-v3-turbo in Groq's cloud. Fast."
        case .openai: return "OpenAI's hosted Whisper API."
        case .auto: return "Local when a model exists, then Groq, then OpenAI."
        }
    }

    private var help: String {
        switch kind {
        case .local: return "Nothing leaves this machine."
        case .groq: return "Needs GROQ_API_KEY in .env."
        case .openai: return "Needs OPENAI_API_KEY in .env."
        case .auto: return "Hands-off: uses whatever is available."
        }
    }
}
