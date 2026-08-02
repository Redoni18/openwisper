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
                    keysSection
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
                        select: { select(kind) }
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
                downloadCard
            }

            Text("Local never sends anything anywhere. Cloud options upload each recording to their provider under your own API key — Groq for speed, or OpenAI's hosted service.")
                .formFootnote()
        }
    }

    /// Selecting a cloud engine that has no key yet also opens its key field —
    /// choosing an engine and giving it what it needs are one gesture.
    private func select(_ kind: EngineKind) {
        model.setEngine(kind)
        let keyKind: APIKeyKind? = switch kind {
        case .groq: .groq
        case .openai: .openai
        case .local, .auto: nil
        }
        if let keyKind, !model.hasKey(keyKind), model.editingKey != keyKind {
            model.beginKeyEntry(keyKind)
        }
    }

    // MARK: Model download

    /// Shown only while the local model file is missing: one button that
    /// fetches it, with live progress. No terminal, no repo, no `make`.
    private var downloadCard: some View {
        OWCard {
            switch model.modelDownload {
            case .idle:
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get the on-device model")
                            .font(.system(size: 13, weight: .medium))
                        Text("A one-time \(Self.approxModelSize) download. After that, transcription works entirely on this Mac — even offline.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Download") { model.startModelDownload() }
                        .buttonStyle(.owPrimary)
                }

            case .downloading(let fraction, let receivedBytes):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Downloading the model…")
                            .font(.system(size: 13, weight: .medium))
                        Spacer(minLength: 8)
                        Text(Self.progressLabel(fraction: fraction, receivedBytes: receivedBytes))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Cancel") { model.cancelModelDownload() }
                            .buttonStyle(.owQuiet)
                    }
                    if let fraction {
                        ProgressView(value: fraction)
                            .tint(OWTheme.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(OWTheme.accent)
                    }
                }

            case .failed(let message):
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The download didn't finish")
                            .font(.system(size: 13, weight: .medium))
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Try Again") { model.startModelDownload() }
                        .buttonStyle(.owPrimary)
                }
            }
        }
    }

    private static let approxModelSize = ByteCountFormatter.string(
        fromByteCount: Defaults.defaultModelApproxBytes, countStyle: .file
    )

    private static func progressLabel(fraction: Double?, receivedBytes: Int64) -> String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        guard let fraction else { return received }
        return "\(Int((fraction * 100).rounded()))% · \(received)"
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

    // MARK: API keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("API keys")

            OWCard(padding: 0) {
                ForEach(Array(APIKeyKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 {
                        Divider().padding(.leading, 56)
                    }
                    KeyRow(model: model, kind: kind)
                }
            }

            Text("Keys are optional — OpenWisper works fully offline without any. They are saved on this Mac only, never shown again, and never sent anywhere except to the provider you got them from.")
                .formFootnote()
        }
    }

    // MARK: Cleanup

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Cleanup")

            OWCard {
                Toggle(isOn: model.cleanupEnabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tidy up your dictation with AI")
                            .font(.system(size: 13, weight: .medium))
                        Text("Removes fillers and false starts, fixes punctuation. It never rephrases you.")
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
                }
            }

            Text("If tidying fails or times out, you still get exactly what you said — your words are never lost to a flaky network. With no key at all, tidying is skipped and dictation keeps working offline.")
                .formFootnote()
        }
    }

    // MARK: Config file

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Everything else")

            OWCard {
                HStack(spacing: 8) {
                    Button("Open Settings File") { model.openConfigFile() }
                        .buttonStyle(.owQuiet)
                    Button("Reload Settings") { model.reloadConfig() }
                        .buttonStyle(.owQuiet)
                    Spacer(minLength: 0)
                }
            }

            Text("Advanced settings — the hotkey, paste behavior and more — live in config.json. Open it, edit, then click Reload.")
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
        case .local: return "On this Mac. Offline and private."
        case .groq: return "In Groq's cloud. Fast."
        case .openai: return "In OpenAI's cloud."
        case .auto: return "On this Mac when possible, then Groq, then OpenAI."
        }
    }

    private var help: String {
        switch kind {
        case .local: return "Nothing leaves this machine."
        case .groq: return "Needs a Groq API key — add it below."
        case .openai: return "Needs an OpenAI API key — add it below."
        case .auto: return "Hands-off: uses whatever is available."
        }
    }
}

// MARK: - API key row

/// One provider: name, whether a key is saved, and the buttons to add,
/// replace or remove one. The paste field appears inline under the row, so
/// the whole flow — click, paste, save — happens on this page.
private struct KeyRow: View {
    @ObservedObject var model: MainWindowModel
    let kind: APIKeyKind

    private var hasKey: Bool { model.hasKey(kind) }
    private var isEditing: Bool { model.editingKey == kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: hasKey ? "key.fill" : "key")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(hasKey ? Color.green : OWTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((hasKey ? Color.green : OWTheme.accent).opacity(0.11))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                    Text(blurb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Chip(
                    text: hasKey ? "Key saved" : "No key",
                    tint: hasKey ? .green : .secondary,
                    systemImage: hasKey ? "checkmark" : "key.slash"
                )

                Button(hasKey ? "Replace…" : "Add Key…") { model.beginKeyEntry(kind) }
                    .buttonStyle(.owQuiet)
                if hasKey {
                    Button("Remove") { model.removeKey(kind) }
                        .buttonStyle(.owQuietDestructive)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if isEditing {
                HStack(spacing: 8) {
                    SecureField("Paste your \(name) API key", text: $model.keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { model.saveKeyDraft() }
                    Button("Save") { model.saveKeyDraft() }
                        .buttonStyle(.owPrimary)
                        .disabled(model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { model.cancelKeyEntry() }
                        .buttonStyle(.owQuiet)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }
        }
    }

    private var name: String {
        switch kind {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    private var blurb: String {
        switch kind {
        case .groq: return "Fast cloud transcription, plus transcript cleanup."
        case .openai: return "Cloud transcription, plus transcript cleanup."
        case .anthropic: return "Transcript cleanup with Claude."
        }
    }
}
