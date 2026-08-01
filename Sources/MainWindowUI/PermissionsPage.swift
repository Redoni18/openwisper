// Permissions — the three macOS approvals that decide whether OpenWisper works
// at all, plus the fn-key setting that decides whether the default hotkey is
// usable.
//
// Status is injected (`MainWindowActions.permissions`) rather than read from
// `Permissions` directly, so `window-demo` can render a mixed state offscreen
// without touching TCC. The live wiring polls the real API.
import OpenWisperCore
import SwiftUI

struct PermissionsPage: View {
    @ObservedObject var model: MainWindowModel

    /// How often the page re-reads TCC while it is on screen.
    private static let pollSeconds: UInt64 = 2

    var body: some View {
        PageScaffold(.permissions) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    permissionsSection
                    keyboardSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
        .task {
            // A grant happens in System Settings — another app, no notification
            // back to us — so polling is the only way this page can be right.
            // `.task` cancels the loop when the page goes away.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                model.refreshPermissions()
            }
        }
    }

    // MARK: Hero

    /// All granted → a small celebration. Anything missing → the count and a
    /// Re-check, in warning amber. The one glance that answers "will it work?"
    @ViewBuilder
    private var hero: some View {
        if model.permissions.allGranted {
            HStack(spacing: 13) {
                BrandMark(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all set")
                        .font(OWTheme.display(16))
                    Text("All three permissions are granted. Hold your hotkey anywhere and start talking.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.green)
            }
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OWTheme.cream)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(OWTheme.brown.opacity(0.25), lineWidth: 1)
            )
        } else {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.orange)
                Text(attentionText)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Button("Re-check") { model.refreshPermissions() }
                    .buttonStyle(.owQuiet)
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var attentionText: String {
        let granted = PermissionKind.allCases
            .filter { model.permissions.status(for: $0) == .granted }
            .count
        return "\(granted) of 3 granted — dictation will not work until all three are on."
    }

    // MARK: The three permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Privacy & Security")

            OWCard(padding: 0) {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 {
                        Divider().padding(.leading, 56)
                    }
                    permissionRow(kind)
                }
            }

            Text("Input Monitoring and Accessibility cannot be granted from a dialog — the button asks macOS (which is what puts OpenWisper in the list at all) and then opens the pane so you can flip the switch. **Quit and relaunch OpenWisper afterwards:** macOS does not always hand a running process its new rights.")
                .formFootnote()
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = model.permissions.status(for: kind)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OWTheme.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OWTheme.accent.opacity(0.11))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 13, weight: .medium))
                Text(kind.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            StatusReading.chip(for: status)

            Button("Open System Settings") { model.requestPermission(kind) }
                .buttonStyle(.owQuiet)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: fn key

    /// Not a TCC permission and not deep-linkable, but it is the fourth thing
    /// that stops the default hotkey from working, so it belongs on this page.
    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Keyboard")

            OWCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OWTheme.brown)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OWTheme.brown.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Free up the fn key")
                            .font(.system(size: 13, weight: .medium))
                        Text(
                            """
                            System Settings → Keyboard → **“Press 🌐 key to”** → **Do Nothing**. Otherwise holding fn \
                            opens the emoji picker or starts Apple's own dictation on top of OpenWisper. Check \
                            Keyboard → Dictation while you are there, and make sure its shortcut is not the globe key either.
                            """
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("This pane cannot be opened reliably from another app — open System Settings and go to Keyboard yourself. Or sidestep it entirely with a different hotkey: `\"hotkey\": { \"key\": \"f13\" }` in config.json.")
                .formFootnote()
        }
    }
}
