// The SwiftUI half of the floating pill: a compact dark glass capsule rendering
// one of four states (recording / processing / success / error).
//
// Driven entirely by `PillModel`, which `PillController` owns and mutates on the
// main actor. The view never talks to AppKit and never handles input — the
// hosting view routes clicks (✕ = cancel, anywhere else = drag) using the
// geometry contract in `PillMetrics`, so keep those numbers in sync with the
// layout here.
//
// Recording renders a scrolling history of the live input level: every
// `updateLevel` pushes one sample into `PillModel.levels`, so the bars are a
// 1.3-second oscillogram of the speaker's actual voice — louder speech reads
// instantly as taller motion, silence decays to a quiet shimmer floor.
import AppKit
import Combine
import OpenWisperCore
import SwiftUI

// MARK: - Metrics

/// Layout constants shared by the SwiftUI pill, the AppKit panel sizing, and the
/// panel's click hit-testing. The panel hugs the pill (pill size + shadow
/// padding), so the pill rect inside the panel is always
/// `(shadowPadding, shadowPadding, pillWidth, height)`.
public enum PillMetrics {
    public static let height: CGFloat = 40
    /// Width of recording/processing/success. Error grows to fit its message.
    public static let standardWidth: CGFloat = 116
    public static let maxWidth: CGFloat = 320
    public static let horizontalPadding: CGFloat = 11

    /// Breathing room around the pill so the drop shadow is never clipped.
    /// Also the pill's origin inside the panel.
    public static let shadowPadding: CGFloat = 16
    /// Gap between the pill's bottom edge and the screen's visible frame when
    /// the user has not moved it.
    public static let bottomMargin: CGFloat = 24
    /// How far the pill travels upward while fading in.
    public static let riseOffset: CGFloat = 8

    // Waveform. The model keeps `historyLength` samples; each presentation
    // renders the most recent slice it has room for, so the docked pill can
    // show a longer stretch of the same history than the floating one.
    static let historyLength = 40
    static let barCount = 22
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 1
    static let barMinHeight: CGFloat = 3
    static let barMaxHeight: CGFloat = 28

    // Cancel control (present in recording + processing)
    public static let cancelDiameter: CGFloat = 22
    /// Distance from the pill's trailing edge to the ✕ circle's trailing edge.
    public static let cancelTrailingInset: CGFloat = 9

    /// Whether the given state renders the ✕ control (and should hit-test it).
    public static func showsCancel(for state: PillState) -> Bool {
        switch state {
        case .recording, .processing: return true
        case .success, .error: return false
        }
    }

    public static func pillWidth(for state: PillState) -> CGFloat {
        switch state {
        case .recording, .processing, .success:
            return standardWidth
        case .error(let message):
            // Measured with AppKit metrics so the width is a plain animatable
            // number (SwiftUI's system font maps to exactly this NSFont).
            let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            let measured = (message as NSString).size(withAttributes: [.font: font]).width
            let chrome = horizontalPadding * 2 + PillLayout.errorIconWidth + PillLayout.errorIconSpacing
            return min(max(standardWidth, chrome + ceil(measured) + 4), maxWidth)
        }
    }

    /// The panel hugs the pill: content size + shadow padding on every side.
    public static func panelSize(for state: PillState) -> CGSize {
        CGSize(
            width: pillWidth(for: state) + shadowPadding * 2,
            height: height + shadowPadding * 2
        )
    }

    /// The ✕ hit zone in *panel* coordinates (bottom-left origin), padded a few
    /// points beyond the drawn circle so it is comfortably clickable.
    public static func cancelHitRect(for state: PillState) -> CGRect {
        let pillW = pillWidth(for: state)
        let slack: CGFloat = 4
        let x = shadowPadding + pillW - cancelTrailingInset - cancelDiameter - slack
        let y = shadowPadding + (height - cancelDiameter) / 2 - slack
        return CGRect(
            x: x,
            y: y,
            width: cancelDiameter + slack * 2,
            height: cancelDiameter + slack * 2
        )
    }

    /// The pill capsule itself, in panel coordinates — the draggable region.
    public static func pillRect(for state: PillState) -> CGRect {
        CGRect(x: shadowPadding, y: shadowPadding, width: pillWidth(for: state), height: height)
    }
}

private enum PillLayout {
    static let errorIconWidth: CGFloat = 14
    static let errorIconSpacing: CGFloat = 7
}

// MARK: - Palette

/// Explicit values rather than semantic colors: the pill is always dark glass,
/// whatever the user's appearance setting is.
enum Palette {
    static let text = Color.white.opacity(0.92)
    static let successGreen = Color(red: 0.22, green: 0.84, blue: 0.38)
    static let warningOrange = Color(red: 1.00, green: 0.64, blue: 0.08)
    static let barTop = Color.white.opacity(0.95)
    static let barBottom = Color.white.opacity(0.45)
    static let strokeTop = Color.white.opacity(0.22)
    static let strokeBottom = Color.white.opacity(0.03)
    static let tint = Color.black.opacity(0.22)
    static let backdrop = Color.black.opacity(0.52)
    static let shadow = Color.black.opacity(0.32)
    static let cancelGlyph = Color.white.opacity(0.70)
    static let cancelCircle = Color.white.opacity(0.12)
    static let cancelGlyphHover = Color.white.opacity(0.98)
    static let cancelCircleHover = Color(red: 0.94, green: 0.32, blue: 0.30).opacity(0.85)
}

let pillFont = Font.system(size: 11.5, weight: .medium)

// MARK: - Model

/// The single source of truth the hosting view observes.
/// `PillController` is the only writer, always on the main actor.
@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .recording
    /// Scrolling level history, oldest first, exactly `PillMetrics.historyLength`
    /// entries. Each `updateLevel` shifts left and appends.
    @Published var levels: [Double] = Array(repeating: 0, count: PillMetrics.historyLength)
    /// When the current recording began, for the docked pill's elapsed clock.
    @Published var recordingStartedAt: Date?
    /// False once the panel has been ordered out; pauses animation timelines.
    @Published var isOnScreen: Bool = false
    /// Pointer is over the ✕. Drives its hover highlight — the affordance that
    /// works even where the system cursor cannot be changed.
    @Published var hoveringCancel: Bool = false

    // MARK: Notch presentation

    /// True when the pill is docked in the display's notch rather than
    /// floating. Switches the whole root view.
    @Published var isNotchDocked: Bool = false
    /// Drives the expand/collapse animation while docked: false renders exactly
    /// the notch silhouette, true grows the content strip out of it.
    @Published var isExpanded: Bool = false
    /// The host display's notch size, so the docked view can align its content
    /// strip immediately below the (pixel-less) cutout.
    @Published var notchSize: CGSize = .zero
}

/// Identity key for the crossfade: the error message can change without
/// restarting the transition, but a change of *kind* swaps the content.
private enum PillKind: Hashable {
    case recording, processing, success, error
}

private extension PillState {
    var kind: PillKind {
        switch self {
        case .recording: return .recording
        case .processing: return .processing
        case .success: return .success
        case .error: return .error
        }
    }
}

// MARK: - Pill

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        content
            .padding(.horizontal, PillMetrics.horizontalPadding)
            .frame(width: PillMetrics.pillWidth(for: model.state), height: PillMetrics.height)
            .background(background)
            .overlay(alignment: .trailing) { cancelControl }
            .animation(.easeInOut(duration: 0.16), value: model.state)
            // Bottom-left inside the panel is (shadowPadding, shadowPadding):
            // the panel hugs the pill, so centring fills that contract exactly.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark)
            // Input is handled by the hosting NSView (drag + ✕), never by SwiftUI.
            .allowsHitTesting(false)
    }

    /// Dark glass: backdrop (casts the single shadow) → system material → tint →
    /// a gradient hairline that reads as a top sheen.
    private var background: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Palette.backdrop)
                .shadow(color: Palette.shadow, radius: 9, x: 0, y: 3)
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(Palette.tint)
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Palette.strokeTop, Palette.strokeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
    }

    /// ✕ — drawn here, hit-tested by the panel (see `PillMetrics.cancelHitRect`).
    /// The hover highlight is the affordance of last resort: an accessory app
    /// cannot always win control of the system cursor, but it can always light
    /// up its own button.
    @ViewBuilder
    private var cancelControl: some View {
        if PillMetrics.showsCancel(for: model.state) {
            let hovering = model.hoveringCancel
            ZStack {
                Circle()
                    .fill(hovering ? Palette.cancelCircleHover : Palette.cancelCircle)
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(hovering ? Palette.cancelGlyphHover : Palette.cancelGlyph)
            }
            .frame(width: PillMetrics.cancelDiameter, height: PillMetrics.cancelDiameter)
            .scaleEffect(hovering ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .padding(.trailing, PillMetrics.cancelTrailingInset)
            .transition(.opacity)
        }
    }

    private var content: some View {
        ZStack {
            stateContent
                .id(model.state.kind)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.12), value: model.state.kind)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .recording:
            // The floating pill is narrow: show only the most recent slice of
            // the shared history.
            RecordingContent(levels: Array(model.levels.suffix(PillMetrics.barCount)))
                // Keep the wave clear of the ✕ zone.
                .padding(.trailing, PillMetrics.cancelDiameter + 6)
        case .processing:
            ProcessingContent(animating: model.isOnScreen)
                .padding(.trailing, PillMetrics.cancelDiameter + 6)
        case .success:
            SuccessContent()
        case .error(let message):
            ErrorContent(message: message)
        }
    }
}

// MARK: - Recording

/// The scrolling oscillogram: one thin bar per history sample, newest at the
/// right. All motion comes from real level data pushed at ≤ 20 Hz; a short
/// linear animation between pushes keeps it fluid without a 60 Hz timeline.
struct RecordingContent: View {
    let levels: [Double]
    var barWidth: CGFloat = PillMetrics.barWidth
    var spacing: CGFloat = PillMetrics.barSpacing
    var minHeight: CGFloat = PillMetrics.barMinHeight
    var maxHeight: CGFloat = PillMetrics.barMaxHeight

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.barTop, Palette.barBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: barWidth, height: barHeight(levels[index]))
            }
        }
        .frame(height: maxHeight)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.linear(duration: 0.06), value: levels)
    }

    private func barHeight(_ level: Double) -> CGFloat {
        // A soft-knee curve lifts quiet speech into the visible range without
        // letting shouts pin every bar to the top.
        let shaped = pow(min(max(level, 0), 1), 0.62)
        return minHeight + (maxHeight - minHeight) * CGFloat(shaped)
    }
}

/// Elapsed recording time, `m:ss`. Ticks itself off a timeline rather than
/// pushing state changes through the model.
struct ElapsedLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.25)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .fixedSize()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Processing

/// The same bar geometry as recording, driven by a travelling wave instead of
/// the mic — the pill visibly keeps "working" without jumping to a different
/// layout, then crossfades out when the transcript lands.
struct ProcessingContent: View {
    let animating: Bool
    var barCount: Int = PillMetrics.barCount
    var barWidth: CGFloat = PillMetrics.barWidth
    var spacing: CGFloat = PillMetrics.barSpacing
    var maxHeight: CGFloat = PillMetrics.barMaxHeight
    /// The docked pill has room to say what it is doing; the floating one does not.
    var label: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 9) {
                HStack(spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(Palette.barTop.opacity(0.30 + 0.55 * pulse(index, at: t)))
                            .frame(width: barWidth, height: height(index, at: t))
                    }
                }
                if let label {
                    Text(label)
                        .font(pillFont)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(height: maxHeight)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func pulse(_ index: Int, at t: Double) -> Double {
        let travel = sin(t * 4.4 - Double(index) * 0.42)
        return travel * 0.5 + 0.5
    }

    private func height(_ index: Int, at t: Double) -> CGFloat {
        4 + 10 * CGFloat(pulse(index, at: t))
    }
}

// MARK: - Success

struct SuccessContent: View {
    var label: String?
    @State private var popped = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.successGreen)
            if let label {
                Text(label)
                    .font(pillFont)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .scaleEffect(popped ? 1.0 : 0.5)
        .onAppear {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) { popped = true }
        }
    }
}

// MARK: - Error

struct ErrorContent: View {
    let message: String

    var body: some View {
        HStack(spacing: PillLayout.errorIconSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.warningOrange)
                .frame(width: PillLayout.errorIconWidth)
            Text(message)
                .font(pillFont)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
