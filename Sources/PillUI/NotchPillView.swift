// The notch-docked presentation: the black shape appears to grow out of the
// MacBook's camera cutout, carrying an elapsed clock, the live waveform and the
// ✕ in a strip below it.
//
// Why this works without any special API: the notch is a physical cutout with
// no pixels, and the strips either side of it are ordinary menu-bar pixels. A
// pure-black shape drawn flush to the screen's top edge, centred on the cutout
// and wider than it, is indistinguishable from the cutout itself growing. All
// content sits below `notchSize.height` — anything above that line would be
// hidden inside the cutout.
//
// Dragging the strip does not animate anything here: `PillController` hands the
// pill straight to the pointer as the ordinary floating capsule, and this view
// goes away with it.
import OpenWisperCore
import SwiftUI

// MARK: - Root

/// Switches between the two presentations. Kept as a single root view so the
/// hosting view never has to be rebuilt when the pill docks or undocks.
struct PillRootView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        if model.isNotchDocked {
            NotchPillView(model: model)
        } else {
            PillView(model: model)
        }
    }
}

// MARK: - Notch pill

struct NotchPillView: View {
    @ObservedObject var model: PillModel

    private var notchWidth: CGFloat { max(model.notchSize.width, 120) }
    private var notchHeight: CGFloat { max(model.notchSize.height, 24) }

    private var isOpen: Bool { model.isExpanded }

    private var shapeWidth: CGFloat { isOpen ? NotchMetrics.expandedWidth : notchWidth }
    private var shapeHeight: CGFloat { isOpen ? notchHeight + NotchMetrics.contentHeight : notchHeight }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(
                bottomRadius: isOpen ? NotchMetrics.bottomRadius : NotchMetrics.collapsedBottomRadius,
                fillet: isOpen ? NotchMetrics.fillet : 0
            )
            .fill(Color.black)
            .frame(width: shapeWidth, height: shapeHeight)
            .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 5)
            .frame(maxWidth: .infinity, alignment: .center)

            strip
                .frame(width: shapeWidth, height: NotchMetrics.contentHeight)
                .offset(y: notchHeight)
                .opacity(isOpen ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isOpen)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    // MARK: Docked strip

    /// `[ 0:07 ] [ ————waveform———— ] [ ✕ ]` — the clock and the longer wave are
    /// what keep the wider shape from reading as empty.
    private var strip: some View {
        ZStack {
            stateContent
                .id(kindKey)
                .transition(.opacity)
        }
        .overlay(alignment: .trailing) { cancelControl }
        .animation(.easeInOut(duration: 0.12), value: kindKey)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .recording:
            HStack(spacing: 10) {
                if let started = model.recordingStartedAt {
                    ElapsedLabel(start: started)
                }
                RecordingContent(
                    levels: model.levels,
                    barWidth: NotchMetrics.barWidth,
                    spacing: NotchMetrics.barSpacing,
                    minHeight: NotchMetrics.barMinHeight,
                    maxHeight: NotchMetrics.barMaxHeight
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, NotchMetrics.cancelDiameter + NotchMetrics.cancelTrailingInset + 8)

        case .processing:
            ProcessingContent(
                animating: model.isOnScreen,
                barCount: 22,
                barWidth: NotchMetrics.barWidth,
                spacing: NotchMetrics.barSpacing,
                maxHeight: NotchMetrics.barMaxHeight,
                label: "Transcribing…"
            )
            .padding(.leading, 16)
            .padding(.trailing, NotchMetrics.cancelDiameter + NotchMetrics.cancelTrailingInset + 8)

        case .success:
            SuccessContent(label: "Inserted")

        case .error(let message):
            ErrorContent(message: message)
                .padding(.horizontal, 16)
        }
    }

    /// The ✕, matching `NotchMetrics.cancelHitRect`. Same hover highlight as the
    /// floating pill.
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
            .frame(width: NotchMetrics.cancelDiameter, height: NotchMetrics.cancelDiameter)
            .scaleEffect(hovering ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .padding(.trailing, NotchMetrics.cancelTrailingInset)
        }
    }

    private var kindKey: Int {
        switch model.state {
        case .recording: return 0
        case .processing: return 1
        case .success: return 2
        case .error: return 3
        }
    }
}
