import SwiftUI

/// Layout tuning for the notch-docked pill.
public enum NotchMetrics {
    /// Expanded width. Wider than the ~185 pt notch so the shape visibly grows
    /// out of it rather than just downward.
    public static let expandedWidth: CGFloat = 340
    /// Height of the content strip hanging below the cutout.
    public static let contentHeight: CGFloat = 52

    public static let bottomRadius: CGFloat = 22
    /// Matches the real notch's own bottom corners while collapsed.
    public static let collapsedBottomRadius: CGFloat = 10
    /// The concave curve where the black melts back into the menu bar.
    public static let fillet: CGFloat = 11

    /// Window slack: the fillets bulge outside the shape's width, and the
    /// shadow needs room below.
    public static let horizontalPadding: CGFloat = 30
    public static let bottomPadding: CGFloat = 26

    public static let cancelDiameter: CGFloat = 22
    public static let cancelTrailingInset: CGFloat = 12

    // Waveform inside the docked strip: longer and taller than the floating
    // pill's, which is what keeps the wider shape from reading as empty.
    public static let barWidth: CGFloat = 2
    public static let barSpacing: CGFloat = 2.1
    public static let barMaxHeight: CGFloat = 30
    public static let barMinHeight: CGFloat = 3

    // MARK: Docking
    //
    // Pulling the pill out is a plain drag: grabbing the strip hands the pill
    // straight to the pointer as the floating capsule (see
    // `PillController.beginFloatingDrag`). These numbers only govern the way
    // back in.

    /// Reach of the notch's capture zone: dropping the pill within this of the
    /// cutout re-docks it.
    public static let redockDistance: CGFloat = 150
    /// Within this of the docked position the pill is actively pulled toward
    /// the notch while dragging — it snaps home instead of being parked behind
    /// the cutout, which has no pixels to draw it in.
    public static let magnetRadius: CGFloat = 190
    /// How hard the magnet pulls at its centre (0–1 of the remaining gap, per
    /// frame). High enough to feel decisive, low enough to still fight it.
    public static let magnetStrength: CGFloat = 0.55

    public static func windowSize(notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: expandedWidth + horizontalPadding * 2,
            height: notchHeight + contentHeight + bottomPadding
        )
    }

    /// The content strip in *window* coordinates (bottom-left origin).
    public static func contentRect(windowSize: CGSize, notchHeight: CGFloat) -> CGRect {
        CGRect(
            x: (windowSize.width - expandedWidth) / 2,
            y: windowSize.height - notchHeight - contentHeight,
            width: expandedWidth,
            height: contentHeight
        )
    }

    /// The ✕ hit zone in window coordinates, padded beyond the drawn circle.
    public static func cancelHitRect(windowSize: CGSize, notchHeight: CGFloat) -> CGRect {
        let content = contentRect(windowSize: windowSize, notchHeight: notchHeight)
        let slack: CGFloat = 5
        return CGRect(
            x: content.maxX - cancelTrailingInset - cancelDiameter - slack,
            y: content.midY - cancelDiameter / 2 - slack,
            width: cancelDiameter + slack * 2,
            height: cancelDiameter + slack * 2
        )
    }
}

// MARK: - The notch silhouette

/// The docked shape: square against the screen's top edge, rounded bottom
/// corners, and concave fillets where the black melts back into the menu bar.
///
/// Collapsed it is pixel-identical to the real cutout; expanded it is the same
/// outline grown wider and taller, which is what makes the strip read as the
/// notch itself opening.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var fillet: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, fillet) }
        set {
            bottomRadius = newValue.first
            fillet = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let r = min(bottomRadius, min(w, h) / 2)
        let f = max(0, fillet)

        var p = Path()
        // Outer top-left, curving inward to the shape's left edge.
        p.move(to: CGPoint(x: rect.minX - f, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + f),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        // Down the left side, around the bottom-left corner.
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY + h),
            control: CGPoint(x: rect.minX, y: rect.minY + h)
        )
        // Bottom edge, bottom-right corner, up the right side.
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + h))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h - r),
            control: CGPoint(x: rect.maxX, y: rect.minY + h)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX + f, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
