// The window's root: brand sidebar on the left, whichever page it selects on
// the right.
//
// Everything below is driven by `MainWindowModel` and nothing else, so the same
// views render identically in the running app and in `window-demo`'s offscreen
// snapshots — the demo just hands the model a different set of closures.
//
// The window has no visible title bar (see MainWindowController): the sidebar
// runs the full height of the window and the traffic lights float over its top
// padding, which is why the brand block leaves room for them.
import OpenWisperCore
import SwiftUI

// MARK: - Root

public struct MainWindowRootView: View {
    @ObservedObject private var model: MainWindowModel

    public init(model: MainWindowModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .background(OWTheme.windowBg)
        }
        // Paint under the (transparent) title bar; the sidebar's own top
        // padding is what keeps content clear of the traffic lights.
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .history:
            HistoryPage(model: model)
        case .model:
            ModelPage(model: model)
        case .permissions:
            PermissionsPage(model: model)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.top, 46)   // clear of the traffic lights
                .padding(.bottom, 22)

            ForEach(MainWindowPage.allCases) { page in
                SidebarItem(page: page, isSelected: model.page == page) {
                    model.page = page
                }
            }

            Spacer(minLength: 0)

            Text("\(Defaults.appName) \(Defaults.version)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.leading, 10)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OWTheme.sidebarBg)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            BrandMark(size: 30)
            Text(Defaults.appName)
                .font(OWTheme.display(15))
        }
        .padding(.leading, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SidebarItem: View {
    let page: MainWindowPage
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        HoverReader { hovering in
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20)
                    Text(page.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? OWTheme.accent : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected
                            ? OWTheme.selectionFill
                            : hovering ? OWTheme.softFill : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.bottom, 2)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Page scaffold

/// Title, one line of explanation, then the page. Every page uses it, so the
/// three of them line up to the pixel when you switch between them.
struct PageScaffold<Content: View>: View {
    let page: MainWindowPage
    private let content: () -> Content

    init(_ page: MainWindowPage, @ViewBuilder content: @escaping () -> Content) {
        self.page = page
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                    .font(OWTheme.display(23))
                Text(page.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 16)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared bits

extension View {
    /// The explanatory paragraph under a card: full-width, left-aligned,
    /// quiet.
    func formFootnote() -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Status → color/word, one place. Green / amber / red, the same reading the
/// menu bar's ✓ and ⚠ give.
enum StatusReading {
    static func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .undetermined: return .orange
        }
    }

    static func label(for status: PermissionStatus) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .undetermined: return "Not yet asked"
        }
    }

    static func chip(for status: PermissionStatus) -> StatusChip {
        StatusChip(label: label(for: status), color: color(for: status))
    }
}

/// "Key found" / "No key" — the only thing the UI is ever allowed to say about
/// an API key. Values are never rendered, never copied, never logged.
struct KeyPresenceLabel: View {
    let variable: String
    let isPresent: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isPresent ? "key.fill" : "key.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isPresent ? Color.green : Color.secondary)
            Text(variable)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(isPresent ? .primary : .secondary)
            Chip(
                text: isPresent ? "found" : "not set",
                tint: isPresent ? .green : .secondary
            )
        }
    }
}
