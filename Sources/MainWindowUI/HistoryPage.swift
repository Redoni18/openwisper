// History — everything OpenWisper has inserted, newest first.
//
// The reason this page exists: insertion is the one step that can fail
// invisibly. A paste with no text field focused, an app that eats synthetic
// ⌘V, an insert that throws — the words are gone and there is nowhere to get
// them back from. `HistoryRecordingInserter` writes the transcript here *before*
// handing it to the inserter, so this list is that "nowhere". Hence one-click
// Copy on every row.
//
// The transcript is the row: text first and largest, metadata whispered under
// it, actions only on hover. A history you *scan* — not a table you parse.
import OpenWisperCore
import SwiftUI

struct HistoryPage: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        PageScaffold(.history) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search transcripts", text: $model.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if model.isSearching {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OWTheme.cardBg)
                .shadow(color: .black.opacity(0.04), radius: 5, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OWTheme.cardStroke, lineWidth: 1)
        )
    }

    // MARK: List / empty states

    @ViewBuilder
    private var content: some View {
        if !model.historyEnabled && model.entries.isEmpty {
            EmptyState(
                title: "History is off",
                message: "OpenWisper is not saving transcripts. Turn it on and everything it types for you from now on shows up here."
            ) {
                Button("Turn On Save History") { model.setHistoryEnabled(true) }
                    .buttonStyle(.owPrimary)
            }
        } else if model.entries.isEmpty {
            EmptyState(
                title: "Nothing here yet",
                message: "Hold your hotkey and say something — every transcript lands here, ready to copy."
            )
        } else if model.filteredEntries.isEmpty {
            EmptyState(
                title: "No matches",
                message: "No transcript contains “\(model.search.trimmingCharacters(in: .whitespacesAndNewlines))”."
            )
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.filteredEntries) { entry in
                    HistoryRow(
                        entry: entry,
                        isExpanded: model.expandedEntry == entry.id,
                        isCopied: model.isCopied(entry),
                        copy: { model.copy(entry) },
                        delete: { model.delete(entry) },
                        toggleExpanded: { model.toggleExpanded(entry) }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text(countText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: 0)

            Toggle("Save history", isOn: model.historyEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .tint(OWTheme.accent)
                .help("Keep a local record of everything OpenWisper types for you.")

            Button("Clear All…") { model.isConfirmingClear = true }
                .buttonStyle(.owQuietDestructive)
                .disabled(model.entries.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(OWTheme.sidebarBg.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(OWTheme.cardStroke).frame(height: 1)
        }
        .confirmationDialog(
            "Delete all \(model.entries.count) saved transcripts?",
            isPresented: $model.isConfirmingClear
        ) {
            Button("Clear All", role: .destructive) { model.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved transcript. It cannot be undone.")
        }
    }

    private var countText: String {
        let total = model.entries.count
        let noun = total == 1 ? "transcript" : "transcripts"
        guard model.isSearching else { return "\(total) \(noun)" }
        return "\(model.filteredEntries.count) of \(total) \(noun)"
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: TranscriptEntry
    let isExpanded: Bool
    let isCopied: Bool
    let copy: () -> Void
    let delete: () -> Void
    let toggleExpanded: () -> Void

    var body: some View {
        HoverReader { hovering in
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.text)
                    .font(.system(size: 13.5))
                    .lineSpacing(2.5)
                    .lineLimit(isExpanded ? nil : 2)
                    // Without this a wrapped line is clipped instead of
                    // growing the row.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Room for the hover actions so they never sit on text.
                    .padding(.trailing, 96)

                HStack(spacing: 7) {
                    Text(entry.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Chip(text: entry.engine)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OWTheme.cardBg)
                    .shadow(color: .black.opacity(hovering ? 0.07 : 0.04),
                            radius: hovering ? 8 : 5, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        hovering ? OWTheme.accent.opacity(0.35) : OWTheme.cardStroke,
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                actions(visible: hovering || isCopied)
                    .padding(10)
            }
            .animation(.easeOut(duration: 0.13), value: hovering)
            // The whole row is the expand affordance, so a long transcript can
            // be read in place instead of being copied out to see it.
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(perform: toggleExpanded)
            .help(entry.date.formatted(date: .abbreviated, time: .standard))
            .contextMenu {
                Button("Copy", action: copy)
                Button(isExpanded ? "Collapse" : "Expand", action: toggleExpanded)
                Divider()
                Button("Delete", role: .destructive, action: delete)
            }
        }
    }

    /// Copy + delete, revealed on hover. Copy stays visible while it is
    /// confirming, so the ✓ never vanishes mid-beat under a moved pointer.
    private func actions(visible: Bool) -> some View {
        HStack(spacing: 5) {
            Button(action: delete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Circle().fill(OWTheme.softFill))
            }
            .buttonStyle(.plain)
            .help("Delete this transcript")

            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(isCopied ? "Copied" : "Copy")
                        .font(.system(size: 11.5, weight: .medium))
                }
                // Pinned width: the label swaps between two strings and the
                // row must not twitch when it does.
                .frame(minWidth: 58)
                .foregroundStyle(isCopied ? Color.white : OWTheme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    Capsule().fill(isCopied ? Color.green : OWTheme.accent.opacity(0.13))
                )
            }
            .buttonStyle(.plain)
            .help("Copy this transcript to the clipboard")
            .animation(.spring(duration: 0.22), value: isCopied)
        }
        .opacity(visible ? 1 : 0)
    }
}

// MARK: - Empty states

private struct EmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(title: String, message: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandMark(size: 64)
            VStack(spacing: 5) {
                Text(title)
                    .font(OWTheme.display(16))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            actions()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 28)   // optical center against the footer bar
    }
}
