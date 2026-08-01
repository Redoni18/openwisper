// Theme — OpenWisper's design language, in one file.
//
// The palette is lifted straight out of the app icon: the cornflower blue it
// sits on, the monkey's fur brown, the cream of its face. Everything else is
// warm-tinted neutrals rather than system gray, which is most of what makes
// the window read as "this app" instead of "a settings pane". Every color is
// a light/dark pair resolved through NSAppearance, so the same views render
// correctly in both modes — including offscreen in `window-demo`, which snaps
// each appearance explicitly.
//
// Nothing in here talks to the model layer. Views own *what* is on screen;
// this file owns *how it looks*.
import AppKit
import SwiftUI

// MARK: - Palette

enum OWTheme {

    // --- Icon-derived accents ---

    /// The icon's cornflower blue. Primary accent: selection, toggles, the
    /// one important button on a page.
    static let accent = dynamic(light: 0x4B87E2, dark: 0x6AA0F0)
    static let accentPressed = dynamic(light: 0x3D74C9, dark: 0x5B8FDD)
    /// The monkey's fur. Secondary accent: engine chips, small warm details.
    static let brown = dynamic(light: 0xA95F33, dark: 0xD08A5B)
    /// The monkey's face. Soft highlight fill for the "all set" hero.
    static let cream = dynamic(light: 0xF6E8C6, dark: 0x3B3324)

    // --- Warm neutrals ---

    /// The content area behind everything. Warm paper, not system gray.
    static let windowBg = dynamic(light: 0xFAF7F1, dark: 0x211F1C)
    /// The sidebar sits a shade deeper so the window has structure without a
    /// hard divider.
    static let sidebarBg = dynamic(light: 0xF1ECE1, dark: 0x1B1917)
    static let cardBg = dynamic(light: 0xFFFFFF, dark: 0x2B2825)
    static let cardStroke = dynamic(light: 0x000000, dark: 0xFFFFFF,
                                    lightAlpha: 0.07, darkAlpha: 0.09)
    /// Quiet-control resting fill and hover fill for rows.
    static let softFill = dynamic(light: 0x000000, dark: 0xFFFFFF,
                                  lightAlpha: 0.045, darkAlpha: 0.065)
    /// The sidebar's selected pill. A fixed accent opacity washed out against
    /// the dark sidebar, so the two appearances get their own strength.
    static let selectionFill = dynamic(light: 0x4B87E2, dark: 0x6AA0F0,
                                       lightAlpha: 0.14, darkAlpha: 0.24)

    /// What `NSWindow.backgroundColor` is set to, so the flash during a live
    /// resize matches what SwiftUI paints a frame later.
    static let nsWindowBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x211F1C) : NSColor(hex: 0xFAF7F1)
    }

    // --- Type ---

    /// Rounded for titles and the wordmark — the "homemade" register — and
    /// only there. Body text stays in the system default for legibility.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Color plumbing

    private static func dynamic(
        light: UInt32, dark: UInt32,
        lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Brand image

enum OWAssets {
    /// The monkey, full-bleed on its blue square, shipped as a SwiftPM resource
    /// so the unbundled `window-demo` and the installed app both have it.
    /// `BrandMark` clips it to a squircle at whatever size it is shown.
    ///
    /// Resolved by hand instead of `Bundle.module`: the generated accessor
    /// traps when the resource bundle is missing (say, an app assembled by an
    /// older make_app.sh), and a missing brand image should degrade to the app
    /// icon, never crash the window.
    static let monkey: NSImage? = {
        let bundleName = "OpenWisper_MainWindowUI.bundle"
        var candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        // `swift run` / `swift test`: the bundle sits next to the executable.
        candidates.append(
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        )
        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent(bundleName),
                  let bundle = Bundle(url: url),
                  let image = bundle.url(forResource: "monkey-512", withExtension: "jpg")
                      .flatMap({ NSImage(contentsOf: $0) })
            else { continue }
            return image
        }
        return NSApp.applicationIconImage
    }()
}

/// The monkey in a continuous-corner squircle — sidebar mark, empty states,
/// the all-granted hero. Corner radius tracks the macOS icon grid (≈22.4%).
struct BrandMark: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let monkey = OWAssets.monkey {
                Image(nsImage: monkey)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                // No asset and no app icon: never render a hole.
                OWTheme.accent
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.224, style: .continuous)
                .strokeBorder(OWTheme.cardStroke, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Card

/// The page building block: white (or warm-dark) surface, hairline stroke,
/// a whisper of shadow. Sections are cards; cards never nest.
struct OWCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OWTheme.cardBg)
                .shadow(color: .black.opacity(0.05), radius: 7, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OWTheme.cardStroke, lineWidth: 1)
        )
    }
}

/// The tracked micro-label above a card.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Buttons

/// The one loud button on a page: accent capsule, white text.
struct OWPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(configuration.isPressed ? OWTheme.accentPressed : OWTheme.accent)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

/// Everything else: quiet capsule, soft fill, hairline stroke. `tint` warms
/// the text (destructive red, accent blue) without shouting.
struct OWQuietButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint ?? Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(OWTheme.softFill.opacity(configuration.isPressed ? 2 : 1)))
            .overlay(Capsule().strokeBorder(OWTheme.cardStroke, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OWPrimaryButtonStyle {
    static var owPrimary: OWPrimaryButtonStyle { OWPrimaryButtonStyle() }
}

extension ButtonStyle where Self == OWQuietButtonStyle {
    static var owQuiet: OWQuietButtonStyle { OWQuietButtonStyle() }
    static var owQuietDestructive: OWQuietButtonStyle { OWQuietButtonStyle(tint: .red) }
}

// MARK: - Chips

/// A small tinted capsule: the engine tag on a history row, key presence,
/// model-on-disk state. `tint` at ~12% for the fill, full for the text.
struct Chip: View {
    let text: String
    var tint: Color = OWTheme.brown
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3.5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// Permission state as a chip: dot + word, tinted by status. Same green /
/// amber / red reading as the menu bar's ✓ and ⚠.
struct StatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityLabel(label)
    }
}

// MARK: - Hover

/// Row-level hover state without every view rolling its own `@State`.
struct HoverReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}
